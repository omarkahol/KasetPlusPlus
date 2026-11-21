import Foundation
import os
import Testing
@testable import KasetPlus

@Suite("DearrowCache", .serialized, .tags(.service))
@MainActor
struct DearrowCacheTests {
    @Test("DearrowTitle decodes UUID and strips > formatter markers in displayTitle")
    func titleDecodingAndDisplayFormatting() throws {
        let json = """
        {
            "title": "How >AI Works in >2026",
            "original": false,
            "votes": 12,
            "locked": true,
            "UUID": "abc-123-def"
        }
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(DearrowTitle.self, from: data)

        #expect(decoded.title == "How >AI Works in >2026")
        #expect(decoded.displayTitle == "How AI Works in 2026")
        #expect(decoded.original == false)
        #expect(decoded.votes == 12)
        #expect(decoded.locked == true)
        #expect(decoded.uuid == "abc-123-def")
        #expect(decoded.id == "abc-123-def")
    }

    @Test("fetchAllTitles hits fetchAll=true and validates top-title rules")
    func fetchAllTitlesAndTopTitleValidity() async throws {
        let negativeUnlockedJSON = """
        {
            "titles": [
                { "title": "Bad >Title", "original": false, "votes": -3, "locked": false, "UUID": "u1" },
                { "title": "Original Title", "original": true, "votes": 0, "locked": false, "UUID": "u2" }
            ]
        }
        """

        let cache1 = DearrowCache.makeTestInstance(
            transport: { request in
                let url = try #require(request.url)
                #expect(url.absoluteString == "https://sponsor.ajay.app/api/branding?videoID=vid1&fetchAll=true")
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                let data = try #require(negativeUnlockedJSON.data(using: .utf8))
                return (data, response)
            }
        )

        let titles1 = try await cache1.fetchAllTitles(videoId: "vid1")
        #expect(titles1.count == 2)
        #expect(cache1.hasDearrow(for: "vid1") == false)
        #expect(cache1.displayTitle(for: "vid1", original: "Original Title") == "Original Title")

        let negativeLockedJSON = """
        {
            "titles": [
                { "title": "Locked >Title", "original": false, "votes": -2, "locked": true, "UUID": "u3" }
            ]
        }
        """

        let cache2 = DearrowCache.makeTestInstance(
            transport: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                let data = try #require(negativeLockedJSON.data(using: .utf8))
                return (data, response)
            }
        )

        let titles2 = try await cache2.fetchAllTitles(videoId: "vid2")
        #expect(titles2.count == 1)
        #expect(cache2.hasDearrow(for: "vid2") == true)
        #expect(cache2.displayTitle(for: "vid2", original: "Orig") == "Locked Title")
    }

    @Test("fetchAllTitles handles 404 by returning empty array")
    func fetchAllTitles404() async throws {
        let cache = DearrowCache.makeTestInstance(
            transport: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (Data(), response)
            }
        )

        let titles = try await cache.fetchAllTitles(videoId: "missing")
        #expect(titles.isEmpty)
        #expect(cache.cachedAllTitles(for: "missing") == [])
    }

    @Test("vote sends raw title payload to POST /api/branding and updates local vote state")
    func voteSuccessAndToggleDelta() async throws {
        let initialJSON = """
        {
            "titles": [
                { "title": ">NASA Launches >Rocket", "original": false, "votes": 5, "locked": false, "UUID": "title-uuid-1" }
            ]
        }
        """

        let capturedBodies = OSAllocatedUnfairLock<[Data]>(initialState: [])
        let cache = DearrowCache.makeTestInstance(
            transport: { request in
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                if request.httpMethod == "POST" {
                    let bodyData = try #require(request.httpBody)
                    capturedBodies.withLock { $0.append(bodyData) }
                    #expect(url.absoluteString == "https://sponsor.ajay.app/api/branding")
                    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                    return (Data("OK".utf8), response)
                }
                let data = try #require(initialJSON.data(using: .utf8))
                return (data, response)
            },
            userIDProvider: { "12345678-1234-1234-1234-123456789012" }
        )

        let titles = try await cache.fetchAllTitles(videoId: "vid123")
        let entry = try #require(titles.first)

        // Upvote
        try await cache.vote(videoId: "vid123", title: entry, downvote: false)
        #expect(cache.userVote(for: "vid123", titleUUID: "title-uuid-1") == .up)
        #expect(cache.cachedAllTitles(for: "vid123")?.first?.votes == 6)

        // Verify raw title with '>' was sent, not stripped displayTitle
        let firstBodyData = try #require(capturedBodies.withLock { $0.first })
        let firstBody = try #require(try JSONSerialization.jsonObject(with: firstBodyData) as? [String: Any])
        #expect(firstBody["videoID"] as? String == "vid123")
        #expect(firstBody["userID"] as? String == "12345678-1234-1234-1234-123456789012")
        #expect(firstBody["downvote"] as? Bool == false)
        let titlePayload = try #require(firstBody["title"] as? [String: Any])
        #expect(titlePayload["title"] as? String == ">NASA Launches >Rocket")
        #expect(titlePayload["original"] as? Bool == false)

        // Switch to downvote (-2 delta)
        try await cache.vote(videoId: "vid123", title: entry, downvote: true)
        #expect(cache.userVote(for: "vid123", titleUUID: "title-uuid-1") == .down)
        #expect(cache.cachedAllTitles(for: "vid123")?.first?.votes == 4)
    }

    @Test("vote maps HTTP 400, 403, 429, and 500 to DearrowVoteError")
    func voteErrorMapping() async throws {
        let entry = DearrowTitle(title: "Test", original: false, votes: 1, locked: false, uuid: "u1")

        let cases: [(Int, String, DearrowVoteError)] = [
            (400, "Invalid title", .invalidRequest("Invalid title")),
            (403, "Locked", .forbidden("Locked")),
            (429, "Vote already in progress", .rateLimited),
            (500, "Title not found", .serverError(500, "Title not found")),
        ]

        for (status, body, expectedError) in cases {
            let cache = DearrowCache.makeTestInstance(
                transport: { request in
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: nil
                    ))
                    return (Data(body.utf8), response)
                },
                userIDProvider: { "12345678-1234-1234-1234-123456789012" }
            )

            await #expect(throws: expectedError) {
                try await cache.vote(videoId: "vid1", title: entry, downvote: true)
            }
        }
    }

    @Test("LRU eviction synchronizes allTitles with dearrowTitles and originalTitles")
    func lruEvictionSynchronizesAllTitles() async throws {
        let cache = DearrowCache.makeTestInstance(
            maxEntries: 2,
            transport: { request in
                let url = try #require(request.url)
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "videoID" })?.value ?? "v"
                let json = """
                {
                    "titles": [
                        { "title": "DeArrow \(id)", "original": false, "votes": 3, "locked": false, "UUID": "u-\(id)" }
                    ]
                }
                """
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                ))
                let data = try #require(json.data(using: .utf8))
                return (data, response)
            }
        )

        _ = try await cache.fetchAllTitles(videoId: "v1")
        _ = try await cache.fetchAllTitles(videoId: "v2")
        #expect(cache.cachedEntryCount == 2)
        #expect(cache.cachedAllTitles(for: "v1") != nil)

        _ = try await cache.fetchAllTitles(videoId: "v3")
        #expect(cache.cachedEntryCount == 2)
        #expect(cache.cachedAllTitles(for: "v1") == nil)
        #expect(cache.hasDearrow(for: "v1") == false)
        #expect(cache.cachedAllTitles(for: "v3") != nil)
        #expect(cache.hasDearrow(for: "v3") == true)
    }

    @Test("SettingsManager dearrowUserID generates and persists a 36-char UUID")
    func settingsManagerDearrowUserID() {
        let userID = SettingsManager.shared.dearrowUserID
        #expect(userID.count == 36)
        #expect(UUID(uuidString: userID) != nil)
        #expect(SettingsManager.shared.dearrowUserID == userID)
    }
}

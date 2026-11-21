import Foundation

/// A single community-submitted or original title entry from the DeArrow API.
struct DearrowTitle: Codable, Sendable, Identifiable, Equatable {
    let title: String
    let original: Bool
    let votes: Int
    let locked: Bool
    let uuid: String

    var id: String { self.uuid }

    /// Title formatted for display with DeArrow's `>` auto-formatter markers stripped.
    var displayTitle: String {
        self.title.replacingOccurrences(of: ">", with: "")
    }

    enum CodingKeys: String, CodingKey {
        case title
        case original
        case votes
        case locked
        case uuid = "UUID"
    }
}

/// Local user vote state for a DeArrow title entry.
enum DearrowVoteDirection: String, Sendable, Equatable, Codable {
    case up
    case down
}

/// Errors returned when fetching all DeArrow titles or submitting a vote.
enum DearrowVoteError: LocalizedError, Equatable {
    case invalidRequest(String?)
    case forbidden(String?)
    case rateLimited
    case serverError(Int, String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(detail):
            if let detail, !detail.isEmpty {
                return String(localized: "DeArrow rejected the vote request: \(detail)")
            }
            return String(localized: "DeArrow rejected the vote request.")
        case let .forbidden(detail):
            if let detail, !detail.isEmpty {
                return String(localized: "Voting is not permitted for this title: \(detail)")
            }
            return String(localized: "Voting is not permitted for this title.")
        case .rateLimited:
            return String(localized: "A vote is already in progress. Please wait a moment and try again.")
        case let .serverError(statusCode, _):
            return String(localized: "DeArrow server returned an error (HTTP \(statusCode)).")
        case .invalidResponse:
            return String(localized: "Received an invalid response from DeArrow.")
        }
    }
}

/// Centralized DeArrow title cache. Fetches community-submitted accurate
/// titles from the DeArrow API and makes them available to any view.
///
/// Views show original titles immediately; the cache fetches in the
/// background and `@Observable` triggers live UI updates when results
/// arrive.
@MainActor
@Observable
final class DearrowCache {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = DearrowCache()

    private static let defaultMaxEntries = 500
    private static let maxConcurrentFetches = 4
    private static let userVotesDefaultsKey = "dearrow.userVotes"

    /// DeArrow title keyed by videoId.
    private var dearrowTitles: [String: String] = [:]
    /// Original YouTube title, stored so the toggle can restore it.
    private var originalTitles: [String: String] = [:]
    /// All community titles keyed by videoId (populated by `fetchAllTitles`).
    private var allTitles: [String: [DearrowTitle]] = [:]
    /// Local user vote state keyed by `"\(videoId)|\(uuid)"`.
    private var userVotes: [String: DearrowVoteDirection] = [:]
    /// Insertion/access order for bounded LRU eviction.
    private var accessOrder: [String] = []
    /// Video IDs currently being fetched (dedup).
    private var inFlight: Set<String> = []
    /// Video IDs that already completed a DeArrow lookup (prevents re-fetching 404s on scroll).
    private var checkedVideoIds: Set<String> = []
    private let maxEntries: Int
    private let userDefaults: UserDefaults?
    private let transport: Transport
    private let userIDProvider: () -> String

    private init(
        maxEntries: Int = DearrowCache.defaultMaxEntries,
        userDefaults: UserDefaults? = .standard,
        transport: Transport? = nil,
        userIDProvider: (() -> String)? = nil
    ) {
        self.maxEntries = max(1, maxEntries)
        self.userDefaults = userDefaults
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
        self.userIDProvider = userIDProvider ?? {
            SettingsManager.shared.dearrowUserID
        }
        if let stored = userDefaults?.dictionary(forKey: Self.userVotesDefaultsKey) as? [String: String] {
            var restored: [String: DearrowVoteDirection] = [:]
            for (key, rawValue) in stored {
                if let direction = DearrowVoteDirection(rawValue: rawValue) {
                    restored[key] = direction
                }
            }
            self.userVotes = restored
        }
    }

    static func makeTestInstance(
        maxEntries: Int = 500,
        transport: Transport? = nil,
        userIDProvider: (() -> String)? = nil
    ) -> DearrowCache {
        DearrowCache(
            maxEntries: maxEntries,
            userDefaults: nil,
            transport: transport,
            userIDProvider: userIDProvider
        )
    }

    // MARK: - Public API

    /// Pure read of the cached DeArrow title without mutating cache state.
    func dearrowTitle(for videoId: String) -> String? {
        self.dearrowTitles[videoId]
    }

    /// Records the original YouTube title for toggle-back support outside of view `body`.
    func registerOriginalTitle(_ title: String, for videoId: String) {
        guard !title.isEmpty, self.originalTitles[videoId] == nil else { return }
        self.originalTitles[videoId] = title
        self.recordAccess(for: videoId)
    }

    /// Returns the DeArrow title if available, otherwise the original.
    func displayTitle(for videoId: String, original: String) -> String {
        // Store original for toggle support
        if !original.isEmpty, self.originalTitles[videoId] == nil {
            self.originalTitles[videoId] = original
            self.recordAccess(for: videoId)
        }
        return self.dearrowTitles[videoId] ?? original
    }

    /// Whether a DeArrow replacement exists for this video.
    func hasDearrow(for videoId: String) -> Bool {
        self.dearrowTitles[videoId] != nil
    }

    /// The original YouTube title (for toggle back).
    func originalTitle(for videoId: String) -> String? {
        self.originalTitles[videoId]
    }

    /// Returns cached community titles for a video if already fetched.
    func cachedAllTitles(for videoId: String) -> [DearrowTitle]? {
        self.allTitles[videoId]
    }

    /// Returns the local user's vote direction for a specific title, if any.
    func userVote(for videoId: String, titleUUID: String) -> DearrowVoteDirection? {
        self.userVotes[Self.voteKey(videoId: videoId, uuid: titleUUID)]
    }

    var cachedEntryCount: Int {
        self.accessOrder.count
    }

    /// Batch-fetch DeArrow data for multiple videos with bounded concurrency.
    func fetchBatch(for videoIds: [String]) {
        guard SettingsManager.shared.dearrowEnabled else { return }
        let candidates = videoIds.filter {
            self.dearrowTitles[$0] == nil
                && !self.checkedVideoIds.contains($0)
                && !self.inFlight.contains($0)
        }
        guard !candidates.isEmpty else { return }
        for id in candidates {
            self.inFlight.insert(id)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = candidates.makeIterator()
                for _ in 0 ..< Self.maxConcurrentFetches {
                    if let nextId = iterator.next() {
                        group.addTask {
                            await self._fetch(videoId: nextId)
                            await MainActor.run {
                                _ = self.inFlight.remove(nextId)
                            }
                        }
                    }
                }
                while await group.next() != nil {
                    if let nextId = iterator.next() {
                        group.addTask {
                            await self._fetch(videoId: nextId)
                            await MainActor.run {
                                _ = self.inFlight.remove(nextId)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Fetch a single video. Safe to call from anywhere.
    func fetchOneIfNeeded(videoId: String) {
        guard SettingsManager.shared.dearrowEnabled,
              self.dearrowTitles[videoId] == nil,
              !self.checkedVideoIds.contains(videoId),
              !self.inFlight.contains(videoId)
        else { return }

        self.inFlight.insert(videoId)
        Task {
            await self._fetch(videoId: videoId)
            self.inFlight.remove(videoId)
        }
    }

    /// Fetches all community titles for a video (including negative-score titles)
    /// and synchronizes the local cache.
    @discardableResult
    func fetchAllTitles(videoId: String) async throws -> [DearrowTitle] {
        guard let url = Self.brandingURL(videoId: videoId, fetchAll: true) else {
            throw DearrowVoteError.invalidResponse
        }

        let (data, response) = try await self.transport(URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DearrowVoteError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            self.allTitles[videoId] = []
            self.dearrowTitles.removeValue(forKey: videoId)
            self.checkedVideoIds.insert(videoId)
            self.recordAccess(for: videoId)
            return []
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DearrowVoteError.serverError(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(BrandingResponse.self, from: data)
        self.allTitles[videoId] = decoded.titles
        self.checkedVideoIds.insert(videoId)
        self.syncTopDisplayTitle(from: decoded.titles, for: videoId)
        self.recordAccess(for: videoId)
        return decoded.titles
    }

    /// Submits an upvote or downvote for a DeArrow title and updates local vote state.
    func vote(videoId: String, title: DearrowTitle, downvote: Bool) async throws {
        guard let url = URL(string: "https://sponsor.ajay.app/api/branding") else {
            throw DearrowVoteError.invalidResponse
        }

        let payload = VoteRequest(
            videoID: videoId,
            userID: self.userIDProvider(),
            userAgent: Self.userAgent,
            title: VoteRequest.TitlePayload(
                title: title.title,
                original: title.original
            ),
            downvote: downvote
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await self.transport(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DearrowVoteError.invalidResponse
        }

        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch httpResponse.statusCode {
        case 200 ... 299:
            self.applySuccessfulVote(videoId: videoId, title: title, downvote: downvote)
        case 400:
            throw DearrowVoteError.invalidRequest(body)
        case 403:
            throw DearrowVoteError.forbidden(body)
        case 429:
            throw DearrowVoteError.rateLimited
        default:
            throw DearrowVoteError.serverError(httpResponse.statusCode, body)
        }
    }

    // MARK: - Private

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Kaset/\(version)"
    }

    private static func brandingURL(videoId: String, fetchAll: Bool) -> URL? {
        var components = URLComponents(string: "https://sponsor.ajay.app/api/branding")
        var items = [URLQueryItem(name: "videoID", value: videoId)]
        if fetchAll {
            items.append(URLQueryItem(name: "fetchAll", value: "true"))
        }
        components?.queryItems = items
        return components?.url
    }

    private static func voteKey(videoId: String, uuid: String) -> String {
        "\(videoId)|\(uuid)"
    }

    private static func isValidTopTitle(_ entry: DearrowTitle) -> Bool {
        !entry.original
            && (entry.locked || entry.votes >= 0)
            && !entry.displayTitle.isEmpty
    }

    private func syncTopDisplayTitle(from titles: [DearrowTitle], for videoId: String) {
        if let first = titles.first, Self.isValidTopTitle(first) {
            self.dearrowTitles[videoId] = first.displayTitle
        } else {
            self.dearrowTitles.removeValue(forKey: videoId)
        }
    }

    private func applySuccessfulVote(videoId: String, title: DearrowTitle, downvote: Bool) {
        let key = Self.voteKey(videoId: videoId, uuid: title.uuid)
        let newDirection: DearrowVoteDirection = downvote ? .down : .up
        let previousDirection = self.userVotes[key]

        let delta: Int = switch (previousDirection, newDirection) {
        case (nil, .up): 1
        case (nil, .down): -1
        case (.up, .down): -2
        case (.down, .up): 2
        case (.up, .up), (.down, .down): 0
        }

        self.userVotes[key] = newDirection
        if let userDefaults = self.userDefaults {
            let rawMap = self.userVotes.mapValues(\.rawValue)
            userDefaults.set(rawMap, forKey: Self.userVotesDefaultsKey)
        }

        if var existingTitles = self.allTitles[videoId],
           let index = existingTitles.firstIndex(where: { $0.uuid == title.uuid })
        {
            let target = existingTitles[index]
            existingTitles[index] = DearrowTitle(
                title: target.title,
                original: target.original,
                votes: target.votes + delta,
                locked: target.locked,
                uuid: target.uuid
            )
            self.allTitles[videoId] = existingTitles
            self.syncTopDisplayTitle(from: existingTitles, for: videoId)
            self.recordAccess(for: videoId)
        }
    }

    private func recordAccess(for videoId: String) {
        if let existingIndex = self.accessOrder.firstIndex(of: videoId) {
            self.accessOrder.remove(at: existingIndex)
        }
        self.accessOrder.append(videoId)
        while self.accessOrder.count > self.maxEntries {
            let evicted = self.accessOrder.removeFirst()
            self.dearrowTitles.removeValue(forKey: evicted)
            self.originalTitles.removeValue(forKey: evicted)
            self.allTitles.removeValue(forKey: evicted)
            self.checkedVideoIds.remove(evicted)
        }
    }

    /// Fetches the original video title via YouTube's public oEmbed endpoint as a fallback
    /// when no original title is cached locally or returned by DeArrow.
    func fetchOriginalTitleOEmbed(videoId: String) async -> String? {
        if let cached = self.originalTitles[videoId], !cached.isEmpty {
            return cached
        }
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoId)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await self.transport(URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode)
            else {
                return nil
            }
            let decoded = try JSONDecoder().decode(OEmbedResponse.self, from: data)
            let trimmed = decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            self.registerOriginalTitle(trimmed, for: videoId)
            return trimmed
        } catch {
            return nil
        }
    }

    private func _fetch(videoId: String) async {
        guard let url = Self.brandingURL(videoId: videoId, fetchAll: false) else {
            return
        }

        do {
            let (data, response) = try await self.transport(URLRequest(url: url))
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    self.checkedVideoIds.insert(videoId)
                    return
                }
                if !(200 ... 299).contains(httpResponse.statusCode) {
                    return
                }
            }

            self.checkedVideoIds.insert(videoId)
            let decoded = try JSONDecoder().decode(BrandingResponse.self, from: data)
            guard let first = decoded.titles.first, Self.isValidTopTitle(first) else {
                return
            }

            self.dearrowTitles[videoId] = first.displayTitle
            self.recordAccess(for: videoId)
        } catch {
            // Silently ignore — no DeArrow data for this video
        }
    }
}

// MARK: - API Models

private struct OEmbedResponse: Decodable {
    let title: String
}

private struct BrandingResponse: Decodable {
    let titles: [DearrowTitle]
}

private struct VoteRequest: Encodable {
    struct TitlePayload: Encodable {
        let title: String
        let original: Bool
    }

    let videoID: String
    let userID: String
    let userAgent: String
    let title: TitlePayload
    let downvote: Bool
}

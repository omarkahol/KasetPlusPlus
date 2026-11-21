import Foundation

// MARK: - InnerTubeStreamResolver

/// Resolves direct `AVPlayer`-compatible streaming URLs (Apple HLS multivariant manifests or
/// muxed progressive MP4s) directly via YouTube's InnerTube `/youtubei/v1/player` API
/// without spawning external subprocesses.
actor InnerTubeStreamResolver {
    static let shared = InnerTubeStreamResolver()

    struct ResolvedStream: Sendable {
        let url: URL
        let ttl: TimeInterval
    }

    enum PlayerParseResult: Sendable {
        case stream(url: URL, ttl: TimeInterval, visitorData: String?)
        case loginRequired(visitorData: String?)
        case unplayable(visitorData: String?)
    }

    private struct ClientProfile: Sendable {
        let clientName: String
        let clientID: String
        let clientVersion: String
        let deviceMake: String
        let deviceModel: String
        let osName: String
        let osVersion: String
        let userAgent: String

        static let visionOS = ClientProfile(
            clientName: "VISIONOS",
            clientID: "101",
            clientVersion: "1.02",
            deviceMake: "Apple",
            deviceModel: "RealityDevice17,1",
            osName: "visionOS",
            osVersion: "26.5.23O471",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        )

        static let ios = ClientProfile(
            clientName: "IOS",
            clientID: "5",
            clientVersion: "20.10.4",
            deviceMake: "Apple",
            deviceModel: "iPhone16,2",
            osName: "iPhone",
            osVersion: "18.3.2.22D82",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
        )
    }

    // swiftlint:disable:next line_length
    private static let playerEndpointURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false&fields=playabilityStatus,streamingData(hlsManifestUrl,expiresInSeconds,formats(itag,url,mimeType,width,height,bitrate)),videoDetails(videoId,lengthSeconds,isLiveContent),responseContext.visitorData")
    private static let nextEndpointURL = URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false&fields=responseContext.visitorData")
    private static let defaultStreamTTL: TimeInterval = 3 * 3600
    private static let expirationSafetyBuffer: TimeInterval = 300

    private let session: URLSession
    private var cachedVisitorData: String?
    private var visitorDataBootstrapTask: Task<String?, Never>?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = APISessionConfiguration.make()
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func prewarmVisitorData() async {
        guard self.cachedVisitorData == nil else { return }
        let deadline = ContinuousClock.now + .seconds(3)
        _ = await self.bootstrapVisitorData(for: "dQw4w9WgXcQ", deadline: deadline)
    }

    func resolveStream(videoId: String, timeoutSeconds: TimeInterval) async -> ResolvedStream? {
        guard !Task.isCancelled, !videoId.isEmpty else { return nil }
        let deadline = ContinuousClock.now + .seconds(max(0.2, timeoutSeconds))

        if self.cachedVisitorData == nil {
            _ = await self.bootstrapVisitorData(for: videoId, deadline: deadline)
        }

        let initialVisitorData = self.cachedVisitorData
        let visionResult = await self.fetchPlayerStream(
            videoId: videoId,
            profile: .visionOS,
            visitorData: initialVisitorData,
            deadline: deadline
        )

        switch visionResult {
        case let .stream(url, ttl, visitorData):
            self.updateVisitorData(visitorData)
            return ResolvedStream(url: url, ttl: ttl)
        case let .loginRequired(visitorData):
            if let visitorData, !visitorData.isEmpty {
                self.updateVisitorData(visitorData)
            } else {
                self.cachedVisitorData = nil
            }
        case let .unplayable(visitorData):
            self.updateVisitorData(visitorData)
        case nil:
            break
        }

        guard !Task.isCancelled, self.remainingSeconds(until: deadline) > 0.1 else {
            return nil
        }

        let iosResult = await self.fetchPlayerStream(
            videoId: videoId,
            profile: .ios,
            visitorData: self.cachedVisitorData,
            deadline: deadline
        )

        var refreshedVisitorData: String?
        switch iosResult {
        case let .stream(url, ttl, visitorData):
            self.updateVisitorData(visitorData)
            return ResolvedStream(url: url, ttl: ttl)
        case let .loginRequired(visitorData), let .unplayable(visitorData):
            if let visitorData, !visitorData.isEmpty {
                self.updateVisitorData(visitorData)
                refreshedVisitorData = visitorData
            }
        case nil:
            break
        }

        // If VISIONOS failed with stale/missing visitorData and IOS supplied a fresh one,
        // retry VISIONOS once because VISIONOS exposes HLS manifests for tracks where IOS does not.
        if let refreshedVisitorData,
           refreshedVisitorData != initialVisitorData,
           !Task.isCancelled,
           self.remainingSeconds(until: deadline) > 0.1
        {
            let retryResult = await self.fetchPlayerStream(
                videoId: videoId,
                profile: .visionOS,
                visitorData: refreshedVisitorData,
                deadline: deadline
            )
            if case let .stream(url, ttl, visitorData) = retryResult {
                self.updateVisitorData(visitorData)
                return ResolvedStream(url: url, ttl: ttl)
            }
        }

        return nil
    }

    func updateVisitorData(_ visitorData: String?) {
        guard let visitorData = visitorData?.trimmingCharacters(in: .whitespacesAndNewlines),
              !visitorData.isEmpty
        else { return }
        self.cachedVisitorData = visitorData
    }

    nonisolated static func parsePlayerResponse(_ data: Data) -> PlayerParseResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unplayable(visitorData: nil)
        }

        let responseContext = json["responseContext"] as? [String: Any]
        let rawVisitorData = (responseContext?["visitorData"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visitorData = (rawVisitorData?.isEmpty == false) ? rawVisitorData : nil

        let playabilityStatus = json["playabilityStatus"] as? [String: Any]
        let status = playabilityStatus?["status"] as? String ?? ""

        if status == "LOGIN_REQUIRED" {
            return .loginRequired(visitorData: visitorData)
        }
        guard status == "OK" else {
            return .unplayable(visitorData: visitorData)
        }

        let streamingData = json["streamingData"] as? [String: Any]
        let ttl = Self.streamTTL(from: streamingData)

        if let hlsString = streamingData?["hlsManifestUrl"] as? String,
           let hlsURL = Self.validHTTPURL(from: hlsString)
        {
            return .stream(url: hlsURL, ttl: ttl, visitorData: visitorData)
        }

        if let formats = streamingData?["formats"] as? [[String: Any]] {
            let candidates: [(url: URL, bitrate: Int)] = formats.compactMap { format in
                guard let urlString = format["url"] as? String,
                      let url = Self.validHTTPURL(from: urlString)
                else { return nil }
                let mimeType = (format["mimeType"] as? String ?? "").lowercased()
                guard mimeType.contains("mp4") else { return nil }
                let bitrate = format["bitrate"] as? Int ?? 0
                return (url, bitrate)
            }
            if let best = candidates.max(by: { $0.bitrate < $1.bitrate }) {
                return .stream(url: best.url, ttl: ttl, visitorData: visitorData)
            }
        }

        return .unplayable(visitorData: visitorData)
    }

    private func bootstrapVisitorData(
        for videoId: String,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        if let cached = self.cachedVisitorData {
            return cached
        }
        if let existingTask = self.visitorDataBootstrapTask {
            return await existingTask.value
        }

        let remaining = self.remainingSeconds(until: deadline)
        guard remaining > 0.1, let endpointURL = Self.nextEndpointURL else {
            return nil
        }

        let task = Task<String?, Never> { [session = self.session] in
            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.httpShouldHandleCookies = false
            request.timeoutInterval = min(2.5, max(0.5, remaining))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(ClientProfile.visionOS.userAgent, forHTTPHeaderField: "User-Agent")
            let body: [String: Any] = [
                "videoId": videoId,
                "context": [
                    "client": [
                        "clientName": "WEB",
                        "clientVersion": "2.20260708.00.00",
                        "hl": "en",
                        "gl": "US",
                    ],
                ],
            ]
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                return nil
            }
            request.httpBody = bodyData

            guard let data = await Self.performBoundedDataRequest(
                      request,
                      session: session,
                      timeoutSeconds: min(2.5, remaining)
                  ),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseContext = json["responseContext"] as? [String: Any],
                  let visitorData = (responseContext["visitorData"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !visitorData.isEmpty
            else {
                return nil
            }
            return visitorData
        }

        self.visitorDataBootstrapTask = task
        let resolved = await task.value
        self.visitorDataBootstrapTask = nil
        self.updateVisitorData(resolved)
        return self.cachedVisitorData
    }

    private func fetchPlayerStream(
        videoId: String,
        profile: ClientProfile,
        visitorData: String?,
        deadline: ContinuousClock.Instant
    ) async -> PlayerParseResult? {
        let remaining = self.remainingSeconds(until: deadline)
        guard !Task.isCancelled, remaining > 0.1, let endpointURL = Self.playerEndpointURL else {
            return nil
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = max(0.5, remaining)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.clientID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        var clientContext: [String: Any] = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
            "deviceMake": profile.deviceMake,
            "deviceModel": profile.deviceModel,
            "osName": profile.osName,
            "osVersion": profile.osVersion,
            "hl": "en",
            "gl": "US",
            "userAgent": profile.userAgent,
        ]
        if let visitorData, !visitorData.isEmpty {
            clientContext["visitorData"] = visitorData
        }

        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": clientContext],
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        request.httpBody = bodyData

        guard let data = await Self.performBoundedDataRequest(
            request,
            session: self.session,
            timeoutSeconds: remaining
        ) else {
            return nil
        }
        return Self.parsePlayerResponse(data)
    }

    private func remainingSeconds(until deadline: ContinuousClock.Instant) -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000.0
        return max(0, seconds)
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func performBoundedDataRequest(
        _ request: URLRequest,
        session: URLSession,
        timeoutSeconds: TimeInterval
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                guard let (data, response) = try? await session.data(for: request),
                      let httpResponse = response as? HTTPURLResponse,
                      (200 ... 299).contains(httpResponse.statusCode)
                else {
                    return nil
                }
                return data
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0.05, timeoutSeconds)))
                return nil
            }
            let first = await group.next().flatMap(\.self)
            group.cancelAll()
            return first
        }
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func streamTTL(from streamingData: [String: Any]?) -> TimeInterval {
        let rawSeconds: TimeInterval? = switch streamingData?["expiresInSeconds"] {
        case let string as String:
            TimeInterval(string)
        case let int as Int:
            TimeInterval(int)
        case let double as Double:
            double
        default:
            nil
        }
        guard let rawSeconds, rawSeconds.isFinite, rawSeconds > 0 else {
            return Self.defaultStreamTTL
        }
        return max(60, min(rawSeconds - Self.expirationSafetyBuffer, 5.5 * 3600))
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func validHTTPURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

// MARK: - DirectStreamResolver

/// Resolves direct audio stream URLs via YouTube's InnerTube player API for low-latency native streaming.
@MainActor
final class DirectStreamResolver {
    static let shared = DirectStreamResolver()

    private struct CachedURL {
        let url: URL
        let expirationDate: Date
    }

    private struct InFlightResolution {
        let id: UUID
        let task: Task<URL?, Never>
        let timeoutSeconds: TimeInterval
    }

    /// In-memory cache of resolved stream URLs with expiration (default 3 hours TTL).
    private var cache: [String: CachedURL] = [:]
    private var inFlightTasks: [String: InFlightResolution] = [:]

    private init() {}

    /// Returns a cached direct stream URL synchronously if one is present and unexpired.
    func cachedStreamURL(for videoId: String) -> URL? {
        guard let cached = self.cache[videoId], cached.expirationDate > Date() else {
            return nil
        }
        return cached.url
    }

    /// Prewarms a stream URL and its HLS audio playlist only when Fast Native Streaming is enabled.
    func prewarmIfEnabled(videoId: String) {
        guard SettingsManager.shared.isFastNativeStreamingEnabled, !UITestConfig.isRunningUnitTests else {
            return
        }
        self.prewarm(videoId: videoId)
    }

    /// Resolves and caches a stream URL in the background without blocking callers.
    func prewarm(videoId: String) {
        if let cachedURL = self.cachedStreamURL(for: videoId) {
            if HLSAudioSamplePlayer.isHLSURL(cachedURL) {
                Task {
                    await HLSManifestCache.shared.prewarm(multivariantURL: cachedURL)
                }
            }
            return
        }
        guard self.inFlightTasks[videoId] == nil else {
            return
        }
        Task {
            if let url = await self.resolveStreamURL(videoId: videoId, timeoutSeconds: 8.0),
               HLSAudioSamplePlayer.isHLSURL(url)
            {
                await HLSManifestCache.shared.prewarm(multivariantURL: url)
            }
        }
    }

    /// Attempts to resolve a direct `AVPlayer`-compatible streaming URL for a YouTube/YouTube Music videoId.
    ///
    /// - Parameters:
    ///   - videoId: Target video ID.
    ///   - timeoutSeconds: Maximum wait time before timing out (default 3.5s).
    /// - Returns: Direct streaming URL if resolved within the timeout, or `nil` on failure/timeout/DRM.
    func resolveStreamURL(videoId: String, timeoutSeconds: TimeInterval = 3.5) async -> URL? {
        if let cachedURL = self.cachedStreamURL(for: videoId) {
            return cachedURL
        }

        let startedAt = ContinuousClock.now
        if let existing = self.inFlightTasks[videoId] {
            let existingURL = await existing.task.value
            if let existingURL {
                return existingURL
            }
            if Task.isCancelled || existing.timeoutSeconds >= timeoutSeconds {
                return nil
            }
        }

        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
        let remainingBudget = timeoutSeconds - elapsedSeconds
        guard !Task.isCancelled, remainingBudget > 0.1 else {
            return nil
        }

        let taskID = UUID()
        let task: Task<InnerTubeStreamResolver.ResolvedStream?, Never> = Task {
            await InnerTubeStreamResolver.shared.resolveStream(
                videoId: videoId,
                timeoutSeconds: remainingBudget
            )
        }
        let wrapperTask = Task<URL?, Never> {
            await task.value?.url
        }

        self.inFlightTasks[videoId] = InFlightResolution(
            id: taskID,
            task: wrapperTask,
            timeoutSeconds: timeoutSeconds
        )
        let resolved = await task.value
        if self.inFlightTasks[videoId]?.id == taskID {
            self.inFlightTasks.removeValue(forKey: videoId)
        }

        if let resolved {
            self.cache[videoId] = CachedURL(
                url: resolved.url,
                expirationDate: Date().addingTimeInterval(resolved.ttl)
            )
        }

        return resolved?.url
    }

    /// Invalidates a cached stream URL for a video ID (e.g., if AVPlayer fails to open it).
    func invalidate(videoId: String) {
        self.cache.removeValue(forKey: videoId)
    }

    /// Clears any cached stream URLs.
    func clearCache() {
        self.cache.removeAll()
    }
}

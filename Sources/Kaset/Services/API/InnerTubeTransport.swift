import Foundation
import os

// MARK: - InnerTubeAuthPolicy

enum InnerTubeAuthPolicy {
    case optional
    case required
}

// MARK: - InnerTubeAuthHeaders

struct InnerTubeAuthHeaders {
    let headers: [String: String]
    let authenticated: Bool
    let authIdentityGeneration: UInt64?
    let allowsGuestAuthentication: Bool
}

// MARK: - InnerTubeClientProfile

struct InnerTubeClientProfile {
    let clientName: String
    let clientVersion: String
    let origin: String
    let baseURL: String
    let includeExperiments: Bool
    let logLabel: String
    let telemetryPrefix: String?
}

// MARK: - InnerTubeAuthProvider

/// Builds and validates InnerTube authentication headers for a specific origin.
@MainActor
final class InnerTubeAuthProvider {
    private let authService: AuthService
    private let webKitManager: WebKitManager
    private let origin: String
    private let cookieDomain: String
    private let logLabel: String
    private let logger = DiagnosticsLogger.api

    init(
        authService: AuthService,
        webKitManager: WebKitManager,
        origin: String,
        cookieDomain: String = "youtube.com",
        logLabel: String
    ) {
        self.authService = authService
        self.webKitManager = webKitManager
        self.origin = origin
        self.cookieDomain = cookieDomain
        self.logLabel = logLabel
    }

    func canUseAuthenticatedSession(allowGuestAuthentication: Bool) -> Bool {
        self.authService.hasPersonalAccount
            || (allowGuestAuthentication
                && self.authService.state.isLoggedIn
                && self.authService.isGuestModeEnabled)
    }

    func validateAuthIdentity(
        authenticated: Bool,
        generation: UInt64?,
        allowGuestAuthentication: Bool = false
    ) throws {
        guard authenticated else { return }
        guard let generation,
              generation == self.authService.accountIdentityGeneration,
              self.canUseAuthenticatedSession(allowGuestAuthentication: allowGuestAuthentication)
        else {
            throw CancellationError()
        }
    }

    func buildRequestHeaders(
        authPolicy: InnerTubeAuthPolicy,
        allowGuestAuthentication: Bool = false
    ) async throws -> InnerTubeAuthHeaders {
        let canAuthenticate = self.canUseAuthenticatedSession(allowGuestAuthentication: allowGuestAuthentication)
        if canAuthenticate {
            let authIdentityGeneration = self.authService.accountIdentityGeneration
            do {
                let headers = try await self.buildAuthHeaders()
                try self.validateAuthIdentity(
                    authenticated: true,
                    generation: authIdentityGeneration,
                    allowGuestAuthentication: allowGuestAuthentication
                )
                return InnerTubeAuthHeaders(
                    headers: headers,
                    authenticated: true,
                    authIdentityGeneration: authIdentityGeneration,
                    allowsGuestAuthentication: allowGuestAuthentication
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                try self.validateAuthIdentity(
                    authenticated: true,
                    generation: authIdentityGeneration,
                    allowGuestAuthentication: allowGuestAuthentication
                )
                self.authService.sessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                throw YTMusicError.authExpired
            }
        } else if authPolicy == .required {
            throw YTMusicError.notAuthenticated
        }

        return InnerTubeAuthHeaders(
            headers: self.buildUnauthenticatedHeaders(),
            authenticated: false,
            authIdentityGeneration: nil,
            allowsGuestAuthentication: false
        )
    }

    func handleSessionExpired(ifIdentityGenerationMatches generation: UInt64) {
        self.authService.sessionExpired(ifIdentityGenerationMatches: generation)
    }

    private func buildAuthHeaders() async throws -> [String: String] {
        // Snapshot cookies once per request; deriving the cookie header and SAPISID from
        // the same snapshot avoids repeated WebKit cookie-store enumerations during API fanout.
        let authMaterial = await self.webKitManager.authMaterial(for: self.cookieDomain)
        self.logger.debug(
            "Building \(self.logLabel) auth headers - total cookies: \(authMaterial.totalCookieCount), \(self.cookieDomain) cookies: \(authMaterial.domainCookieCount)"
        )

        guard let cookieHeader = authMaterial.cookieHeader else {
            self.logger.error("No cookies found for \(self.cookieDomain) domain")
            throw YTMusicError.notAuthenticated
        }

        guard let sapisid = authMaterial.sapisid else {
            self.logger.error("SAPISID cookie not found or expired")
            throw YTMusicError.authExpired
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let sapisidhash = InnerTubeSupport.sapisidHash(
            sapisid: sapisid,
            origin: self.origin,
            timestamp: timestamp
        )

        return [
            "Cookie": cookieHeader,
            "Authorization": "SAPISIDHASH \(sapisidhash)",
            "Origin": self.origin,
            "Referer": self.origin,
            "Content-Type": "application/json",
            // Kaset's account model is primary + brand accounts: selection is
            // expressed via context.user.onBehalfOfUser (brandIdProvider), not
            // the authuser index.
            "X-Goog-AuthUser": "0",
            "X-Origin": self.origin,
        ]
    }

    private func buildUnauthenticatedHeaders() -> [String: String] {
        [
            "Origin": self.origin,
            "Referer": self.origin,
            "Content-Type": "application/json",
        ]
    }
}

// MARK: - InnerTubeTransport

/// Shared transport, context building, and in-flight read coalescing for InnerTube clients.
@MainActor
final class InnerTubeTransport {
    private struct Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    @MainActor
    private final class InFlightJSONRequest {
        let id = UUID()
        let generation: Int
        var task: Task<Void, Never>?
        var waiters: [Waiter] = []
        var result: Result<[String: Any], Error>?

        init(generation: Int) {
            self.generation = generation
        }
    }

    let profile: InnerTubeClientProfile
    let authProvider: InnerTubeAuthProvider
    let session: URLSession
    private let logger = DiagnosticsLogger.api
    private var inFlightJSONRequests: [String: InFlightJSONRequest] = [:]

    init(
        profile: InnerTubeClientProfile,
        authProvider: InnerTubeAuthProvider,
        session: URLSession
    ) {
        self.profile = profile
        self.authProvider = authProvider
        self.session = session
    }

    func clearInFlightRequests() {
        self.inFlightJSONRequests.removeAll()
    }

    /// Coalesces identical concurrent cacheable JSON read requests by cache key.
    func coalesceJSONRequest(
        cacheKey: String,
        generation: Int,
        operation: @MainActor @escaping () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        try Task.checkCancellation()

        let entry: InFlightJSONRequest
        if let existing = self.inFlightJSONRequests[cacheKey], existing.generation == generation {
            self.logger.debug("Coalescing in-flight \(self.profile.logLabel) request for key \(cacheKey)")
            entry = existing
        } else {
            let newEntry = InFlightJSONRequest(generation: generation)
            self.inFlightJSONRequests[cacheKey] = newEntry
            entry = newEntry

            newEntry.task = Task { @MainActor in
                let result: Result<[String: Any], Error>
                do {
                    result = try await .success(operation())
                } catch {
                    result = .failure(error)
                }

                if self.inFlightJSONRequests[cacheKey]?.id == newEntry.id {
                    self.inFlightJSONRequests.removeValue(forKey: cacheKey)
                }
                newEntry.result = result
                let waiters = newEntry.waiters
                newEntry.waiters.removeAll()
                for waiter in waiters {
                    waiter.continuation.resume()
                }
            }
        }

        if entry.result == nil {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await self.awaitEntry(entry, waiterID: waiterID, cacheKey: cacheKey)
            } onCancel: {
                Task { @MainActor in
                    self.cancelWaiter(id: waiterID, for: entry, cacheKey: cacheKey)
                }
            }
        }
        try Task.checkCancellation()
        guard let result = entry.result else {
            throw CancellationError()
        }
        return try result.get()
    }

    private func awaitEntry(
        _ entry: InFlightJSONRequest,
        waiterID: UUID,
        cacheKey: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                self.cancelInFlightEntryIfAbandoned(entry, cacheKey: cacheKey)
                return
            }
            if entry.result != nil {
                continuation.resume()
                return
            }
            entry.waiters.append(Waiter(id: waiterID, continuation: continuation))
        }
    }

    private func cancelWaiter(id waiterID: UUID, for entry: InFlightJSONRequest, cacheKey: String) {
        guard let index = entry.waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        let waiter = entry.waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        self.cancelInFlightEntryIfAbandoned(entry, cacheKey: cacheKey)
    }

    private func cancelInFlightEntryIfAbandoned(_ entry: InFlightJSONRequest, cacheKey: String) {
        guard entry.waiters.isEmpty, entry.result == nil else {
            return
        }
        if self.inFlightJSONRequests[cacheKey]?.id == entry.id {
            self.inFlightJSONRequests.removeValue(forKey: cacheKey)
        }
        entry.task?.cancel()
    }

    /// Builds the standard InnerTube `context` dictionary.
    func buildContext(authenticated: Bool, brandId: String?) -> [String: Any] {
        var userDict: [String: Any] = [
            "lockedSafetyMode": false,
        ]

        // Add brand account ID only when this request is actually authenticated.
        // Signed-out requests must look like a normal public web request and must
        // not carry a stale delegated identity in the body.
        if authenticated, let brandId {
            userDict["onBehalfOfUser"] = brandId
        }

        var clientDict: [String: Any] = [
            "clientName": self.profile.clientName,
            "clientVersion": self.profile.clientVersion,
            "hl": SettingsManager.shared.contentLanguage.apiLanguageCode,
            "gl": SettingsManager.shared.contentLanguage.apiRegionCode,
            "browserName": "Safari",
            "browserVersion": "17.0",
            "osName": "Macintosh",
            "osVersion": "10_15_7",
            "platform": "DESKTOP",
            "userAgent": APISessionConfiguration.userAgent,
            "utcOffsetMinutes": InnerTubeSupport.utcOffsetMinutes(for: .current),
        ]

        if self.profile.includeExperiments {
            clientDict["experimentIds"] = []
            clientDict["experimentsToken"] = ""
        }

        return [
            "client": clientDict,
            "user": userDict,
        ]
    }

    func performRequest(
        _ endpoint: String,
        fullBody: [String: Any],
        requestAuth: InnerTubeAuthHeaders,
        queryItems: [URLQueryItem] = [URLQueryItem(name: "prettyPrint", value: "false")]
    ) async throws -> [String: Any] {
        let data = try await self.performRequestData(
            endpoint,
            fullBody: fullBody,
            requestAuth: requestAuth,
            queryItems: queryItems
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let telemetryPrefix = self.profile.telemetryPrefix {
                Telemetry.report("\(telemetryPrefix).parse_fail", ["endpoint": endpoint])
            }
            throw YTMusicError.parseError(message: "Response is not a JSON object")
        }
        return json
    }

    func performRequestData(
        _ endpoint: String,
        fullBody: [String: Any],
        requestAuth: InnerTubeAuthHeaders,
        queryItems: [URLQueryItem] = [URLQueryItem(name: "prettyPrint", value: "false")]
    ) async throws -> Data {
        let authenticated = requestAuth.authenticated
        let authIdentityGeneration = requestAuth.authIdentityGeneration
        let allowGuestAuthentication = requestAuth.allowsGuestAuthentication

        try self.authProvider.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration,
            allowGuestAuthentication: allowGuestAuthentication
        )

        var components = URLComponents(string: "\(self.profile.baseURL)/\(endpoint)")
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw YTMusicError.unknown(message: "Invalid API URL for endpoint: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = authenticated

        for (key, value) in requestAuth.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        self.logger.debug("Making \(self.profile.logLabel) request to \(endpoint)")

        let result = try await Self.performNetworkRequest(request: request, session: self.session)
        try self.authProvider.validateAuthIdentity(
            authenticated: authenticated,
            generation: authIdentityGeneration,
            allowGuestAuthentication: allowGuestAuthentication
        )

        switch result {
        case let .success(data):
            return data
        case let .authError(statusCode):
            self.logger.error("\(self.profile.logLabel) auth error: HTTP \(statusCode)")
            if authenticated {
                if let authIdentityGeneration {
                    self.authProvider.handleSessionExpired(ifIdentityGenerationMatches: authIdentityGeneration)
                }
                throw YTMusicError.authExpired
            }
            throw YTMusicError.notAuthenticated
        case let .httpError(statusCode):
            self.logger.error("\(self.profile.logLabel) API error: HTTP \(statusCode)")
            if let telemetryPrefix = self.profile.telemetryPrefix {
                Telemetry.report("\(telemetryPrefix).http_error", ["endpoint": endpoint, "code": "\(statusCode)"])
            }
            throw YTMusicError.apiError(message: "HTTP \(statusCode)", code: statusCode)
        case let .networkError(error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw YTMusicError.networkError(underlying: error)
        }
    }

    // MARK: - Nonisolated Network Helper

    private enum NetworkResult {
        case success(Data)
        case authError(statusCode: Int)
        case httpError(statusCode: Int)
        case networkError(Error)
    }

    // swiftformat:disable:next modifierOrder
    nonisolated private static func performNetworkRequest(
        request: URLRequest,
        session: URLSession
    ) async throws -> NetworkResult {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError(URLError(.badServerResponse))
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .authError(statusCode: httpResponse.statusCode)
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                return .httpError(statusCode: httpResponse.statusCode)
            }

            return .success(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return .networkError(error)
        }
    }
}

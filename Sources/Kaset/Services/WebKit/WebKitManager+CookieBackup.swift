import Foundation
import WebKit

// MARK: - CookieArchiveBackupAction

enum CookieArchiveBackupAction: Equatable, Sendable {
    case persist(data: Data, cookieCount: Int)
    case invalidate
    case retainExisting

    static func make(from result: CookieArchiveEncodingResult) -> CookieArchiveBackupAction {
        switch result {
        case let .archive(data, cookieCount):
            .persist(data: data, cookieCount: cookieCount)
        case .noPrimarySession:
            .invalidate
        case .failure:
            .retainExisting
        }
    }
}

// MARK: - CookieArchiveSnapshot

struct CookieArchiveSnapshot: Equatable, Sendable {
    let data: Data
    let cookieCount: Int
    let primarySessionValue: String?
    let stabilityFingerprint: Data

    static func == (lhs: CookieArchiveSnapshot, rhs: CookieArchiveSnapshot) -> Bool {
        lhs.stabilityFingerprint == rhs.stabilityFingerprint
    }

    static func make(from cookies: [HTTPCookie]) -> CookieArchiveSnapshot? {
        let validCookies = cookies.filter { KeychainCookieStorage.isValidAuthCookie($0) }
        guard let archive = KeychainCookieStorage.makeArchiveData(from: validCookies) else {
            return nil
        }

        let entries = validCookies
            .map(CookieArchiveStabilityEntry.init(cookie:))
            .sorted { lhs, rhs in
                lhs.sortKey.lexicographicallyPrecedes(rhs.sortKey)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let stabilityFingerprint = try? encoder.encode(entries) else { return nil }

        let youtubeCookies = WebKitManager.cookies(
            validCookies,
            matching: "youtube.com"
        )
        let secureSessionValue = youtubeCookies.first {
            $0.name == WebKitManager.authCookieName
        }?.value
        let fallbackSessionValue = youtubeCookies.first {
            $0.name == WebKitManager.fallbackAuthCookieName
        }?.value
        return CookieArchiveSnapshot(
            data: archive.data,
            cookieCount: archive.cookieCount,
            primarySessionValue: secureSessionValue ?? fallbackSessionValue,
            stabilityFingerprint: stabilityFingerprint
        )
    }
}

// MARK: - CookieArchiveVerificationState

enum CookieArchiveVerificationState: Sendable {
    case noValidAuthCookies
    case snapshot(CookieArchiveSnapshot)
    case invalid

    static func make(from cookies: [HTTPCookie]) -> CookieArchiveVerificationState {
        let validCookies = cookies.filter { KeychainCookieStorage.isValidAuthCookie($0) }
        guard !validCookies.isEmpty else { return .noValidAuthCookies }
        guard let snapshot = CookieArchiveSnapshot.make(from: validCookies) else { return .invalid }
        return .snapshot(snapshot)
    }

    func matches(_ expected: CookieArchiveVerificationState) -> Bool {
        switch (self, expected) {
        case (.noValidAuthCookies, .noValidAuthCookies):
            true
        case let (.snapshot(actual), .snapshot(expected)):
            actual == expected
        case (.invalid, _), (_, .invalid), (.noValidAuthCookies, .snapshot), (.snapshot, .noValidAuthCookies):
            false
        }
    }
}

// MARK: - CookieArchiveStabilityEntry

struct CookieArchiveStabilityEntry: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let isSessionOnly: Bool
    let sameSitePolicy: String?

    init(cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain.lowercased()
        self.path = cookie.path
        self.expiresDate = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
        self.isSessionOnly = cookie.isSessionOnly
        self.sameSitePolicy = cookie.sameSitePolicy?.rawValue.lowercased() ?? "none"
    }

    var sortKey: [String] {
        [self.domain, self.path, self.name, self.value]
    }
}

// MARK: - LoginCookieVerificationState

struct LoginCookieVerificationState: Equatable, Sendable {
    let entries: [CookieArchiveStabilityEntry]

    static func make(
        from cookies: [HTTPCookie],
        expirationCutoff: Date = Date()
    ) -> LoginCookieVerificationState {
        let entries = cookies
            .filter { cookie in
                guard KeychainCookieStorage.isLoginDomainCookie(cookie) else { return false }
                guard let expiresDate = cookie.expiresDate else { return true }
                return expiresDate > expirationCutoff
            }
            .map(CookieArchiveStabilityEntry.init(cookie:))
            .sorted { lhs, rhs in
                lhs.sortKey.lexicographicallyPrecedes(rhs.sortKey)
            }
        return LoginCookieVerificationState(entries: entries)
    }
}

// MARK: - CookieArchiveWriteAttempt

struct CookieArchiveWriteAttempt: Sendable {
    let snapshot: CookieArchiveSnapshot
    let generation: UInt64
}

// MARK: - CookieBackupStabilizationResult

enum CookieBackupStabilizationResult: Equatable {
    case persisted
    case failed
    case cancelled
    case unstable
}

// MARK: - CookieBackupStabilizer

@MainActor
enum CookieBackupStabilizer {
    struct Operations {
        let prepareAttempt: () -> Void
        let makeAttempt: () async -> CookieArchiveWriteAttempt?
        let persist: (CookieArchiveWriteAttempt) async -> CookieArchiveSaveResult
        let readVerificationSnapshot: () async -> CookieArchiveSnapshot?
        let isDirty: () -> Bool
        let canContinue: () -> Bool
    }

    static func persistStableSnapshot(
        maxAttempts: Int,
        operations: Operations
    ) async -> CookieBackupStabilizationResult {
        guard maxAttempts > 0 else { return .unstable }

        for _ in 0 ..< maxAttempts {
            guard operations.canContinue() else { return .cancelled }
            operations.prepareAttempt()

            guard let attempt = await operations.makeAttempt() else {
                return operations.canContinue() ? .failed : .cancelled
            }
            guard operations.canContinue() else { return .cancelled }

            let saveResult = await operations.persist(attempt)
            switch saveResult {
            case .failed:
                return .failed
            case .superseded:
                guard operations.canContinue() else { return .cancelled }
                continue
            case .saved, .alreadyCurrent:
                break
            }

            guard operations.canContinue() else { return .cancelled }
            guard let verificationSnapshot = await operations.readVerificationSnapshot() else {
                return operations.canContinue() ? .failed : .cancelled
            }

            // Give already-enqueued observer callbacks a chance to mark the
            // snapshot dirty, but verify freshness directly instead of treating
            // observer delivery as a synchronization barrier.
            await Task.yield()
            guard operations.canContinue() else { return .cancelled }

            guard let isStable = await self.isStable(
                attempt: attempt.snapshot,
                verification: verificationSnapshot,
                operations: operations
            ) else {
                return operations.canContinue() ? .failed : .cancelled
            }
            if isStable {
                return .persisted
            }
        }

        return .unstable
    }

    private static func isStable(
        attempt: CookieArchiveSnapshot,
        verification: CookieArchiveSnapshot,
        operations: Operations
    ) async -> Bool? {
        guard attempt == verification else { return false }
        guard operations.isDirty() else { return true }
        operations.prepareAttempt()
        guard let postCallbackSnapshot = await operations.readVerificationSnapshot() else {
            return nil
        }
        await Task.yield()
        guard !operations.isDirty() else { return false }
        return attempt == postCallbackSnapshot
    }
}

// MARK: - LiveCookieRollbackResult

enum LiveCookieRollbackResult {
    case restored
    case superseded
    case failed
}

// MARK: - LoginCookieBackupBaseline

struct LoginCookieBackupBaseline {
    let liveBaseline: CookieArchiveLiveBaseline
    let authSnapshot: CookieArchiveSnapshot?
    let loginCookies: [HTTPCookie]
}

// MARK: - WebKitManager + Login Baseline Matching

extension WebKitManager {
    static func loginCookieBaselineMatches(
        expectedAuthSnapshot: CookieArchiveSnapshot?,
        expectedLoginCookies: [HTTPCookie],
        currentCookies: [HTTPCookie]
    ) -> Bool {
        let currentAuthCookies = currentCookies.filter(KeychainCookieStorage.isAuthCookie)
        let currentAuthSnapshot = CookieArchiveSnapshot.make(from: currentAuthCookies)
        let authSnapshotMatches = expectedAuthSnapshot?.stabilityFingerprint
            == currentAuthSnapshot?.stabilityFingerprint
        let expectedLoginState = LoginCookieVerificationState.make(from: expectedLoginCookies)
        let currentLoginState = LoginCookieVerificationState.make(from: currentCookies)
        return authSnapshotMatches && expectedLoginState == currentLoginState
    }
}

// MARK: - WebKitManager + WKHTTPCookieStoreObserver

extension WebKitManager: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            self.cookieArchiveManager.handleObservedCookieChange(in: cookieStore)
        }
    }
}

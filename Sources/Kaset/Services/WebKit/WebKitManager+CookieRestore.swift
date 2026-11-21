import Foundation

// MARK: - CookieRestoreResult

enum CookieRestoreResult: Equatable, Sendable {
    case ready
    case unavailable
    case failed
}


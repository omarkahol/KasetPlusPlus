import Foundation
import Security

// MARK: - KeychainCredentialStore

/// Thin Keychain wrapper for storing scrobbling service credentials.
/// Uses `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlock`.
@MainActor
final class KeychainCredentialStore {
    private let servicePrefix: String

    #if DEBUG
        private static let debugCookieStorageEnvironmentKey = "KASET_DEBUG_COOKIE_STORAGE"

        private static var usesDebugFileStorage: Bool {
            ProcessInfo.processInfo.environment[Self.debugCookieStorageEnvironmentKey]?.lowercased() != "keychain"
        }

        private var debugCredentialsFileURL: URL? {
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            let sanitizedPrefix = self.servicePrefix.replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "_",
                options: .regularExpression
            )
            return appSupport
                .appendingPathComponent("Kaset", isDirectory: true)
                .appendingPathComponent("debug-credentials", isDirectory: true)
                .appendingPathComponent("\(sanitizedPrefix).json")
        }
    #endif

    /// Creates a credential store with the given service prefix.
    /// - Parameter servicePrefix: Prefix for Keychain entries (default: "com.sertacozercan.Kaset").
    init(servicePrefix: String = "com.sertacozercan.Kaset") {
        self.servicePrefix = servicePrefix
    }

    // MARK: - Public API

    /// Saves the Last.fm session key to Keychain.
    func saveLastFMSessionKey(_ sessionKey: String) throws {
        try self.save(key: "lastFMSessionKey", value: sessionKey)
    }

    /// Retrieves the stored Last.fm session key, if any.
    func getLastFMSessionKey() -> String? {
        self.get(key: "lastFMSessionKey")
    }

    /// Saves the Last.fm username to Keychain.
    func saveLastFMUsername(_ username: String) throws {
        try self.save(key: "lastFMUsername", value: username)
    }

    /// Retrieves the stored Last.fm username, if any.
    func getLastFMUsername() -> String? {
        self.get(key: "lastFMUsername")
    }

    /// Removes all Last.fm credentials from Keychain.
    func removeLastFMCredentials() {
        self.delete(key: "lastFMSessionKey")
        self.delete(key: "lastFMUsername")
    }

    /// Saves the ListenBrainz user token to Keychain.
    func saveListenBrainzToken(_ token: String) throws {
        try self.save(key: "listenBrainzToken", value: token)
    }

    /// Retrieves the stored ListenBrainz user token, if any.
    func getListenBrainzToken() -> String? {
        self.get(key: "listenBrainzToken")
    }

    /// Saves the ListenBrainz username to Keychain.
    func saveListenBrainzUsername(_ username: String) throws {
        try self.save(key: "listenBrainzUsername", value: username)
    }

    /// Retrieves the stored ListenBrainz username, if any.
    func getListenBrainzUsername() -> String? {
        self.get(key: "listenBrainzUsername")
    }

    /// Removes all ListenBrainz credentials from Keychain.
    func removeListenBrainzCredentials() {
        self.delete(key: "listenBrainzToken")
        self.delete(key: "listenBrainzUsername")
    }

    /// Saves the GitHub (community) OAuth access token to Keychain.
    func saveGitHubToken(_ token: String) throws {
        try self.save(key: "gitHubToken", value: token)
    }

    /// Retrieves the stored GitHub access token, if any.
    func getGitHubToken() -> String? {
        self.get(key: "gitHubToken")
    }

    /// Removes the stored GitHub access token.
    func removeGitHubToken() {
        self.delete(key: "gitHubToken")
    }

    // MARK: - Private Helpers

    private func save(key: String, value: String) throws {
        #if DEBUG
            if Self.usesDebugFileStorage {
                try self.saveToDebugFile(key: key, value: value)
                return
            }
        #endif

        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let account = "\(self.servicePrefix).\(key)"

        // Try to update existing item first
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: self.servicePrefix,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            var addQuery = updateQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(status: updateStatus)
        }
    }

    private func get(key: String) -> String? {
        #if DEBUG
            if Self.usesDebugFileStorage {
                return self.loadDebugCredentials()[key]
            }
        #endif

        let account = "\(self.servicePrefix).\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: self.servicePrefix,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    private func delete(key: String) {
        #if DEBUG
            if Self.usesDebugFileStorage {
                self.deleteFromDebugFile(key: key)
                return
            }
        #endif

        let account = "\(self.servicePrefix).\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: self.servicePrefix,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            DiagnosticsLogger.app.warning("Keychain delete failed for \(key) with status: \(status)")
        }
    }

    #if DEBUG
        private func loadDebugCredentials() -> [String: String] {
            guard let url = self.debugCredentialsFileURL,
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else {
                return [:]
            }
            return decoded
        }

        private func saveToDebugFile(key: String, value: String) throws {
            guard let url = self.debugCredentialsFileURL else {
                throw KeychainError.encodingFailed
            }
            var credentials = self.loadDebugCredentials()
            credentials[key] = value
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(credentials)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        private func deleteFromDebugFile(key: String) {
            guard let url = self.debugCredentialsFileURL else { return }
            var credentials = self.loadDebugCredentials()
            credentials.removeValue(forKey: key)
            if credentials.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder().encode(credentials) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    #endif
}

// MARK: - KeychainError

/// Errors that can occur during Keychain operations.
enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "Failed to encode value for Keychain storage."
        case let .saveFailed(status):
            "Keychain save failed with status: \(status)"
        }
    }
}

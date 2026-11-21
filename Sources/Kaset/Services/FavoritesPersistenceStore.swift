import Foundation

// MARK: - FavoritesPersistenceStore

/// Encapsulates disk persistence, legacy file migration, and scope-merge file operations
/// for `FavoritesManager`.
@MainActor
struct FavoritesPersistenceStore {
    struct ScopeMergeKey: Hashable {
        let sourceScopeID: String
        let targetScopeID: String
    }

    let storageDirectory: URL

    var legacyFavoritesURL: URL {
        self.storageDirectory.appendingPathComponent("favorites.json")
    }

    var ownerStateBackupURL: URL {
        self.storageDirectory.appendingPathComponent(".favorites-owner-state.json")
    }

    func fileURL(for scopeID: String) -> URL {
        self.storageDirectory.appendingPathComponent("favorites-\(scopeID).json")
    }

    func mergeBaselineURL(for key: ScopeMergeKey) -> URL {
        self.storageDirectory.appendingPathComponent(
            ".favorites-merge-\(key.sourceScopeID)-to-\(key.targetScopeID)-baseline.json"
        )
    }

    func preparedMergeURL(for key: ScopeMergeKey) -> URL {
        self.storageDirectory.appendingPathComponent(
            ".favorites-merge-\(key.sourceScopeID)-to-\(key.targetScopeID)-prepared.json"
        )
    }

    func legacyAccountFavoritesURL(accountID: String) -> URL? {
        guard accountID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return self.storageDirectory.appendingPathComponent("favorites-\(accountID).json")
    }

    func legacyClaimURL(for legacyURL: URL, boundTo targetScopeID: String) -> URL {
        let sourceID = FavoritesManager.hashID(for: Data(legacyURL.lastPathComponent.utf8))
        return self.storageDirectory.appendingPathComponent(
            ".favorites-legacy-claim-\(targetScopeID)-\(sourceID).json"
        )
    }

    func legacyClaimURLs(boundTo scopeID: String, legacyAccountID: String) -> [URL] {
        var legacyURLs = [self.legacyFavoritesURL]
        if let legacyAccountURL = self.legacyAccountFavoritesURL(accountID: legacyAccountID) {
            legacyURLs.append(legacyAccountURL)
        }
        return legacyURLs.map { self.legacyClaimURL(for: $0, boundTo: scopeID) }
    }

    // MARK: - Read / Write

    func loadItems(for scopeID: String) throws -> [FavoriteItem]? {
        let url = self.fileURL(for: scopeID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([FavoriteItem].self, from: data)
    }

    @discardableResult
    func write(_ items: [FavoriteItem], for scopeID: String) -> Bool {
        Self.write(items, to: self.fileURL(for: scopeID))
    }

    @discardableResult
    static func write(_ items: [FavoriteItem], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to save favorites: \(error.localizedDescription)")
            return false
        }
    }

    func loadOwnerStateBackup() -> Data? {
        guard FileManager.default.fileExists(atPath: self.ownerStateBackupURL.path) else {
            return nil
        }
        do {
            return try Data(contentsOf: self.ownerStateBackupURL)
        } catch {
            DiagnosticsLogger.ui.error("Failed to load favorites owner-state backup: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func saveOwnerStateBackup(_ data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: self.storageDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: self.ownerStateBackupURL, options: .atomic)
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to save favorites owner-state backup: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Legacy Migration

    func migrateLegacyFileIfNeeded(
        from legacyURL: URL,
        toScopeID targetScopeID: String
    ) -> FavoritesManager.LegacyMigrationResult {
        let targetURL = self.fileURL(for: targetScopeID)
        guard legacyURL != targetURL else { return .completed }

        let claimURL = self.legacyClaimURL(for: legacyURL, boundTo: targetScopeID)
        guard FileManager.default.fileExists(atPath: legacyURL.path)
            || FileManager.default.fileExists(atPath: claimURL.path)
        else { return .completed }

        do {
            try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: claimURL.path) {
                let result = self.commitLegacyClaim(at: claimURL, to: targetURL)
                guard result == .completed else { return result }
            }

            guard FileManager.default.fileExists(atPath: legacyURL.path) else { return .completed }
            guard FileManager.default.fileExists(atPath: targetURL.path) else {
                try FileManager.default.moveItem(at: legacyURL, to: targetURL)
                return .completed
            }

            // Consume the globally discoverable name before changing an existing destination.
            // A failed commit or cleanup can then only be resumed by this destination scope.
            try FileManager.default.moveItem(at: legacyURL, to: claimURL)
            return self.commitLegacyClaim(at: claimURL, to: targetURL)
        } catch {
            DiagnosticsLogger.ui.error("Failed to migrate favorites: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }
    }

    private func commitLegacyClaim(at claimURL: URL, to targetURL: URL) -> FavoritesManager.LegacyMigrationResult {
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            do {
                try FileManager.default.moveItem(at: claimURL, to: targetURL)
                return .completed
            } catch {
                DiagnosticsLogger.ui.error("Failed to promote favorites claim: \(error.localizedDescription)")
                return .requiresReadOnlyRetry
            }
        }

        let claimData: Data
        do {
            claimData = try Data(contentsOf: claimURL)
        } catch {
            DiagnosticsLogger.ui.error("Cannot read legacy favorites claim: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }

        let claimedItems: [FavoriteItem]
        do {
            claimedItems = try JSONDecoder().decode([FavoriteItem].self, from: claimData)
        } catch {
            DiagnosticsLogger.ui.error("Deferring malformed legacy favorites claim: \(error.localizedDescription)")
            return .deferred
        }

        let existingItems: [FavoriteItem]
        do {
            existingItems = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: targetURL))
        } catch {
            DiagnosticsLogger.ui.error("Cannot merge favorites into an invalid target: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }

        do {
            try JSONEncoder().encode(FavoritesManager.merging(existingItems, appending: claimedItems))
                .write(to: targetURL, options: .atomic)
            try FileManager.default.removeItem(at: claimURL)
            return .completed
        } catch {
            DiagnosticsLogger.ui.error("Failed to commit favorites claim: \(error.localizedDescription)")
            return .requiresReadOnlyRetry
        }
    }

    // MARK: - Scope Merge Persistence

    func prepareScopeMerge(
        from sourceScopeID: String,
        into targetScopeID: String,
        legacyAccountID: String,
        pendingItemsByScope: [String: [FavoriteItem]]
    ) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        let sourceURL = self.fileURL(for: sourceScopeID)
        let targetURL = self.fileURL(for: targetScopeID)
        let baselineURL = self.mergeBaselineURL(for: mergeKey)
        let preparedURL = self.preparedMergeURL(for: mergeKey)

        do {
            try FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
            var sourceItems: [FavoriteItem]?
            if let pendingSourceItems = pendingItemsByScope[sourceScopeID] {
                sourceItems = pendingSourceItems
            } else if FileManager.default.fileExists(atPath: sourceURL.path) {
                sourceItems = try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: sourceURL)
                )
            }
            for claimURL in self.legacyClaimURLs(
                boundTo: sourceScopeID,
                legacyAccountID: legacyAccountID
            ) where FileManager.default.fileExists(atPath: claimURL.path) {
                // Claims remain source-owned until owner migration commits and finalizes.
                let claimItems = try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: claimURL)
                )
                sourceItems = FavoritesManager.merging(sourceItems ?? [], appending: claimItems)
            }
            guard let sourceItems else { return true }

            let currentTargetItems: [FavoriteItem] = if let pendingTargetItems = pendingItemsByScope[targetScopeID] {
                pendingTargetItems
            } else if FileManager.default.fileExists(atPath: targetURL.path) {
                try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: targetURL)
                )
            } else {
                []
            }

            let baselineItems: [FavoriteItem]
            if FileManager.default.fileExists(atPath: baselineURL.path) {
                baselineItems = try JSONDecoder().decode(
                    [FavoriteItem].self,
                    from: Data(contentsOf: baselineURL)
                )
            } else {
                baselineItems = currentTargetItems
                try JSONEncoder().encode(baselineItems).write(to: baselineURL, options: .atomic)
            }
            let previousPreparedItems: [FavoriteItem]? = if FileManager.default.fileExists(atPath: preparedURL.path) {
                try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: preparedURL))
            } else {
                nil
            }
            let targetOwnedItems = FavoritesManager.targetOwnedItems(
                baselineItems: baselineItems,
                currentTargetItems: currentTargetItems,
                previousPreparedItems: previousPreparedItems
            )
            try JSONEncoder().encode(targetOwnedItems).write(to: baselineURL, options: .atomic)
            try JSONEncoder().encode(FavoritesManager.merging(targetOwnedItems, appending: sourceItems))
                .write(to: preparedURL, options: .atomic)
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to merge favorites scopes: \(error.localizedDescription)")
            return false
        }
    }

    func commitScopeMerge(from sourceScopeID: String, into targetScopeID: String) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        let preparedURL = self.preparedMergeURL(for: mergeKey)
        guard FileManager.default.fileExists(atPath: preparedURL.path) else { return true }
        let targetURL = self.fileURL(for: targetScopeID)
        do {
            let preparedData = try Data(contentsOf: preparedURL)
            try preparedData.write(to: targetURL, options: .atomic)
            return true
        } catch {
            DiagnosticsLogger.ui.error("Failed to commit favorites scope merge: \(error.localizedDescription)")
            return false
        }
    }

    func canFinalizeScopeMerge(
        from sourceScopeID: String,
        into targetScopeID: String,
        legacyAccountID: String,
        pendingItemsByScope: [String: [FavoriteItem]]
    ) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        let targetURL = self.fileURL(for: targetScopeID)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            do {
                _ = try JSONDecoder().decode([FavoriteItem].self, from: Data(contentsOf: targetURL))
                return true
            } catch {
                DiagnosticsLogger.ui.error("Cannot finalize favorites migration with an invalid target: \(error.localizedDescription)")
                return false
            }
        }

        // Empty accounts legitimately have no source, prepared merge, claims, or
        // target file. They must not block finalization of other migrated scopes.
        let recoveryURLs = [
            self.fileURL(for: sourceScopeID),
            self.preparedMergeURL(for: mergeKey),
        ] + self.legacyClaimURLs(
            boundTo: sourceScopeID,
            legacyAccountID: legacyAccountID
        )
        return pendingItemsByScope[sourceScopeID] == nil
            && recoveryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    func cleanupScopeMerge(
        from sourceScopeID: String,
        into targetScopeID: String,
        legacyAccountID: String
    ) -> Bool {
        let mergeKey = ScopeMergeKey(sourceScopeID: sourceScopeID, targetScopeID: targetScopeID)
        var didCleanup = true
        let cleanupURLs = [
            self.fileURL(for: sourceScopeID),
            self.mergeBaselineURL(for: mergeKey),
            self.preparedMergeURL(for: mergeKey),
        ] + self.legacyClaimURLs(
            boundTo: sourceScopeID,
            legacyAccountID: legacyAccountID
        )
        for url in cleanupURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                didCleanup = false
                DiagnosticsLogger.ui.error("Failed to clean up migrated favorites scope: \(error.localizedDescription)")
            }
        }
        return didCleanup
    }
}

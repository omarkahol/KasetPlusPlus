import Foundation
import os
import WebKit

// MARK: - CookieArchiveManager

/// Owns authentication cookie backup, startup restoration, rollback-safe login
/// transactions, and cookie-archive invalidation for a `WebKitManager` data store.
@MainActor
final class CookieArchiveManager {
    let dataStore: WKWebsiteDataStore
    let cookieArchiveQueue: CookieArchiveWriteQueue
    let logger = DiagnosticsLogger.webKit
    private let onCookiesDidChange: @MainActor () -> Void

    /// Flag to prevent cookie backups while restoring from Keychain.
    var isRestoringCookies = false

    /// Flag to prevent observer-driven backups while auth cookies are being cleared.
    var isClearingAuthCookies = false

    /// Serializes and coalesces every auth-cookie/data clearing operation.
    let authCookieClearCoordinator = AuthCookieClearCoordinator()

    /// Task for debouncing cookie change handling.
    var cookieDebounceTask: Task<Void, Never>?

    /// Coalesces callers that require the latest cookie snapshot to be persisted.
    var forcedCookieBackupTask: Task<Bool, Never>?

    /// Suppresses observer-driven persistence while a login baseline is captured.
    var isPreparingLoginCookieBackup = false

    /// Suppresses observer-driven persistence while a login backup is staged.
    var activeLoginCookieBackupTransaction: CookieBackupTransaction?

    /// Whether transaction setup failed to restore its prior durable state.
    var loginCookieBackupSetupRequiresCleanup = false

    /// Records cookie changes delivered while a forced snapshot is being persisted.
    var forcedCookieBackupDirty = false

    /// Coalesces startup restoration and retries after temporary storage failures.
    var initialCookieRestoreTask: Task<CookieRestoreResult, Never>?

    /// Authentication and archive writes stay blocked until restoration is resolved.
    var initialCookieRestoreResult: CookieRestoreResult = .ready

    /// Invalidates startup restores and backups that began before an auth-cookie clear.
    var authCookieOperationFence = AuthCookieOperationFence()

    init(
        dataStore: WKWebsiteDataStore,
        cookieArchiveQueue: CookieArchiveWriteQueue,
        onCookiesDidChange: @escaping @MainActor () -> Void
    ) {
        self.dataStore = dataStore
        self.cookieArchiveQueue = cookieArchiveQueue
        self.onCookiesDidChange = onCookiesDidChange
    }

    var canPersistAuthCookies: Bool {
        self.initialCookieRestoreResult == .ready
            && !self.isRestoringCookies
            && !self.isClearingAuthCookies
    }

    @discardableResult
    func invalidateAuthCookieRestoration() -> Bool {
        CookieArchiveRestorePolicy.invalidateAndAdvanceGeneration()
    }

    // MARK: - Startup Cookie Restoration

    func startInitialCookieRestore() {
        guard self.initialCookieRestoreTask == nil,
              !self.isClearingAuthCookies,
              !self.authCookieClearCoordinator.isBusy
        else { return }

        self.initialCookieRestoreResult = .unavailable
        let pendingBackup = self.cookieDebounceTask
        let forcedBackup = self.forcedCookieBackupTask
        pendingBackup?.cancel()
        forcedBackup?.cancel()
        self.cookieDebounceTask = nil
        let restoreGeneration = self.authCookieOperationFence.generation
        self.initialCookieRestoreTask = Task { @MainActor in
            await pendingBackup?.value
            _ = await forcedBackup?.value
            let result = await self.restoreAuthCookiesFromBackup(
                expectedGeneration: restoreGeneration
            )
            self.initialCookieRestoreResult = result
            self.initialCookieRestoreTask = nil
            return result
        }
    }

    /// Joins the current restore, or retries a previous non-destructive storage failure.
    func waitForInitialCookieRestore() async -> CookieRestoreResult {
        if self.initialCookieRestoreTask == nil, self.initialCookieRestoreResult == .unavailable {
            self.startInitialCookieRestore()
        }
        if let restoreTask = self.initialCookieRestoreTask {
            return await restoreTask.value
        }
        return self.initialCookieRestoreResult
    }

    /// Restores auth cookies from the configured archive storage to WebKit.
    /// Handles migration from legacy file-based storage on first run.
    func restoreAuthCookiesFromBackup(expectedGeneration: UInt64) async -> CookieRestoreResult {
        self.isRestoringCookies = true
        defer { self.isRestoringCookies = false }

        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        // Wait a moment for WebKit to fully initialize
        try? await Task.sleep(for: .milliseconds(100))
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        switch await self.cookieArchiveQueue.restoreDecision() {
        case .allowed:
            break
        case .denied:
            self.logger.info("Cookie backup restoration is disabled after explicit invalidation")
            let didDeletePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }
            let didClearLiveCookies = await self.clearLiveLoginSessionCookies(
                expectedGeneration: expectedGeneration
            )
            return didDeletePersistedCookies && didClearLiveCookies ? .ready : .failed
        case .unavailable:
            self.logger.error("Cookie restore policy could not be read; preserving live cookies and the archive for retry")
            return .unavailable
        }

        // Migrate from legacy file-based storage if needed (one-time operation).
        // Perform file I/O off the main actor.
        _ = await Task(priority: .utility) {
            LegacyCookieMigration.migrateIfNeeded()
        }.value
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        let existingCookies = await self.dataStore.httpCookieStore.allCookies()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }
        self.logger.info("WebKit has \(existingCookies.count) cookies on startup")

        // Archive I/O runs on the injected storage queue, never on the main actor.
        let archiveResult = await self.cookieArchiveQueue.loadArchiveResult()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        switch archiveResult {
        case .failure:
            self.logger.error("Cookie backup storage could not be read; preserving live cookies and the archive for retry")
            return .unavailable
        case .notFound:
            // Explicit invalidation persists a denied restore policy before it
            // deletes the archive. An allowed policy with no archive is not an
            // authoritative sign-out signal and may coexist with a live login.
            self.logger.info("No cookies found in archive storage; preserving the live WebKit session")
            return .ready
        case let .data(archiveData):
            // The persisted archive is the source of truth for login-session
            // state. Preserve unrelated Google/YouTube preference cookies.
            let liveLoginCookies = existingCookies.filter(KeychainCookieStorage.isLoginSessionCookie)
            guard await self.clearLiveLoginSessionCookies(
                expectedGeneration: expectedGeneration
            ) else { return .failed }
            if await self.restoreArchivedAuthCookies(
                archiveData,
                expectedGeneration: expectedGeneration
            ) {
                return .ready
            }
            // An unusable archive must not cost a working login. Roll the live
            // session back instead of quarantining it; the next backup
            // overwrites the archive with a good snapshot.
            return await self.rollBackLiveLoginSessionCookies(
                liveLoginCookies,
                expectedGeneration: expectedGeneration
            ) ? .ready : .failed
        }
    }

    private func restoreArchivedAuthCookies(
        _ archiveData: Data,
        expectedGeneration: UInt64
    ) async -> Bool {
        let keychainCookies = KeychainCookieStorage.decodeCookies(from: archiveData)
        guard !keychainCookies.isEmpty else {
            self.logger.error("Cookie archive contained no restorable authentication cookies")
            return false
        }
        let expectedState = CookieArchiveVerificationState.make(from: keychainCookies)
        guard case .snapshot = expectedState else {
            self.logger.error("Cookie archive could not produce a verifiable authentication snapshot")
            return false
        }
        let expectedPrimarySession = keychainCookies.contains { cookie in
            KeychainCookieStorage.isValidAuthCookie(cookie)
                && (cookie.name == "SAPISID" || cookie.name == "__Secure-3PAPISID")
        }
        guard expectedPrimarySession else {
            self.logger.error("Cookie archive does not contain a primary authentication cookie")
            return false
        }

        #if DEBUG
            await self.cookieArchiveQueue.exportDebugArchiveIfEnabled(archiveData)
        #endif

        self.logger.info("Restoring \(keychainCookies.count) auth cookies from Keychain")
        for cookie in keychainCookies {
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
            await self.dataStore.httpCookieStore.setCookie(cookie)
        }
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }

        let cookies = await self.dataStore.httpCookieStore.allCookies()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
        let restoredState = CookieArchiveVerificationState.make(from: cookies)
        let didRestore = restoredState.matches(expectedState)
        guard didRestore else {
            self.logger.error("✗ Failed to restore auth cookies - Keychain data may be corrupted")
            return false
        }
        self.logger.info("✓ Auth cookies restored from Keychain (\(cookies.count) total cookies)")

        return true
    }

    /// Puts the pre-restore login session back after an unusable archive.
    /// Returns whether a primary session is live again.
    private func rollBackLiveLoginSessionCookies(
        _ cookies: [HTTPCookie],
        expectedGeneration: UInt64
    ) async -> Bool {
        guard cookies.contains(where: { KeychainCookieStorage.isValidAuthCookie($0) }) else { return false }
        guard await self.clearLiveLoginSessionCookies(
            expectedGeneration: expectedGeneration
        ) else { return false }
        for cookie in cookies {
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
            await self.dataStore.httpCookieStore.setCookie(cookie)
        }
        self.logger.info("Rolled back to the live login session after an unusable cookie archive")
        return true
    }

    func quarantineFailedAuthCookieRestore(expectedGeneration: UInt64) async -> Bool {
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else {
            return false
        }
        let didInvalidateRestore = self.invalidateAuthCookieRestoration()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else {
            return false
        }
        let didClearLiveCookies = await self.clearLiveLoginSessionCookies(
            expectedGeneration: expectedGeneration
        )
        if !didInvalidateRestore || !didClearLiveCookies {
            self.logger.error("Failed to fully quarantine an invalid authentication-cookie restore")
        }
        return didInvalidateRestore && didClearLiveCookies
    }

    private func clearLiveLoginSessionCookies(expectedGeneration: UInt64) async -> Bool {
        for _ in 0 ..< 3 {
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
            let liveCookies = await self.dataStore.httpCookieStore.allCookies()
            for cookie in liveCookies where KeychainCookieStorage.isLoginSessionCookie(cookie) {
                await self.dataStore.httpCookieStore.deleteCookie(cookie)
            }
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
            let remainingCookies = await self.dataStore.httpCookieStore.allCookies()
            if !remainingCookies.contains(where: KeychainCookieStorage.isLoginSessionCookie) {
                return true
            }
            await Task.yield()
        }

        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
        self.logger.error("Could not clear live login-session cookies from WebKit")
        return false
    }

    private func canContinueAuthCookieOperation(expectedGeneration: UInt64) -> Bool {
        !Task.isCancelled && self.authCookieOperationFence.isCurrent(expectedGeneration)
    }

    // MARK: - Auth Cookie Clearing

    @discardableResult
    func clearAuthCookies() async -> Bool {
        await self.authCookieClearCoordinator.run(scope: .authenticationCookies) { [weak self] in
            guard let self else { return false }
            return await self.performAuthCookieClear()
        }
    }

    private func performAuthCookieClear() async -> Bool {
        self.logger.info("Clearing WebKit auth cookies")
        self.isClearingAuthCookies = true
        defer { self.isClearingAuthCookies = false }

        await self.fenceAuthCookieOperationsAndInvalidateBackup()

        let didInvalidatePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()

        let liveClearResult = await LiveAuthCookieStoreClearer.clear(
            operations: LiveAuthCookieStoreClearer.Operations(
                readCookies: {
                    await self.dataStore.httpCookieStore.allCookies()
                },
                deleteCookie: { cookie in
                    await self.dataStore.httpCookieStore.deleteCookie(cookie)
                },
                removeAllCookies: {
                    await self.dataStore.removeData(
                        ofTypes: [WKWebsiteDataTypeCookies],
                        modifiedSince: .distantPast
                    )
                }
            )
        )
        if liveClearResult.usedCookieStoreFallback {
            self.logger.warning("Escalated authentication cleanup to the WebKit cookie data store")
        }
        if !liveClearResult.didClear {
            self.logger.error("Could not clear live authentication cookies")
        }

        let didClear = liveClearResult.didClear && didInvalidatePersistedCookies
        self.initialCookieRestoreResult = didClear ? .ready : .failed
        self.loginCookieBackupSetupRequiresCleanup = !didClear
        self.onCookiesDidChange()
        return didClear
    }

    @discardableResult
    func clearAllData() async -> Bool {
        await self.authCookieClearCoordinator.run(scope: .allWebsiteData) { [weak self] in
            guard let self else { return false }
            return await self.performAllWebsiteDataClear()
        }
    }

    private func performAllWebsiteDataClear() async -> Bool {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let dateFrom = Date.distantPast

        self.logger.info("Clearing all WebKit data")
        self.isClearingAuthCookies = true
        defer { self.isClearingAuthCookies = false }

        await self.fenceAuthCookieOperationsAndInvalidateBackup()
        await self.dataStore.removeData(ofTypes: allTypes, modifiedSince: dateFrom)

        let didInvalidatePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()
        let remainingCookies = await self.dataStore.httpCookieStore.allCookies()
        let didClearLiveCookies = !remainingCookies.contains(where: KeychainCookieStorage.isLoginDomainCookie)
        let didClear = didInvalidatePersistedCookies && didClearLiveCookies
        self.initialCookieRestoreResult = didClear ? .ready : .failed
        self.loginCookieBackupSetupRequiresCleanup = !didClear
        if didClear {
            self.logger.info("WebKit data cleared successfully")
        } else {
            self.logger.error("WebKit data or durable cookie invalidation could not be cleared")
        }
        self.onCookiesDidChange()
        return didClear
    }

    func fenceAuthCookieOperationsAndInvalidateBackup() async {
        self.authCookieOperationFence.invalidate()
        self.activeLoginCookieBackupTransaction = nil
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil

        let restoreTask = self.initialCookieRestoreTask
        let backupTask = self.forcedCookieBackupTask
        restoreTask?.cancel()
        backupTask?.cancel()

        _ = await self.cookieArchiveQueue.invalidateAndDelete()
        _ = await restoreTask?.value
        _ = await backupTask?.value
    }

    // MARK: - Login Cookie Backup & Rollback

    /// Starts a rollback-safe persistence transaction before the login WebView
    /// can change authentication cookies.
    func beginLoginCookieBackup() async -> CookieBackupTransaction? {
        switch await self.waitForInitialCookieRestore() {
        case .ready:
            break
        case .unavailable:
            return nil
        case .failed:
            self.loginCookieBackupSetupRequiresCleanup = true
            return nil
        }
        guard !self.isRestoringCookies,
              !self.isClearingAuthCookies,
              !self.authCookieClearCoordinator.isBusy,
              !self.loginCookieBackupSetupRequiresCleanup,
              !self.isPreparingLoginCookieBackup,
              self.activeLoginCookieBackupTransaction == nil,
              self.forcedCookieBackupTask == nil
        else { return nil }
        let expectedOperationGeneration = self.authCookieOperationFence.generation
        self.isPreparingLoginCookieBackup = true
        self.forcedCookieBackupDirty = false
        defer { self.isPreparingLoginCookieBackup = false }
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil

        guard let baseline = await self.captureLoginCookieBackupBaseline(
            expectedOperationGeneration: expectedOperationGeneration
        ) else { return nil }
        guard let transaction = await self.cookieArchiveQueue.beginLoginTransaction(
            liveBaseline: baseline.liveBaseline,
            previousLoginCookies: baseline.loginCookies,
            previousLiveSnapshotFingerprint: baseline.authSnapshot?.stabilityFingerprint
        ) else {
            if await self.cookieArchiveQueue
                .consumeLoginTransactionSetupCleanupRequirement()
            {
                self.loginCookieBackupSetupRequiresCleanup = true
                _ = await self.cookieArchiveQueue.invalidateAndDelete()
            }
            return nil
        }
        let baselineChanged = await self.loginCookieBackupBaselineChanged(baseline)
        guard !self.isClearingAuthCookies,
              self.authCookieOperationFence.isCurrent(expectedOperationGeneration),
              !Task.isCancelled
        else {
            if baselineChanged {
                await self.abandonUnstableLoginCookieBackup(transaction)
            } else if self.isClearingAuthCookies
                || !self.authCookieOperationFence.isCurrent(expectedOperationGeneration)
            {
                _ = await self.cookieArchiveQueue.abandonLoginTransaction(transaction)
            } else if await self.cookieArchiveQueue.claimLoginTransactionRollback(transaction) {
                let didRollback = await self.cookieArchiveQueue
                    .rollbackLoginTransaction(transaction)
                if !didRollback {
                    self.loginCookieBackupSetupRequiresCleanup = true
                    _ = await self.cookieArchiveQueue.invalidateAndDelete()
                }
            }
            return nil
        }
        guard !baselineChanged else {
            await self.abandonUnstableLoginCookieBackup(transaction)
            return nil
        }

        self.loginCookieBackupSetupRequiresCleanup = false
        self.forcedCookieBackupDirty = false
        self.activeLoginCookieBackupTransaction = transaction
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        return transaction
    }

    private func captureLoginCookieBackupBaseline(
        expectedOperationGeneration: UInt64
    ) async -> LoginCookieBackupBaseline? {
        let allLiveCookies = await self.dataStore.httpCookieStore.allCookies()
        guard !self.isClearingAuthCookies,
              self.authCookieOperationFence.isCurrent(expectedOperationGeneration),
              !Task.isCancelled
        else { return nil }

        let authCookies = allLiveCookies.filter(KeychainCookieStorage.isAuthCookie)
        let loginCookies = allLiveCookies.filter(KeychainCookieStorage.isLoginDomainCookie)
        if case .noPrimarySession = KeychainCookieStorage.makeArchiveResult(from: authCookies) {
            return LoginCookieBackupBaseline(
                liveBaseline: .empty,
                authSnapshot: nil,
                loginCookies: loginCookies
            )
        }
        guard let snapshot = CookieArchiveSnapshot.make(from: authCookies) else {
            self.loginCookieBackupSetupRequiresCleanup = true
            return nil
        }
        return LoginCookieBackupBaseline(
            liveBaseline: .archive(snapshot.data),
            authSnapshot: snapshot,
            loginCookies: loginCookies
        )
    }

    private func loginCookieBackupBaselineChanged(
        _ baseline: LoginCookieBackupBaseline
    ) async -> Bool {
        var baselineChanged = true
        for _ in 0 ..< 3 {
            self.forcedCookieBackupDirty = false
            let verificationCookies = await self.dataStore.httpCookieStore.allCookies()
            baselineChanged = !WebKitManager.loginCookieBaselineMatches(
                expectedAuthSnapshot: baseline.authSnapshot,
                expectedLoginCookies: baseline.loginCookies,
                currentCookies: verificationCookies
            )
            if baselineChanged || !self.forcedCookieBackupDirty {
                break
            }
        }
        return baselineChanged
    }

    private func abandonUnstableLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async {
        let didAbandon = await self.cookieArchiveQueue
            .abandonLoginTransaction(transaction)
        self.loginCookieBackupSetupRequiresCleanup = true
        if !didAbandon {
            _ = await self.cookieArchiveQueue.invalidateAndDelete()
        }
    }

    func isLoginCookieBackupActive(_ transaction: CookieBackupTransaction) async -> Bool {
        let queueOwnsTransaction = await self.cookieArchiveQueue
            .isActiveLoginTransaction(transaction)
        return self.isCurrentLoginCookieBackup(transaction) && queueOwnsTransaction
    }

    func hasLoginCookieSnapshotChanged(_ transaction: CookieBackupTransaction) async -> Bool {
        guard self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled,
              let snapshot = await self.currentCookieArchiveSnapshot()
        else { return false }
        return transaction.hasChangedFromPreviousLiveSnapshot(snapshot)
    }

    func refreshLoginCookieBackup(_ transaction: CookieBackupTransaction) async -> Bool {
        guard self.isCurrentLoginCookieBackup(transaction) else { return false }
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        let didPersist = await self.forceBackupCookies()
        return didPersist && self.isCurrentLoginCookieBackup(transaction)
    }

    @discardableResult
    func commitLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> String? {
        for _ in 0 ..< 5 {
            guard self.isCurrentLoginCookieBackup(transaction),
                  !transaction.isCommitRevoked,
                  !Task.isCancelled
            else {
                return nil
            }
            guard let attempt = await self.makeCurrentCookieArchiveWriteAttempt(),
                  let committedSessionValue = attempt.snapshot.primarySessionValue
            else {
                return nil
            }
            let saveResult = await self.persistCookieArchiveAttempt(attempt)
            guard saveResult.isPersisted,
                  self.isCurrentLoginCookieBackup(transaction),
                  !Task.isCancelled,
                  let verificationSnapshot = await self.currentCookieArchiveSnapshot(),
                  !Task.isCancelled,
                  attempt.snapshot == verificationSnapshot
            else {
                continue
            }
            guard self.isCurrentLoginCookieBackup(transaction),
                  !Task.isCancelled,
                  let postCommitSnapshot = await self.currentCookieArchiveSnapshot(),
                  attempt.snapshot == postCommitSnapshot
            else {
                _ = await self.cookieArchiveQueue
                    .disableLoginTransactionRestore(transaction)
                return nil
            }
            return committedSessionValue
        }

        self.logger.error("Authentication cookies changed repeatedly during login commit")
        return nil
    }

    func finalizeLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> String? {
        guard self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled,
              await self.cookieArchiveQueue
              .disableLoginTransactionRestore(transaction),
              await self.commitLoginCookieBackup(transaction) != nil
        else {
            return nil
        }
        if self.forcedCookieBackupDirty {
            guard let refreshedSnapshot = await self.refreshPersistedSnapshot(),
                  transaction.hasChangedFromPreviousLiveSnapshot(refreshedSnapshot)
            else {
                return nil
            }
        }
        guard self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled
        else { return nil }

        guard let postFinalizeSnapshot = await self.refreshPersistedSnapshot(),
              transaction.hasChangedFromPreviousLiveSnapshot(postFinalizeSnapshot),
              let postFinalizeSessionValue = postFinalizeSnapshot.primarySessionValue,
              self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled
        else { return nil }

        let didFinalize = await self.cookieArchiveQueue.finalizeLoginTransaction(transaction)
        guard didFinalize,
              self.isCurrentLoginCookieBackup(transaction),
              !self.forcedCookieBackupDirty,
              !Task.isCancelled
        else {
            if didFinalize {
                _ = self.invalidateAuthCookieRestoration()
                self.activeLoginCookieBackupTransaction = nil
            }
            return nil
        }

        self.activeLoginCookieBackupTransaction = nil
        return postFinalizeSessionValue
    }

    private func refreshPersistedSnapshot() async -> CookieArchiveSnapshot? {
        for _ in 0 ..< 3 {
            self.forcedCookieBackupDirty = false
            guard await self.forceBackupCookies(),
                  let archiveData = await self.cookieArchiveQueue.persistedArchiveData()
            else {
                return nil
            }
            guard !self.forcedCookieBackupDirty else { continue }
            let cookies = KeychainCookieStorage.decodeCookies(from: archiveData)
            return CookieArchiveSnapshot.make(from: cookies)
        }
        return nil
    }

    func prepareLoginCookieBackupRollback(
        _ transaction: CookieBackupTransaction
    ) async -> Bool {
        guard self.isCurrentLoginCookieBackup(transaction) else {
            return true
        }
        if await self.cookieArchiveQueue.disableLoginTransactionRestore(transaction) {
            return true
        }
        guard self.isCurrentLoginCookieBackup(transaction) else {
            return true
        }
        return self.invalidateAuthCookieRestoration()
    }

    func rollbackLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> CookieBackupRollbackResult {
        guard self.isCurrentLoginCookieBackup(transaction) else {
            return .superseded
        }
        guard await self.cookieArchiveQueue.claimLoginTransactionRollback(transaction) else {
            let ownership = await self.cookieArchiveQueue
                .loginTransactionOwnership(transaction)
            return ownership == .none ? .failed : .superseded
        }

        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        let wasClearingAuthCookies = self.isClearingAuthCookies
        self.isClearingAuthCookies = true
        defer {
            if self.isCurrentLoginCookieBackup(transaction) {
                self.isClearingAuthCookies = wasClearingAuthCookies
            }
        }

        let expirationCutoff = Date()
        let previousCookies = transaction.loginCookiesBeforeAttempt().filter { cookie in
            guard let expiresDate = cookie.expiresDate else { return true }
            return expiresDate > expirationCutoff
        }
        let expectedState = LoginCookieVerificationState.make(
            from: previousCookies,
            expirationCutoff: expirationCutoff
        )
        switch await self.restoreLiveCookies(
            previousCookies,
            expectedState: expectedState,
            expirationCutoff: expirationCutoff,
            transaction: transaction
        ) {
        case .restored:
            break
        case .superseded:
            return .superseded
        case .failed:
            return await self.failLoginCookieBackupRollback(
                transaction,
                restoringClearingStateTo: wasClearingAuthCookies
            )
        }

        let didRollback = await self.cookieArchiveQueue.rollbackLoginTransaction(transaction)
        guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
        guard didRollback else {
            self.isClearingAuthCookies = wasClearingAuthCookies
            self.activeLoginCookieBackupTransaction = nil
            self.logger.error("Could not restore the prior cookie backup after login cancellation")
            return .failed
        }

        let postRollbackCookies = await self.dataStore.httpCookieStore.allCookies()
        guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
        let postRollbackState = LoginCookieVerificationState.make(
            from: postRollbackCookies,
            expirationCutoff: expirationCutoff
        )
        guard postRollbackState == expectedState else {
            _ = await self.cookieArchiveQueue.invalidateAndDelete()
            self.isClearingAuthCookies = wasClearingAuthCookies
            self.activeLoginCookieBackupTransaction = nil
            self.logger.error("Authentication cookies changed during login rollback")
            return .failed
        }

        self.isClearingAuthCookies = wasClearingAuthCookies
        self.activeLoginCookieBackupTransaction = nil
        return .rolledBack
    }

    private func restoreLiveCookies(
        _ previousCookies: [HTTPCookie],
        expectedState: LoginCookieVerificationState,
        expirationCutoff: Date,
        transaction: CookieBackupTransaction
    ) async -> LiveCookieRollbackResult {
        for _ in 0 ..< 3 {
            let currentCookies = await self.dataStore.httpCookieStore.allCookies()
            guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
            for cookie in currentCookies where KeychainCookieStorage.isLoginDomainCookie(cookie) {
                await self.dataStore.httpCookieStore.deleteCookie(cookie)
                guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
            }
            for cookie in previousCookies {
                await self.dataStore.httpCookieStore.setCookie(cookie)
                guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
            }
            await Task.yield()
            let verificationCookies = await self.dataStore.httpCookieStore.allCookies()
            let verificationState = LoginCookieVerificationState.make(
                from: verificationCookies,
                expirationCutoff: expirationCutoff
            )
            if verificationState == expectedState {
                return .restored
            }
        }
        return .failed
    }

    private func failLoginCookieBackupRollback(
        _ transaction: CookieBackupTransaction,
        restoringClearingStateTo wasClearingAuthCookies: Bool
    ) async -> CookieBackupRollbackResult {
        _ = await self.cookieArchiveQueue.failLoginTransactionRollback(transaction)
        self.isClearingAuthCookies = wasClearingAuthCookies
        self.activeLoginCookieBackupTransaction = nil
        return .failed
    }

    private func isCurrentLoginCookieBackup(_ transaction: CookieBackupTransaction) -> Bool {
        self.activeLoginCookieBackupTransaction?.matches(transaction) == true
    }

    /// Forces an immediate save of a stable YouTube/Google cookie snapshot.
    func forceBackupCookies() async -> Bool {
        guard self.canPersistAuthCookies else { return false }

        if let forcedCookieBackupTask {
            self.forcedCookieBackupDirty = true
            return await forcedCookieBackupTask.value
        }

        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.forcedCookieBackupTask = nil }

            let result = await CookieBackupStabilizer.persistStableSnapshot(
                maxAttempts: 5,
                operations: CookieBackupStabilizer.Operations(
                    prepareAttempt: {
                        self.forcedCookieBackupDirty = false
                    },
                    makeAttempt: {
                        await self.makeCurrentCookieArchiveWriteAttempt()
                    },
                    persist: { attempt in
                        await self.persistCookieArchiveAttempt(attempt)
                    },
                    readVerificationSnapshot: {
                        await self.currentCookieArchiveSnapshot()
                    },
                    isDirty: {
                        self.forcedCookieBackupDirty
                    },
                    canContinue: {
                        !Task.isCancelled && self.canPersistAuthCookies
                    }
                )
            )

            switch result {
            case .persisted:
                return !self.forcedCookieBackupDirty
            case .cancelled:
                return false
            case .failed:
                self.logger.error("Forced cookie backup failed")
                return false
            case .unstable:
                self.logger.error("Forced cookie backup did not reach a stable snapshot")
                return false
            }
        }
        self.forcedCookieBackupTask = task
        return await task.value
    }

    private func makeCurrentCookieArchiveWriteAttempt() async -> CookieArchiveWriteAttempt? {
        let generation = await self.cookieArchiveQueue.reserveGeneration()
        guard let snapshot = await self.currentCookieArchiveSnapshot() else { return nil }
        return CookieArchiveWriteAttempt(snapshot: snapshot, generation: generation)
    }

    private func currentCookieArchiveSnapshot() async -> CookieArchiveSnapshot? {
        let cookies = await self.dataStore.httpCookieStore.allCookies()
        let authCookies = cookies.filter(KeychainCookieStorage.isAuthCookie)
        return CookieArchiveSnapshot.make(from: authCookies)
    }

    private func persistCookieArchiveAttempt(
        _ attempt: CookieArchiveWriteAttempt
    ) async -> CookieArchiveSaveResult {
        await self.cookieArchiveQueue.save(
            archiveData: attempt.snapshot.data,
            cookieCount: attempt.snapshot.cookieCount,
            generation: attempt.generation
        )
    }

    // MARK: - Observed Cookie Changes

    func handleObservedCookieChange(in cookieStore: WKHTTPCookieStore) {
        self.onCookiesDidChange()

        guard self.canPersistAuthCookies else { return }
        if self.isPreparingLoginCookieBackup
            || self.activeLoginCookieBackupTransaction != nil
            || self.forcedCookieBackupTask != nil
        {
            self.forcedCookieBackupDirty = true
            return
        }

        // WebKit fires once per individual cookie change, so debounce the backup.
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = Task {
            do {
                try await Task.sleep(for: WebKitManager.cookieDebounceInterval)
            } catch is CancellationError {
                return
            } catch {
                self.logger.warning("Unexpected error during cookie debounce: \(error.localizedDescription)")
            }

            guard !Task.isCancelled else { return }
            await self.performCookieBackup(cookieStore: cookieStore)
        }
    }

    private func performCookieBackup(cookieStore: WKHTTPCookieStore) async {
        guard self.canPersistAuthCookies else { return }
        let generation = await self.cookieArchiveQueue.reserveGeneration()
        let cookies = await cookieStore.allCookies()
        guard !Task.isCancelled, self.canPersistAuthCookies else { return }
        let authCookies = cookies.filter(KeychainCookieStorage.isAuthCookie)
        let action = CookieArchiveBackupAction.make(
            from: KeychainCookieStorage.makeArchiveResult(from: authCookies)
        )
        switch action {
        case .invalidate:
            let result = await self.cookieArchiveQueue.invalidateAndDeleteIfLatest(
                generation: generation
            )
            if result == .failed {
                self.logger.error("Could not invalidate an empty authentication-cookie snapshot")
            }
        case .retainExisting:
            self.logger.error("Retaining the last authentication-cookie archive after serialization failure")
        case let .persist(data, cookieCount):
            guard !Task.isCancelled, self.canPersistAuthCookies else { return }
            _ = await self.cookieArchiveQueue.save(
                archiveData: data,
                cookieCount: cookieCount,
                generation: generation
            )
        }
    }
}

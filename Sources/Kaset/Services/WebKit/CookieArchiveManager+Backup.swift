import Foundation
import os
import WebKit

extension CookieArchiveManager {
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
                  !Task.isCancelled,
                  let attempt = await self.makeCurrentCookieArchiveWriteAttempt(),
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
              !Task.isCancelled,
              let postFinalizeSnapshot = await self.refreshPersistedSnapshot(),
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
}

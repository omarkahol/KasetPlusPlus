import Foundation

extension ScrobblingCoordinator {
    // MARK: - Mix-Mode Playback Handling

    /// Handles per-sub-track scrobbling when a mix tracklist is available.
    func handleMixPlayback(
        track: Song,
        tracklist: MixTracklist,
        progress: TimeInterval,
        isPlaying: Bool
    ) {
        // Determine the sub-track at the current playback position
        let entry = tracklist.entry(at: progress)

        // Sub-track changed — finalize previous, start new
        if entry?.id != self.currentMixEntry?.id {
            if let prevEntry = self.currentMixEntry {
                if let endTime = tracklist.effectiveEndTime(
                       for: prevEntry,
                       videoDuration: self.videoDuration(for: track)
                   ),
                   let tracker = self.mixEntryTracker
                {
                    let progressDelta = progress - tracker.lastProgress
                    if progress >= endTime, progressDelta > 0, progressDelta < 2 {
                        self.mixEntryTracker?.accumulate(
                            progress: endTime,
                            isPlaying: isPlaying,
                            now: self.now()
                        )
                    }
                }
                self.finalizeMixEntry(prevEntry, song: track)
            }

            if let entry {
                self.startMixEntry(entry, progress: progress)
            } else {
                // Between entries or before the first — clear current
                self.currentMixEntry = nil
            }
        }

        guard let entry, self.currentMixEntry?.id == entry.id else { return }

        // A backward jump after scrobbling is a replay and gets a fresh timestamp. Other seeks
        // only reset accumulated play time; already-sent latches remain set to prevent duplicates.
        if let tracker = self.mixEntryTracker, abs(progress - tracker.lastProgress) > 5.0 {
            let restartedNearEntryStart = progress <= entry.startTime + Self.mixReplayStartTolerance
            if tracker.hasScrobbled,
               progress < tracker.lastProgress - 5.0,
               restartedNearEntryStart
            {
                self.mixEntryScrobbledIds.remove(entry.id)
                self.mixEntryTracker = PlaybackScrobbleTracker(startTime: self.now(), initialProgress: progress)
                self.logger.debug("Mix replay detected at \(String(format: "%.1f", progress))s for sub-track '\(entry.title)'")
            } else {
                self.mixEntryTracker?.resetForSeek()
                self.logger.debug("Mix seek detected at \(String(format: "%.1f", progress))s, resetting sub-track accumulation for '\(entry.title)'")
            }
        }

        // Accumulate play time (the tracker ignores seeks and paused spans internally)
        self.mixEntryTracker?.accumulate(progress: progress, isPlaying: isPlaying, now: self.now())

        // Send "now playing" once per sub-track
        if self.mixEntryTracker?.hasSentNowPlaying == false, isPlaying {
            self.sendMixNowPlaying(entry, song: track)
        }

        // Check sub-track scrobble threshold
        if self.mixEntryTracker?.hasScrobbled == false {
            self.checkMixEntryScrobbleThreshold(entry: entry, song: track)
        }
    }

    /// Starts tracking a new sub-track within the mix.
    private func startMixEntry(_ entry: MixTrackEntry, progress: TimeInterval) {
        self.currentMixEntry = entry
        let pendingCredit = self.provisionalCurrentMixCredit
        self.provisionalCurrentMixCredit = nil
        let provisionalCredit = pendingCredit.flatMap { credit in
            credit.entryId == entry.id ? credit.credit : nil
        }
        let isConfirmedReplay = self.mixEntryScrobbledIds.contains(entry.id)
            && progress <= entry.startTime + Self.mixReplayStartTolerance
        if isConfirmedReplay {
            self.mixEntryScrobbledIds.remove(entry.id)
        }
        var tracker = PlaybackScrobbleTracker(
            startTime: provisionalCredit?.startTime ?? self.now(),
            initialProgress: progress
        )
        if let provisionalCredit {
            tracker.creditVerifiedPlayTime(provisionalCredit.accumulatedPlayTime)
            if provisionalCredit.hasScrobbled {
                tracker.markScrobbled()
                self.mixEntryScrobbledIds.insert(entry.id)
            }
        }
        if self.mixEntryScrobbledIds.contains(entry.id) {
            tracker.markScrobbled()
        }
        self.mixEntryTracker = tracker
        self.logger.debug("Mix sub-track started: \(entry.artist ?? "?") - \(entry.title) at \(String(format: "%.1f", entry.startTime))s")
    }

    /// Finalizes a mix sub-track — checks threshold and scrobbles if met.
    func finalizeMixEntry(_ entry: MixTrackEntry, song: Song?) {
        // Final threshold check before the sub-track ends (skip if it already scrobbled)
        if self.mixEntryTracker?.hasScrobbled == false {
            self.checkMixEntryScrobbleThreshold(entry: entry, song: song)
        }

        self.logger.debug("Mix sub-track finalized: \(entry.artist ?? "?") - \(entry.title) (accumulated: \(String(format: "%.1f", self.mixEntryTracker?.accumulatedPlayTime ?? 0))s, scrobbled: \(self.mixEntryTracker?.hasScrobbled ?? false))")

        self.currentMixEntry = nil
        self.mixEntryTracker = nil
    }

    /// Checks whether the current sub-track has met the scrobble threshold.
    private func checkMixEntryScrobbleThreshold(entry: MixTrackEntry, song: Song?) {
        let duration = self.mixEntryDuration(entry, song: song)
        guard var tracker = self.mixEntryTracker,
              tracker.meetsThreshold(duration: duration, thresholds: self.mixEntryThresholds)
        else { return }

        tracker.markScrobbled()
        self.mixEntryTracker = tracker
        self.mixEntryScrobbledIds.insert(entry.id)

        let scrobbleTrack = ScrobbleTrack(
            title: entry.title,
            artist: entry.artist ?? song?.artistsDisplay ?? "Unknown Artist",
            album: nil,
            duration: duration,
            timestamp: tracker.startTime,
            videoId: song?.videoId
        )
        self.queue.enqueue(scrobbleTrack)
        self.scheduleQueueFlushIfNeeded()
        self.logger.info("Mix scrobble: \(entry.artist ?? "?") - \(entry.title) (accumulated: \(String(format: "%.1f", tracker.accumulatedPlayTime))s)")
    }

    // MARK: - Queue Flush

    func scheduleQueueFlushIfNeeded(after delay: Duration = .seconds(30)) {
        guard self.isMonitoring,
              self.hasAnyEnabledConnectedService,
              !self.queue.isEmpty
        else {
            self.flushTaskGeneration += 1
            self.flushTask?.cancel()
            self.flushTask = nil
            return
        }

        guard self.flushTask == nil || self.flushTask?.isCancelled == true else { return }

        self.flushTaskGeneration += 1
        let generation = self.flushTaskGeneration
        self.flushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                guard let self, self.flushTaskGeneration == generation else { return }
                self.flushTask = nil
                return
            }

            guard let self, self.isMonitoring, self.flushTaskGeneration == generation else { return }
            let retryDelay = await self.performQueueFlush()
            guard self.isMonitoring, self.flushTaskGeneration == generation else { return }
            self.flushTask = nil
            if let retryDelay {
                self.scheduleQueueFlushIfNeeded(after: retryDelay)
            }
        }
    }

    /// Exposed for focused tests; true only when there is pending queue work eligible for a one-shot flush.
    var isQueueFlushScheduled: Bool {
        guard let flushTask else { return false }
        return !flushTask.isCancelled
    }

    private static func backoffDelay(attempt: Int) -> Duration {
        let shift = min(max(attempt - 1, 0), 5)
        let seconds = min(30 * (1 << shift), Self.maxFlushBackoffSeconds)
        return .seconds(seconds)
    }

    /// Flushes pending scrobbles from the queue to all enabled services.
    func flushQueue() async {
        _ = await self.performQueueFlush()
    }

    private func performQueueFlush() async -> Duration? {
        guard self.hasAnyEnabledConnectedService else { return nil }
        guard !self.queue.isEmpty else {
            self.consecutiveFlushFailures = 0
            return nil
        }

        // Prune expired entries first
        self.queue.pruneExpired()
        guard !self.queue.isEmpty else {
            self.consecutiveFlushFailures = 0
            return nil
        }

        let activeServices = self.enabledConnectedServices
        let requiredServices = Set(activeServices.map(\.serviceName))

        var hadTransientFailure = false
        var hadPermanentAuthFailure = false
        var hadNonAuthAttempt = false
        var maxRetryAfter: TimeInterval?

        for service in activeServices {
            let outcome = await self.flushBatch(for: service, requiredServices: requiredServices)
            switch outcome {
            case .cancelled:
                return nil
            case .skipped:
                continue
            case .attempted:
                hadNonAuthAttempt = true
            case let .transientFailure(retryAfter):
                hadTransientFailure = true
                if let retryAfter {
                    maxRetryAfter = max(maxRetryAfter ?? 0, retryAfter)
                }
            case .permanentAuthFailure:
                hadPermanentAuthFailure = true
            }
        }

        guard !self.queue.isEmpty else {
            self.consecutiveFlushFailures = 0
            return nil
        }

        if hadTransientFailure {
            self.consecutiveFlushFailures += 1
            if let retryAfter = maxRetryAfter {
                return .seconds(max(1, Int(retryAfter.rounded(.up))))
            }
            return Self.backoffDelay(attempt: self.consecutiveFlushFailures)
        }

        if hadPermanentAuthFailure, !hadNonAuthAttempt {
            return nil
        }

        self.consecutiveFlushFailures = 0
        return .seconds(30)
    }

    private enum BatchFlushOutcome {
        case cancelled
        case skipped
        case attempted
        case transientFailure(retryAfter: TimeInterval?)
        case permanentAuthFailure
    }

    private func flushBatch(
        for service: any ScrobbleServiceProtocol,
        requiredServices: Set<String>
    ) async -> BatchFlushOutcome {
        let batch = self.queue.pendingTracks(for: service.serviceName, limit: 50)
        guard !batch.isEmpty else { return .skipped }

        self.logger.debug("Flushing \(batch.count) scrobbles to \(service.serviceName)")

        do {
            let results = try await service.scrobble(batch)
            let acceptedIds = Set(results.filter(\.accepted).map(\.track.id))
            if !acceptedIds.isEmpty {
                self.queue.markCompleted(
                    acceptedIds,
                    for: service.serviceName,
                    requiredServices: requiredServices
                )
                self.logger.info("Flushed \(acceptedIds.count)/\(batch.count) scrobbles to \(service.serviceName)")
            }

            for result in results where !result.accepted {
                self.logger.warning("Scrobble rejected by \(service.serviceName): \(result.track.title) - \(result.errorMessage ?? "unknown reason")")
            }
            return .attempted
        } catch is CancellationError {
            return .cancelled
        } catch let error as ScrobbleError {
            switch error {
            case let .rateLimited(retryAfter):
                self.logger.warning("\(service.serviceName) rate limited during flush")
                return .transientFailure(retryAfter: retryAfter)
            case .invalidCredentials, .sessionExpired:
                self.logger.warning("\(service.serviceName) credentials invalid/expired during flush; pausing automatic retries until re-authenticated")
                return .permanentAuthFailure
            case .networkError, .serviceUnavailable, .invalidResponse:
                self.logger.error("\(service.serviceName) flush failed: \(error.localizedDescription)")
                return .transientFailure(retryAfter: nil)
            }
        } catch {
            self.logger.error("\(service.serviceName) flush failed with unexpected error: \(error.localizedDescription)")
            return .transientFailure(retryAfter: nil)
        }
    }
}

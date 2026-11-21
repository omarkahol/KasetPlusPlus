import Foundation
import Observation

// MARK: - SleepTimerMode

enum SleepTimerMode: Equatable, Sendable {
    case off
    case minutes(Int)
    case endOfTrack

    var duration: TimeInterval? {
        switch self {
        case .off:
            nil
        case let .minutes(min):
            TimeInterval(min * 60)
        case .endOfTrack:
            nil
        }
    }
}

// MARK: - SleepTimerService

@MainActor
@Observable
final class SleepTimerService {
    static let shared = SleepTimerService()

    private(set) var mode: SleepTimerMode = .off
    private(set) var targetEndDate: Date?
    private(set) var remainingSeconds: TimeInterval = 0

    var isActive: Bool {
        self.mode != .off
    }

    /// Fade duration in seconds before the timer elapses.
    static let fadeOutDuration: TimeInterval = 30

    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var originalVolume: Double?
    @ObservationIgnored private var trackObservationId: String?
    @ObservationIgnored private var isFadingOut: Bool = false

    init() {}

    /// Starts or updates the sleep timer with the specified mode.
    func start(mode: SleepTimerMode) {
        self.cancelTimer(restoreVolume: true)

        guard mode != .off else {
            return
        }

        self.mode = mode

        switch mode {
        case let .minutes(minutes):
            let duration = TimeInterval(minutes * 60)
            let endDate = Date().addingTimeInterval(duration)
            self.targetEndDate = endDate
            self.remainingSeconds = duration
            self.startCountdownLoop(endDate: endDate, totalDuration: duration)

        case .endOfTrack:
            let player = PlayerService.shared
            self.trackObservationId = player?.currentTrack?.videoId
            self.targetEndDate = nil
            self.remainingSeconds = 0
            self.startEndOfTrackLoop()

        case .off:
            break
        }
    }

    /// Stops and turns off the sleep timer, restoring volume if mid-fade.
    func stop() {
        self.cancelTimer(restoreVolume: true)
    }

    private func cancelTimer(restoreVolume: Bool) {
        self.timerTask?.cancel()
        self.timerTask = nil

        if restoreVolume, self.isFadingOut, let originalVolume = self.originalVolume {
            PlayerService.shared?.setVolumeImmediately(originalVolume)
        }

        self.mode = .off
        self.targetEndDate = nil
        self.remainingSeconds = 0
        self.originalVolume = nil
        self.trackObservationId = nil
        self.isFadingOut = false
    }

    // MARK: - Countdown Loop

    private func startCountdownLoop(endDate: Date, totalDuration: TimeInterval) {
        self.timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { break }

                let remaining = max(0, endDate.timeIntervalSinceNow)
                self.remainingSeconds = remaining

                if remaining <= 0 {
                    await self.handleTimerExpired()
                    break
                }

                if remaining <= Self.fadeOutDuration {
                    self.performFadeStep(remaining: remaining, fadeDuration: min(Self.fadeOutDuration, totalDuration))
                }
            }
        }
    }

    // MARK: - End of Track Loop

    private func startEndOfTrackLoop() {
        self.timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { break }
                guard let player = PlayerService.shared else { continue }

                // Check if track has changed
                let currentVideoId = player.currentTrack?.videoId
                if let initialId = self.trackObservationId,
                   let currentId = currentVideoId,
                   initialId != currentId
                {
                    // Track transitioned to next track -> sleep timer triggered
                    await self.handleTimerExpired()
                    break
                }

                // Check remaining playback duration in current track
                let duration = player.duration
                let progress = player.progress
                let remaining = max(0, duration - progress)

                if duration > 0 {
                    self.remainingSeconds = remaining
                    if remaining <= 0.5 || player.state == .ended {
                        await self.handleTimerExpired()
                        break
                    }

                    if remaining <= Self.fadeOutDuration {
                        self.performFadeStep(remaining: remaining, fadeDuration: min(Self.fadeOutDuration, duration))
                    }
                }
            }
        }
    }

    // MARK: - Volume Fade-Out

    private func performFadeStep(remaining: TimeInterval, fadeDuration: TimeInterval) {
        guard let player = PlayerService.shared else { return }

        if !self.isFadingOut {
            self.originalVolume = player.volume
            self.isFadingOut = true
        }

        guard let baseVolume = self.originalVolume, baseVolume > 0, fadeDuration > 0 else { return }

        // Linear interpolation factor from 1.0 (at fadeDuration) to 0.0 (at 0 remaining)
        let ratio = max(0.0, min(1.0, remaining / fadeDuration))
        let targetVolume = baseVolume * ratio
        player.setVolumeImmediately(targetVolume)
    }

    // MARK: - Completion

    private func handleTimerExpired() async {
        guard let player = PlayerService.shared else {
            self.cancelTimer(restoreVolume: false)
            return
        }

        // Set volume to 0 and pause
        player.setVolumeImmediately(0)
        await player.pause()

        // Restore original volume setting so next play has proper volume
        if let originalVolume = self.originalVolume {
            player.setVolumeImmediately(originalVolume)
        }

        self.cancelTimer(restoreVolume: false)
    }
}

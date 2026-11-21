import SwiftUI

// MARK: - MiniPlayerSeekSection

/// Isolates `playerService.progress` observation into a leaf view so `MiniPlayerWindow.body`
/// does not re-render at 5 Hz during playback.
struct MiniPlayerSeekSection: View {
    @Environment(PlayerService.self) private var playerService

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var seekHold = PlayerBarSeekHold()

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: self.$seekValue, in: 0 ... 1) { editing in
                self.isSeeking = editing
                if !editing {
                    self.performSeek()
                }
            }
            .controlSize(.small)
            .tint(SettingsManager.shared.accentColor)
            .layoutPriority(1)
            .disabled(
                self.playerService.duration <= 0
                    || self.playerService.isCurrentItemLive
                    || self.playerService.isShowingAd
            )
            .accessibilityIdentifier(AccessibilityID.MiniPlayer.seekSlider)
            HStack {
                Text(self.formatTime(self.isSeeking ? self.seekValue * self.playerService.duration : self.displayedPlaybackProgress))
                Spacer()
                Text(self.playerService.isCurrentItemLive ? String(localized: "LIVE") : self.remainingTimeText)
            }
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.76))
            .shadow(color: .black.opacity(0.56), radius: 2, y: 1)
        }
        .onChange(of: self.playerService.progress) { _, newValue in
            self.seekHold.reconcile(observedProgress: newValue)
            if !self.isSeeking, !self.seekHold.isActive, self.playerService.duration > 0 {
                self.seekValue = self.displayedPlaybackProgress / self.playerService.duration
            }
        }
        .onChange(of: self.playerService.duration) { _, _ in
            self.seekHold.reconcile(observedProgress: self.playerService.progress)
            if !self.isSeeking, !self.seekHold.isActive {
                self.syncSeekValue()
            }
        }
        .onChange(of: self.currentTrackIdentity) { _, _ in
            self.clearSeekHold()
        }
        .onChange(of: self.playerService.isShowingAd) { _, isShowingAd in
            if isShowingAd {
                self.clearSeekHold()
            }
        }
        .onAppear {
            self.syncSeekValue()
        }
    }

    private var remainingTimeText: String {
        "-\(self.formatTime(max(0, self.playerService.duration - self.displayedPlaybackProgress)))"
    }

    private var displayedPlaybackProgress: TimeInterval {
        self.seekHold.displayProgress(observedProgress: self.playerService.progress)
    }

    private var currentTrackIdentity: String {
        self.playerService.currentTrack?.videoId ?? "none"
    }

    private func syncSeekValue() {
        if self.playerService.duration > 0 {
            self.seekValue = self.displayedPlaybackProgress / self.playerService.duration
        } else {
            self.seekValue = 0
        }
    }

    private func performSeek() {
        guard self.playerService.duration > 0, !self.playerService.isShowingAd else { return }
        let target = self.seekValue * self.playerService.duration
        let holdID = self.seekHold.begin(target: target)
        Task { await self.playerService.seek(to: target) }
        Task { @MainActor in
            try? await Task.sleep(for: PlayerBarSeekHold.timeout)
            if self.seekHold.clearIfCurrent(holdID) {
                self.syncSeekValue()
            }
        }
    }

    private func clearSeekHold() {
        self.seekHold.clear()
        self.isSeeking = false
        self.syncSeekValue()
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

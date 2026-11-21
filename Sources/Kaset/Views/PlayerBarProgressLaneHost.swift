import SwiftUI

// MARK: - PlayerBarProgressLaneHost

/// Shared progress lane host that manages scrubbing state, `PlayerBarSeekHold`,
/// and second-granularity time formatting for both Music and YouTube player bars.
struct PlayerBarProgressLaneHost: View {
    let progress: TimeInterval
    let duration: TimeInterval
    let isShowingAd: Bool
    let isLive: Bool
    let canSeek: Bool
    let isLoading: Bool
    let currentSeekIdentity: String
    let accent: Color
    var markers: [PlayerBarProgressMarker] = []
    var segments: [PlayerBarProgressSegment] = []
    var segmentMarkers: [PlayerBarSegmentMarker] = []
    var heatmap: [YouTubeHeatmapMarker] = []
    var inlineTimestamps: Bool = false
    var onMarkerPreviewChange: (PlayerBarProgressMarker?) -> Void = { _ in }
    var onHoverFractionChange: ((Double?) -> Void)?
    let onSeek: (TimeInterval) async -> Void

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var seekHold = PlayerBarSeekHold()
    @State private var formattedProgress: String = "0:00"
    @State private var formattedRemaining: String = "-0:00"
    @State private var lastProgressSecond: Int = -1

    private var displayedPlaybackProgress: TimeInterval {
        self.seekHold.displayProgress(observedProgress: self.progress)
    }

    private var displayFraction: Double {
        if self.isSeeking {
            return min(max(0, self.seekValue), 1)
        }
        guard self.duration > 0 else { return 0 }
        return min(max(0, self.displayedPlaybackProgress / self.duration), 1)
    }

    var body: some View {
        PlayerBarProgressLane(
            fraction: self.displayFraction,
            accent: self.accent,
            elapsedText: self.isSeeking
                ? Self.formatTime(self.seekValue * self.duration)
                : self.formattedProgress,
            remainingText: self.isSeeking
                ? "-\(Self.formatTime(max(0, self.duration - self.seekValue * self.duration)))"
                : self.formattedRemaining,
            markers: self.markers,
            segments: self.segments,
            isLive: self.isLive,
            canSeek: self.canSeek,
            isLoading: self.isLoading,
            onScrub: { fraction in
                self.isSeeking = true
                self.seekValue = fraction
            },
            onCommit: {
                self.performSeek()
            },
            onMarkerPreviewChange: self.onMarkerPreviewChange,
            segmentMarkers: self.segmentMarkers,
            heatmap: self.heatmap,
            onHoverFractionChange: self.onHoverFractionChange,
            inlineTimestamps: self.inlineTimestamps
        )
        .onAppear {
            self.syncFromPlayer(progress: self.progress, duration: self.duration)
        }
        .onChange(of: self.progress) { _, newValue in
            self.syncFromPlayer(progress: newValue, duration: self.duration)
        }
        .onChange(of: self.duration) { _, newValue in
            self.syncFromPlayer(progress: self.progress, duration: newValue)
        }
        .onChange(of: self.currentSeekIdentity) { _, _ in
            self.clearSeekHold()
        }
        .onChange(of: self.isShowingAd) { _, isShowingAd in
            if isShowingAd {
                self.clearSeekHold()
            }
        }
    }

    private func syncFromPlayer(progress: TimeInterval, duration: TimeInterval) {
        self.seekHold.reconcile(observedProgress: progress)
        let displayProgress = self.seekHold.displayProgress(observedProgress: progress)

        if !self.isSeeking, !self.seekHold.isActive, duration > 0 {
            self.seekValue = displayProgress / duration
        }

        let currentSecond = Int(displayProgress)
        if currentSecond != self.lastProgressSecond || duration == 0 {
            self.lastProgressSecond = currentSecond
            self.updateFormattedTimes(progress: displayProgress, duration: duration)
        }
    }

    private func performSeek() {
        guard self.isSeeking, self.canSeek else { return }
        let seekTime = self.seekValue * self.duration
        let holdID = self.seekHold.begin(target: seekTime)
        self.updateFormattedTimes(progress: seekTime, duration: self.duration)
        self.isSeeking = false

        Task {
            await self.onSeek(seekTime)
        }
        Task { @MainActor in
            try? await Task.sleep(for: PlayerBarSeekHold.timeout)
            if self.seekHold.clearIfCurrent(holdID) {
                self.syncSeekValueFromDisplayedProgress()
                self.updateFormattedTimes(
                    progress: self.displayedPlaybackProgress,
                    duration: self.duration
                )
            }
        }
    }

    private func clearSeekHold() {
        self.seekHold.clear()
        self.isSeeking = false
        self.syncSeekValueFromDisplayedProgress()
        self.updateFormattedTimes(
            progress: self.displayedPlaybackProgress,
            duration: self.duration
        )
    }

    private func syncSeekValueFromDisplayedProgress() {
        if self.duration > 0 {
            self.seekValue = self.displayedPlaybackProgress / self.duration
        } else {
            self.seekValue = 0
        }
    }

    private func updateFormattedTimes(progress: TimeInterval, duration: TimeInterval) {
        self.formattedProgress = Self.formatTime(progress)
        self.formattedRemaining = "-\(Self.formatTime(max(0, duration - progress)))"
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

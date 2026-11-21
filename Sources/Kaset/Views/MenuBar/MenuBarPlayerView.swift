import AppKit
import SwiftUI

// MARK: - MenuBarPlayerView

/// Compact, source-aware popover view for the macOS Menu Bar.
/// Routes controls and metadata to either YouTube Music or YouTube Video
/// based on `PlaybackArbiter`.
struct MenuBarPlayerView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(PlaybackArbiter.self) private var playbackArbiter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false
    @State private var showsVolumeSlider = false

    private var isVideoActive: Bool {
        self.playbackArbiter.routesMediaKeysToVideo
    }

    private var hasActiveItem: Bool {
        self.isVideoActive ? self.youtubePlayer.currentVideo != nil : self.playerService.currentTrack != nil
    }

    private var activeIsPlaying: Bool {
        self.isVideoActive ? self.youtubePlayer.isPlaying : self.playerService.isPlaying
    }

    private var activeVolume: Double {
        self.isVideoActive ? self.youtubePlayer.volume : self.playerService.volume
    }

    var body: some View {
        VStack(spacing: 12) {
            self.trackInfoRow

            MenuBarProgressHost(isVideoActive: self.isVideoActive)

            self.controlsRow

            Divider()
                .opacity(0.3)

            self.openAppRow
        }
        .padding(14)
        .frame(width: 280)
        .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            self.volumeValue = self.activeVolume
        }
        .onChange(of: self.activeVolume) { _, newVol in
            if !self.isAdjustingVolume {
                self.volumeValue = newVol
            }
        }
    }

    // MARK: - Track Info

    private var trackInfoRow: some View {
        HStack(spacing: 10) {
            self.thumbnailView

            VStack(alignment: .leading, spacing: 3) {
                PlayerBarMarqueeText(
                    text: self.displayTitle,
                    font: .system(size: 13, weight: .semibold),
                    color: .primary,
                    height: 15,
                    reduceMotion: self.reduceMotion
                )

                Text(self.subtitleText)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayTitle: String {
        if self.isVideoActive {
            return self.youtubePlayer.currentVideo?.title ?? String(localized: "Not Playing")
        }
        return self.playerService.currentTrack?.title ?? String(localized: "Not Playing")
    }

    @ViewBuilder private var thumbnailView: some View {
        if self.isVideoActive, let video = self.youtubePlayer.currentVideo {
            CachedAsyncImage(url: video.thumbnailURL, targetSize: CGSize(width: 80, height: 80)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 40, height: 40)
            .clipShape(.rect(cornerRadius: 6))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        } else if let track = self.playerService.currentTrack {
            SongThumbnailView(song: track, size: 40, cornerRadius: 6)
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var subtitleText: String {
        if self.isVideoActive {
            return self.youtubePlayer.currentVideo?.channelName ?? "YouTube"
        }
        guard let track = self.playerService.currentTrack else { return "—" }
        return track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay
    }

    // MARK: - Controls Row

    private var controlsRow: some View {
        HStack(spacing: 8) {
            PlayerBarIconButton(
                action: self.previousAction,
                accessibilityLabel: self.isVideoActive
                    ? String(localized: "Back 30 seconds")
                    : String(localized: "Previous track")
            ) {
                Image(systemName: self.isVideoActive ? "gobackward.30" : "backward.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .disabled(!self.hasActiveItem)

            PlayerBarIconButton(
                action: self.playPause,
                accessibilityLabel: self.activeIsPlaying ? String(localized: "Pause") : String(localized: "Play")
            ) {
                Image(systemName: self.activeIsPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!self.hasActiveItem)

            PlayerBarIconButton(
                action: self.nextAction,
                accessibilityLabel: self.isVideoActive
                    ? String(localized: "Forward 30 seconds")
                    : String(localized: "Next track")
            ) {
                Image(systemName: self.isVideoActive ? "goforward.30" : "forward.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .disabled(!self.hasActiveItem)

            Spacer()

            if self.showsVolumeSlider {
                Slider(
                    value: self.$volumeValue,
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        self.isAdjustingVolume = editing
                        if !editing {
                            self.applyVolume(self.volumeValue)
                        }
                    }
                )
                .tint(SettingsManager.shared.accentColor)
                .frame(width: 70)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)),
                    removal: .opacity
                ))
                .onChange(of: self.volumeValue) { _, newVol in
                    if self.isAdjustingVolume {
                        self.applyVolume(newVol)
                    }
                }
            }

            PlayerBarIconButton(
                action: self.toggleVolumeSlider,
                accessibilityLabel: String(localized: "Volume"),
                accessibilityValue: "\(Int(self.activeVolume * 100))%"
            ) {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }

    // MARK: - Open Kaset++

    private var openAppRow: some View {
        Button(action: self.bringAppToFront) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold))
                Text(String(localized: "Open Kaset++"))
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(SettingsManager.shared.accentColor)
    }

    // MARK: - Actions

    private func playPause() {
        HapticService.playback()
        if self.isVideoActive {
            self.youtubePlayer.playPause()
        } else {
            Task {
                await self.playerService.playPause()
            }
        }
    }

    private func previousAction() {
        HapticService.playback()
        if self.isVideoActive {
            self.youtubePlayer.seekBackward()
        } else {
            Task {
                await self.playerService.previous()
            }
        }
    }

    private func nextAction() {
        HapticService.playback()
        if self.isVideoActive {
            self.youtubePlayer.seekForward()
        } else {
            Task {
                await self.playerService.next()
            }
        }
    }

    private func toggleVolumeSlider() {
        HapticService.toggle()
        withAnimation(AppAnimation.quick) {
            self.showsVolumeSlider.toggle()
        }
    }

    private func applyVolume(_ value: Double) {
        if self.isVideoActive {
            self.youtubePlayer.volume = value
        } else {
            self.playerService.setVolumeImmediately(value)
        }
    }

    private func bringAppToFront() {
        HapticService.toggle()
        MainWindowOpener.bringMainWindowToFront(openWindow: self.openWindow)
    }

    private var volumeIcon: String {
        let vol = self.activeVolume
        if vol == 0 {
            return "speaker.slash.fill"
        } else if vol < 0.33 {
            return "speaker.wave.1.fill"
        } else if vol < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - MenuBarProgressHost

/// Isolated progress leaf so 4–5 Hz `progress` updates only re-evaluate the
/// scrubber and timestamps instead of the entire `MenuBarPlayerView`.
private struct MenuBarProgressHost: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(\.colorScheme) private var colorScheme

    let isVideoActive: Bool

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var seekHold = PlayerBarSeekHold()
    @State private var formattedProgress: String = "0:00"
    @State private var formattedRemaining: String = "-0:00"
    @State private var lastProgressSecond: Int = -1

    private var observedProgress: TimeInterval {
        self.isVideoActive ? self.youtubePlayer.progress : self.playerService.progress
    }

    private var observedDuration: TimeInterval {
        self.isVideoActive ? self.youtubePlayer.duration : self.playerService.duration
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PlayerBarSliderVisuals.trackColor(colorScheme: self.colorScheme, isActive: false))
                        .frame(height: 4)

                    Capsule()
                        .fill(SettingsManager.shared.accentColor)
                        .frame(width: availableWidth * CGFloat(min(max(0, self.seekValue), 1)), height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard self.observedDuration > 0 else { return }
                            self.isSeeking = true
                            let progressFraction = min(max(0, gesture.location.x / availableWidth), 1)
                            self.seekValue = progressFraction
                            let previewTime = progressFraction * self.observedDuration
                            self.updateFormattedTimes(progress: previewTime, duration: self.observedDuration)
                        }
                        .onEnded { _ in
                            guard self.observedDuration > 0 else { return }
                            self.performSeek()
                        }
                )
            }
            .frame(height: 6)

            HStack {
                Text(self.formattedProgress)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(self.formattedRemaining)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            self.syncFromPlayer(progress: self.observedProgress, duration: self.observedDuration)
        }
        .onChange(of: self.observedProgress) { _, newValue in
            self.syncFromPlayer(progress: newValue, duration: self.observedDuration)
        }
        .onChange(of: self.observedDuration) { _, newValue in
            self.syncFromPlayer(progress: self.observedProgress, duration: newValue)
        }
    }

    private func syncFromPlayer(progress: TimeInterval, duration: TimeInterval) {
        self.seekHold.reconcile(observedProgress: progress)
        let displayProg = self.isSeeking
            ? self.seekValue * duration
            : self.seekHold.displayProgress(observedProgress: progress)

        if !self.isSeeking, !self.seekHold.isActive, duration > 0 {
            self.seekValue = displayProg / duration
        }

        let currentSecond = Int(displayProg)
        if currentSecond != self.lastProgressSecond || duration == 0 {
            self.lastProgressSecond = currentSecond
            self.updateFormattedTimes(progress: displayProg, duration: duration)
        }
    }

    private func performSeek() {
        let targetProgress = self.seekValue * self.observedDuration
        self.seekHold.begin(target: targetProgress)
        if self.isVideoActive {
            self.youtubePlayer.seek(to: targetProgress)
            self.isSeeking = false
        } else {
            Task {
                await self.playerService.seek(to: targetProgress)
                self.isSeeking = false
            }
        }
    }

    private func updateFormattedTimes(progress: TimeInterval, duration: TimeInterval) {
        let safeDuration = max(0, duration)
        let safeProgress = min(max(0, progress), safeDuration)
        let remaining = safeDuration - safeProgress

        self.formattedProgress = Self.formatTime(safeProgress)
        self.formattedRemaining = "-\(Self.formatTime(remaining))"
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard !seconds.isNaN, !seconds.isInfinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

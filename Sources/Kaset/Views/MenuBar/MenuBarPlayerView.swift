import AppKit
import SwiftUI

// MARK: - MenuBarPlayerView

/// Compact, elegant popover view for the macOS Menu Bar.
/// Adheres to Kaset++'s Liquid Glass aesthetics.
struct MenuBarPlayerView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var seekHold = PlayerBarSeekHold()

    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false
    @State private var showsVolumeSlider = false

    @State private var formattedProgress: String = "0:00"
    @State private var formattedRemaining: String = "-0:00"
    @State private var lastProgressSecond: Int = -1

    var body: some View {
        VStack(spacing: 12) {
            // Track Info Row
            self.trackInfoRow

            // Mini Scrubber Lane
            self.scrubberRow

            // Controls & Volume Row
            self.controlsRow

            Divider()
                .opacity(0.3)

            // Open Kaset++ Action
            self.openAppRow
        }
        .padding(14)
        .frame(width: 280)
        .compatGlass(interactive: true, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            self.volumeValue = self.playerService.volume
            let current = self.displayProgress(observedProgress: self.playerService.progress)
            if self.playerService.duration > 0 {
                self.seekValue = current / self.playerService.duration
            }
            self.updateFormattedTimes(progress: current, duration: self.playerService.duration)
        }
        .onChange(of: self.playerService.volume) { _, newVol in
            if !self.isAdjustingVolume {
                self.volumeValue = newVol
            }
        }
        .onChange(of: self.playerService.progress) { _, newValue in
            self.seekHold.reconcile(observedProgress: newValue)
            let displayProg = self.displayProgress(observedProgress: newValue)

            if !self.isSeeking, !self.seekHold.isActive, self.playerService.duration > 0 {
                self.seekValue = displayProg / self.playerService.duration
            }

            let currentSecond = Int(displayProg)
            if currentSecond != self.lastProgressSecond {
                self.lastProgressSecond = currentSecond
                self.updateFormattedTimes(progress: displayProg, duration: self.playerService.duration)
            }
        }
        .onChange(of: self.playerService.duration) { _, newValue in
            self.seekHold.reconcile(observedProgress: self.playerService.progress)
            let displayProg = self.displayProgress(observedProgress: self.playerService.progress)
            if !self.isSeeking, !self.seekHold.isActive, newValue > 0 {
                self.seekValue = displayProg / newValue
            }
            self.updateFormattedTimes(progress: displayProg, duration: newValue)
        }
    }

    // MARK: - Track Info

    private var trackInfoRow: some View {
        HStack(spacing: 10) {
            self.thumbnailView

            VStack(alignment: .leading, spacing: 3) {
                PlayerBarMarqueeText(
                    text: self.playerService.currentTrack?.title ?? String(localized: "Not Playing"),
                    font: .system(size: 13, weight: .semibold),
                    color: .primary,
                    height: 15,
                    reduceMotion: self.reduceMotion
                )

                Text(self.artistName)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let track = self.playerService.currentTrack {
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

    private var artistName: String {
        guard let track = self.playerService.currentTrack else { return "—" }
        return track.artistsDisplay.isEmpty ? String(localized: "Unknown Artist") : track.artistsDisplay
    }

    // MARK: - Scrubber

    private var scrubberRow: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width)
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(PlayerBarSliderVisuals.trackColor(colorScheme: self.colorScheme, isActive: false))
                        .frame(height: 4)

                    // Elapsed fill
                    Capsule()
                        .fill(SettingsManager.shared.accentColor)
                        .frame(width: availableWidth * CGFloat(min(max(0, self.seekValue), 1)), height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard self.playerService.duration > 0 else { return }
                            self.isSeeking = true
                            let progressFraction = min(max(0, gesture.location.x / availableWidth), 1)
                            self.seekValue = progressFraction
                            let previewTime = progressFraction * self.playerService.duration
                            self.updateFormattedTimes(progress: previewTime, duration: self.playerService.duration)
                        }
                        .onEnded { _ in
                            guard self.playerService.duration > 0 else { return }
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
    }

    // MARK: - Controls Row

    private var controlsRow: some View {
        HStack(spacing: 8) {
            // Previous Track
            PlayerBarIconButton(
                action: self.previousTrack,
                accessibilityLabel: String(localized: "Previous track")
            ) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .disabled(self.playerService.currentTrack == nil)

            // Play / Pause
            PlayerBarIconButton(
                action: self.playPause,
                accessibilityLabel: self.playerService.isPlaying ? String(localized: "Pause") : String(localized: "Play")
            ) {
                Image(systemName: self.playerService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(self.playerService.currentTrack == nil)

            // Next Track
            PlayerBarIconButton(
                action: self.nextTrack,
                accessibilityLabel: String(localized: "Next track")
            ) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
            }
            .disabled(self.playerService.currentTrack == nil)

            Spacer()

            // Volume Button & Expandable Mini Slider
            if self.showsVolumeSlider {
                Slider(
                    value: self.$volumeValue,
                    in: 0...1,
                    onEditingChanged: { editing in
                        self.isAdjustingVolume = editing
                        if !editing {
                            self.playerService.setVolumeImmediately(self.volumeValue)
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
                        self.playerService.setVolumeImmediately(newVol)
                    }
                }
            }

            PlayerBarIconButton(
                action: self.toggleVolumeSlider,
                accessibilityLabel: String(localized: "Volume"),
                accessibilityValue: "\(Int(self.playerService.volume * 100))%"
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
        Task {
            await self.playerService.playPause()
        }
    }

    private func previousTrack() {
        HapticService.playback()
        Task {
            await self.playerService.previous()
        }
    }

    private func nextTrack() {
        HapticService.playback()
        Task {
            await self.playerService.next()
        }
    }

    private func toggleVolumeSlider() {
        HapticService.toggle()
        withAnimation(AppAnimation.quick) {
            self.showsVolumeSlider.toggle()
        }
    }

    private func performSeek() {
        let targetProgress = self.seekValue * self.playerService.duration
        self.seekHold.begin(target: targetProgress)
        Task {
            await self.playerService.seek(to: targetProgress)
            self.isSeeking = false
        }
    }

    private func bringAppToFront() {
        HapticService.toggle()
        MainWindowOpener.bringMainWindowToFront(openWindow: self.openWindow)
    }

    // MARK: - Progress & Volume Helpers

    private func displayProgress(observedProgress: TimeInterval) -> TimeInterval {
        if self.isSeeking {
            return self.seekValue * self.playerService.duration
        }
        return self.seekHold.displayProgress(observedProgress: observedProgress)
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

    private var volumeIcon: String {
        let vol = self.playerService.volume
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

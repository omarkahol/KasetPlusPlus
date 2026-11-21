import SwiftUI

// MARK: - YouTubePlayerBar Controls & Helpers

extension YouTubePlayerBar {
    var downloadButton: some View {
        PlayerBarIconButton(
            action: {
                self.youtubePlayer.showsDownloadSheet = true
            },
            accessibilityLabel: String(localized: "Download"),
            icon: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
            }
        )
        .disabled(self.youtubePlayer.currentVideo == nil)
    }

    var pipButton: some View {
        PlayerBarIconButton(
            action: self.toggleYouTubePictureInPicture,
            isSelected: self.youtubePlayer.surfaceLocation == .floating,
            accessibilityID: AccessibilityID.YouTubeContent.watchPictureInPicture,
            accessibilityLabel: self.youtubePlayer.surfaceLocation == .floating
                ? String(localized: "Pop video back into Kaset++")
                : String(localized: "Picture in Picture")
        ) {
            Image(systemName: self.youtubePlayer.surfaceLocation == .floating ? "pip.exit" : "pip.enter")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 13, height: 14)
                .foregroundStyle(self.youtubePlayer.surfaceLocation == .floating ? Self.brandAccent : .primary)
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(self.youtubePlayer.currentVideo == nil || self.youtubePlayer.isWindowFullscreen)
    }

    /// The secondary options (Watch Later, AirPlay, Download, Captions, Speed &
    /// Quality) collapsed into a single "•••" menu when the bar is too narrow to
    /// show them inline.
    var overflowMenu: some View {
        Menu {
            if self.hasPersonalAccount {
                Button {
                    Task {
                        await self.youtubePlayer.toggleWatchLater()
                    }
                } label: {
                    Label(
                        self.youtubePlayer.isInWatchLater
                            ? String(localized: "Remove from Watch Later")
                            : String(localized: "Add to Watch Later"),
                        systemImage: self.youtubePlayer.isInWatchLater ? "clock.fill" : "clock"
                    )
                }
            }

            Button {
                HapticService.toggle()
                self.youtubePlayer.showAirPlayPicker(at: self.airPlayAnchor.screenPoint)
            } label: {
                Label(String(localized: "AirPlay"), systemImage: "airplayvideo")
            }

            if !self.youtubePlayer.isLive {
                Button {
                    self.youtubePlayer.showsDownloadSheet = true
                } label: {
                    Label(String(localized: "Download"), systemImage: "arrow.down.circle")
                }
            }

            Menu {
                self.captionMenuItems
            } label: {
                Label(String(localized: "Captions"), systemImage: "captions.bubble")
            }

            if self.hasAlternateAudio {
                Menu {
                    self.audioMenuItems
                } label: {
                    Label(String(localized: "Audio"), systemImage: "waveform.circle")
                }
            }
            // Speed & Quality lives in its own popover (gear button) since a
            // slider can't be hosted inside an NSMenu — see compactQualityMenu.
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .disabled(self.youtubePlayer.currentVideo == nil)
        .accessibilityLabel(String(localized: "More options"))
    }

    @ViewBuilder private var captionMenuItems: some View {
        Button {
            self.youtubePlayer.selectCaptionTrack(languageCode: nil)
        } label: {
            if self.youtubePlayer.activeCaptionLanguageCode == nil {
                Label(String(localized: "Off"), systemImage: "checkmark")
            } else {
                Text("Off", comment: "Captions off menu item")
            }
        }
        ForEach(self.youtubePlayer.captionTracks) { track in
            Button {
                self.youtubePlayer.selectCaptionTrack(languageCode: track.languageCode)
            } label: {
                if self.youtubePlayer.activeCaptionLanguageCode == track.languageCode {
                    Label(track.displayName, systemImage: "checkmark")
                } else {
                    Text(track.displayName)
                }
            }
        }
    }

    private var hasActiveCaptions: Bool {
        guard let code = self.youtubePlayer.activeCaptionLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty,
              code.lowercased() != "off"
        else { return false }
        return true
    }

    var compactCaptionsMenu: some View {
        Menu {
            self.captionMenuItems
        } label: {
            Image(systemName: self.hasActiveCaptions ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 16, weight: .regular))
                .frame(width: 16, height: 16)
                .foregroundStyle(self.hasActiveCaptions ? Self.brandAccent : Color.primary)
        }
        .tint(self.hasActiveCaptions ? Self.brandAccent : .primary)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .disabled(self.youtubePlayer.currentVideo == nil)
    }

    /// True only for multi-audio videos; single-track videos hide the control.
    var hasAlternateAudio: Bool {
        self.youtubePlayer.audioTracks.count > 1
    }

    private var audioMenuItems: some View {
        ForEach(self.youtubePlayer.audioTracks) { track in
            Button {
                self.youtubePlayer.selectAudioTrack(id: track.id)
            } label: {
                if self.youtubePlayer.activeAudioTrackId == track.id {
                    Label(track.menuDisplayName, systemImage: "checkmark")
                        .foregroundStyle(track.isOriginal ? Self.brandAccent : .primary)
                } else {
                    Text(track.menuDisplayName)
                        .foregroundStyle(track.isOriginal ? Self.brandAccent : .primary)
                }
            }
            .tint(track.isOriginal ? Self.brandAccent : nil)
        }
    }

    @ViewBuilder var compactAudioMenu: some View {
        if self.hasAlternateAudio {
            Menu {
                self.audioMenuItems
            } label: {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .disabled(self.youtubePlayer.currentVideo == nil)
        }
    }

    var compactQualityMenu: some View {
        PlayerBarIconButton(
            action: { self.showsSpeedQualityPopover.toggle() },
            accessibilityLabel: String(localized: "Speed & Quality"),
            icon: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
            }
        )
        .disabled(self.youtubePlayer.currentVideo == nil)
        .popover(isPresented: self.$showsSpeedQualityPopover, arrowEdge: .bottom) {
            self.speedQualityPopover
        }
        // Keep the on-video controls pinned open while the popover is up so the
        // auto-hide (#33) doesn't dismiss the popover out from under the user.
        .onChange(of: self.showsSpeedQualityPopover) { _, open in
            self.youtubePlayer.isControlOverlayPinned = open
        }
    }

    /// Continuous playback-speed slider + quality picker (issue #32: replaces the
    /// old fixed 0.5/0.75/1/1.25/1.5/2 menu with a YouTube-style slider).
    private var speedQualityPopover: some View {
        let speed = Binding(
            get: { self.youtubePlayer.playbackSpeed },
            set: { self.youtubePlayer.playbackSpeed = ($0 * 20).rounded() / 20 } // 0.05 steps
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playback speed").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(self.youtubePlayer.playbackSpeed, specifier: "%.2f")×")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("0.25×").font(.caption2).foregroundStyle(.secondary)
                Slider(value: speed, in: 0.25 ... 2.0)
                    .accessibilityLabel(String(localized: "Playback speed"))
                Text("2×").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { preset in
                    Button {
                        self.youtubePlayer.playbackSpeed = preset
                    } label: {
                        Text(preset == 1.0 ? "Normal" : "\(preset, specifier: "%.2g")×")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(abs(self.youtubePlayer.playbackSpeed - preset) < 0.001 ? Self.brandAccent : nil)
                }
            }
            if !self.youtubePlayer.qualityLevels.isEmpty {
                Divider()
                Text("Quality").font(.subheadline.weight(.semibold))
                ForEach(self.youtubePlayer.qualityLevels, id: \.self) { level in
                    Button {
                        self.youtubePlayer.selectQuality(level)
                    } label: {
                        HStack {
                            Text(YouTubeQuality.displayName(for: level))
                            Spacer()
                            if (self.youtubePlayer.userPinnedQuality ?? "auto") == level {
                                Image(systemName: "checkmark").foregroundStyle(Self.brandAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    static func layoutMetrics(
        forBarWidth width: CGFloat,
        hasPersonalAccount: Bool = true,
        isLive: Bool = false,
        hasAlternateAudio: Bool = false
    ) -> BarLayoutMetrics {
        let showsDetails = width >= Self.detailsCollapseWidth
        let usesCompactDetails = width < Self.fullDetailsWidth
        // `videoDetailsSection` supplies its own 14pt leading padding inside the
        // capsule; when details collapse at narrow widths, apply the same 14pt
        // leading inset to the progress section so the left timestamp clears the
        // 52pt capsule's 26pt corner curve.
        let leadingPadding: CGFloat = showsDetails ? 0 : 14
        let detailsWidth: CGFloat = showsDetails
            ? (usesCompactDetails ? Self.compactVideoDetailsWidth : Self.fullVideoDetailsWidth)
            : 0
        let optionsTier: OptionsTier = width >= Self.fullOptionsWidth ? .full : .reduced
        let optionsWidth = Self.youtubeOptionsWidth(
            tier: optionsTier,
            hasPersonalAccount: hasPersonalAccount,
            isLive: isLive,
            hasAlternateAudio: hasAlternateAudio
        )
        let spacingTotal: CGFloat = showsDetails ? 20 : 10
        let progressWidth = max(0, width - leadingPadding - detailsWidth - optionsWidth - spacingTotal)
        return BarLayoutMetrics(
            showsDetails: showsDetails,
            usesCompactDetails: usesCompactDetails,
            leadingPadding: leadingPadding,
            detailsWidth: detailsWidth,
            optionsTier: optionsTier,
            optionsWidth: optionsWidth,
            progressWidth: progressWidth
        )
    }

    static func youtubeOptionsWidth(
        tier: OptionsTier,
        hasPersonalAccount: Bool = true,
        isLive: Bool = false,
        hasAlternateAudio: Bool = false
    ) -> CGFloat {
        switch tier {
        case .full:
            // Base 5: fullView, airPlay, captions, quality, pip.
            let buttonCount = 5
                + (hasPersonalAccount ? 1 : 0)
                + (!isLive ? 1 : 0)
                + (hasAlternateAudio ? 1 : 0)
            let buttonsWidth = CGFloat(buttonCount) * 28 + CGFloat(max(0, buttonCount - 1)) * 6 + 12
            return max(246, buttonsWidth)
        // Full-view + overflow "•••" + quality + PiP: four 28pt buttons, 6pt spacing, 12pt trailing pad.
        case .reduced:
            return 144
        }
    }

    var currentSeekIdentity: String {
        self.youtubePlayer.currentVideo?.videoId ?? "none"
    }

    var chapterProgressMarkers: [PlayerBarProgressMarker] {
        guard self.youtubePlayer.duration > 0, !self.youtubePlayer.isShowingAd else { return [] }
        return self.youtubePlayer.chapters.compactMap { chapter in
            guard chapter.startTime > 0, chapter.startTime < self.youtubePlayer.duration else { return nil }
            return PlayerBarProgressMarker(
                id: chapter.id,
                fraction: chapter.startTime / self.youtubePlayer.duration,
                title: chapter.title,
                subtitle: chapter.timeText ?? Self.formatTime(chapter.startTime)
            )
        }
    }

    var chapterProgressSegments: [PlayerBarProgressSegment] {
        guard !self.youtubePlayer.isShowingAd else { return [] }
        return Self.chapterProgressSegments(
            chapters: self.youtubePlayer.chapters,
            duration: self.youtubePlayer.duration
        )
    }

    /// Converts YouTube's chapter starts and optional bounds into the same normalized spans used by
    /// the music player's segmented mix seek bar. Marker data remains separate so chapter snapping
    /// and the existing metadata preview continue to work while segment visuals are active.
    static func chapterProgressSegments(
        chapters: [YouTubeChapter],
        duration: TimeInterval
    ) -> [PlayerBarProgressSegment] {
        guard duration.isFinite, duration > 0 else { return [] }

        let sortedChapters = chapters
            .filter { chapter in
                chapter.startTime.isFinite
                    && chapter.startTime >= 0
                    && chapter.startTime < duration
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime {
                    return lhs.startTime < rhs.startTime
                }
                return lhs.title < rhs.title
            }

        var uniqueChapters: [YouTubeChapter] = []
        for chapter in sortedChapters where uniqueChapters.last?.startTime != chapter.startTime {
            uniqueChapters.append(chapter)
        }

        let resolvedChapters: [ChapterProgressSpan] = uniqueChapters.enumerated().compactMap { index, chapter in
            let start = chapter.startTime
            let nextStart = uniqueChapters.indices.contains(index + 1)
                ? uniqueChapters[index + 1].startTime
                : duration
            let upperBound = min(nextStart, duration)
            let explicitEnd = chapter.endTime.flatMap { endTime in
                endTime.isFinite && endTime > start ? endTime : nil
            }
            let end = min(explicitEnd ?? upperBound, upperBound)
            guard end > start else { return nil }
            return ChapterProgressSpan(chapter: chapter, start: start, end: end)
        }

        let count = resolvedChapters.count
        return resolvedChapters.enumerated().map { index, resolved in
            PlayerBarProgressSegment(
                id: resolved.chapter.id,
                start: resolved.start / duration,
                end: resolved.end / duration,
                index: index,
                count: count,
                title: resolved.chapter.title,
                itemLabel: String(localized: "Chapter"),
                rangeText: "\(Self.formatTime(resolved.start)) – \(Self.formatTime(resolved.end))"
            )
        }
    }

    /// Seeking is unavailable during ads or before a duration is known.
    var canSeek: Bool {
        self.youtubePlayer.duration > 0 && !self.youtubePlayer.isShowingAd
    }

    var isProgressLoading: Bool {
        self.youtubePlayer.isPlaybackLoading
    }

    var canNavigateToCurrentChannel: Bool {
        self.youtubeStore != nil && self.currentChannelId != nil
    }

    private var currentChannelId: String? {
        guard let channelId = self.youtubePlayer.currentVideo?.channelId, !channelId.isEmpty else {
            return nil
        }
        return channelId
    }

    func openCurrentChannel() {
        guard let channelId = self.currentChannelId else { return }
        self.youtubeStore?.navigationPath.append(YouTubeRoute.channel(channelId: channelId))
    }

    var volumeIcon: String {
        if self.displayedVolume == 0 {
            "speaker.slash.fill"
        } else if self.displayedVolume < 0.5 {
            "speaker.wave.1.fill"
        } else {
            "speaker.wave.2.fill"
        }
    }

    var displayedVolume: Double {
        self.isAdjustingVolume ? self.volumeValue : self.youtubePlayer.volume
    }

    func toggleYouTubeVolumeOverlay() {
        HapticService.toggle()
        let isPresented = !self.showsVolumeOverlay
        withAnimation(AppAnimation.quick) {
            self.showsVolumeOverlay = isPresented
        }
    }

    func openYouTubeFullView() {
        HapticService.toggle()
        if self.youtubePlayer.surfaceLocation == .inline {
            self.youtubePlayer.popOutToWindow()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                YouTubeVideoWindowController.shared.toggleFullscreen(returnInlineOnExit: true)
            }
        } else {
            YouTubeVideoWindowController.shared.toggleFullscreen()
        }
    }

    private func toggleYouTubePictureInPicture() {
        guard !self.youtubePlayer.isWindowFullscreen else { return }
        HapticService.toggle()
        if self.youtubePlayer.surfaceLocation == .floating {
            self.youtubePlayer.requestPopIn()
        } else {
            self.youtubePlayer.popOutToWindow()
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Per-View Inset

extension View {
    /// Attaches the YouTube player bar to the bottom of a navigable view.
    ///
    /// Applied to EVERY YouTube view (roots and pushed destinations) —
    /// views pushed onto a `NavigationStack` do not inherit a parent's
    /// `safeAreaInset`, the same rule the music side follows with
    /// `PlayerBar` (see docs/architecture.md).
    func youtubePlayerBarInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            YouTubePlayerBar()
        }
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchPlayPause = "youtubeContent.watchPlayPause"
    static let watchLikeButton = "youtubeContent.watchLikeButton"
    static let watchDislikeButton = "youtubeContent.watchDislikeButton"
    static let watchLaterButton = "youtubeContent.watchLaterButton"
    static let watchPictureInPicture = "youtubeContent.watchPictureInPicture"
    static let watchFullView = "youtubeContent.watchFullView"
    static let captionsButton = "youtubeContent.captionsButton"
    static let qualityButton = "youtubeContent.qualityButton"
}

// MARK: - YouTubePlayerProgressLaneHost

/// Isolated progress leaf so 4 Hz `youtubePlayer.progress` updates only
/// re-evaluate the scrubber lane instead of the entire `YouTubePlayerBar`.
struct YouTubePlayerProgressLaneHost: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer

    let accent: Color
    let markers: [PlayerBarProgressMarker]
    let segments: [PlayerBarProgressSegment]
    let canSeek: Bool
    let isLoading: Bool
    let currentSeekIdentity: String
    let segmentMarkers: [PlayerBarSegmentMarker]
    let heatmap: [YouTubeHeatmapMarker]
    let onMarkerPreviewChange: (PlayerBarProgressMarker?) -> Void
    let onHoverFractionChange: ((Double?) -> Void)?

    var body: some View {
        PlayerBarProgressLaneHost(
            progress: self.youtubePlayer.progress,
            duration: self.youtubePlayer.duration,
            isShowingAd: self.youtubePlayer.isShowingAd,
            isLive: false,
            canSeek: self.canSeek,
            isLoading: self.isLoading,
            currentSeekIdentity: self.currentSeekIdentity,
            accent: self.accent,
            markers: self.markers,
            segments: self.segments,
            segmentMarkers: self.segmentMarkers,
            heatmap: self.heatmap,
            inlineTimestamps: true,
            onMarkerPreviewChange: self.onMarkerPreviewChange,
            onHoverFractionChange: self.onHoverFractionChange,
            onSeek: { seekTime in
                self.youtubePlayer.seek(to: seekTime)
            }
        )
    }
}

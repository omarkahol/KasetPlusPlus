import SwiftUI

// MARK: - YouTubePlayerBar

/// The Liquid Glass player bar for inline and detached YouTube playback.
///
/// Transport controls seek 30 seconds within the video. Chapter markers appear
/// in the progress bar, and video controls manage captions, quality, AirPlay,
/// picture in picture, and fullscreen.
struct YouTubePlayerBar: View {
    /// Where these controls are shown.
    enum Mode {
        /// The docked transport bar at the bottom of the window (default).
        case docked
        /// Overlaid on the video itself (details/thumbnail dropped, scrim behind).
        case videoOverlay
    }

    /// Rendering mode. `docked` keeps the historical behavior; the watch page
    /// passes `videoOverlay` to reuse the exact same controls on the video.
    var mode: Mode = .docked

    /// Reports volume-overlay presentation so a detached window can keep its
    /// chrome visible while the slider is open (upstream #460).
    var onVolumeOverlayChange: (Bool) -> Void = { _ in }

    @MainActor private static var brandAccent: Color { SettingsManager.shared.accentColor }
    private static let fullVideoDetailsWidth: CGFloat = 294
    private static let compactVideoDetailsWidth: CGFloat = 72

    /// How densely the trailing option buttons are packed. On a narrow bar (the
    /// pop-out/PiP window can shrink to ~480pt wide) the secondary options
    /// collapse into a single "•••" overflow menu so the transport controls keep
    /// room and never overlap the elapsed/remaining time labels.
    enum OptionsTier: Equatable {
        case full // every option inline
        case reduced // full-view + overflow menu + quality menu + PiP
    }

    struct BarLayoutMetrics: Equatable {
        let showsDetails: Bool
        let usesCompactDetails: Bool
        let leadingPadding: CGFloat
        let detailsWidth: CGFloat
        let optionsTier: OptionsTier
        let optionsWidth: CGFloat
        let progressWidth: CGFloat
    }

    /// Below this bar width the thumbnail/title details are dropped entirely to
    /// give the transport controls and progress lane room.
    private static let detailsCollapseWidth: CGFloat = 600
    /// At/above this bar width full title/channel details are shown alongside
    /// the progress lane and full options without compressing the scrubber.
    private static let fullDetailsWidth: CGFloat = 840
    /// At/above this bar width every option button is shown inline; below it they
    /// collapse into the overflow menu.
    private static let fullOptionsWidth: CGFloat = 760
    /// When the video has chapters, the progress lane floats a chapter tooltip
    /// above the track; lift the scrub bubble just enough that its timestamp
    /// capsule sits a little above the chapter tooltip instead of landing on it
    /// (close, with a small gap — not floating far above).
    /// ponytail: fixed heuristic; nudge if the two ever touch or drift apart.
    private static let chapterScrubLift: CGFloat = 22

    private struct ChapterProgressSpan {
        let chapter: YouTubeChapter
        let start: TimeInterval
        let end: TimeInterval
    }

    @Environment(AuthService.self) private var authService
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @Environment(YouTubeViewModelStore.self) private var youtubeStore: YouTubeViewModelStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Namespace for glass effect morphing.
    @Namespace private var playerNamespace

    @State private var volumeValue: Double = 1.0
    @State private var isAdjustingVolume = false
    @State private var showsVolumeOverlay = false
    @State private var chapterPreviewMarker: PlayerBarProgressMarker?
    @State private var hoverPreviewFraction: Double?
    @State private var settings = SettingsManager.shared
    @State private var showsSpeedQualityPopover = false
    @State private var airPlayAnchor = AirPlayPickerAnchor()

    var body: some View {
        self.content
        .onChange(of: self.currentSeekIdentity) { _, _ in
            self.chapterPreviewMarker = nil
        }
        .onChange(of: self.youtubePlayer.isShowingAd) { _, _ in
            self.chapterPreviewMarker = nil
        }
        .onChange(of: self.youtubePlayer.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onChange(of: self.showsVolumeOverlay) { _, isPresented in self.onVolumeOverlayChange(isPresented) }
        .onAppear {
            self.volumeValue = self.youtubePlayer.volume
        }
    }

    @ViewBuilder
    private var content: some View {
        switch self.mode {
        case .docked:
            if self.hidesForInlineOverlay {
                // The watch page renders these controls on the video instead;
                // collapse the docked bar so no inset space is reserved.
                Color.clear.frame(height: 0)
            } else {
                self.dockedBar
            }
        case .videoOverlay:
            self.videoOverlayControls
        }
    }

    /// The docked bar hides itself whenever the watch page is showing the same
    /// controls on the video (setting on + a video playing inline). Computed
    /// directly here instead of via a set-from-elsewhere flag, so it can't get
    /// out of sync and leave two bars on screen.
    private var hidesForInlineOverlay: Bool {
        // Only consulted from the `.docked` branch, so no need to re-check mode.
        // Requires the video to be on screen — once it's scrolled out of view,
        // the docked bar comes back so playback stays controllable.
        self.settings.controlsOnVideoEnabled
            && self.youtubePlayer.currentVideo != nil
            && self.youtubePlayer.surfaceLocation == .inline
            && self.youtubePlayer.inlineVideoOnScreen
    }

    /// The historical docked transport bar (thumbnail/title + progress + options
    /// in a glass capsule at the bottom of the window).
    private var dockedBar: some View {
        CompatGlassContainer(spacing: 0) {
            GeometryReader { proxy in
                let metrics = Self.layoutMetrics(
                    forBarWidth: proxy.size.width,
                    hasPersonalAccount: self.hasPersonalAccount,
                    isLive: self.youtubePlayer.isLive,
                    hasAlternateAudio: self.hasAlternateAudio
                )

                HStack(spacing: 10) {
                    if metrics.showsDetails {
                        self.videoDetailsSection(usesCompactDetails: metrics.usesCompactDetails)
                            .frame(width: metrics.detailsWidth, height: 52)
                    }

                    self.youtubeProgressSection(showsHeatmap: false)
                        .padding(.leading, metrics.leadingPadding)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .frame(height: 52)
                        .layoutPriority(1)

                    self.youtubeOptionsSection(tier: metrics.optionsTier)
                        .frame(width: metrics.optionsWidth, height: 52)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .compatGlass(interactive: true, in: .capsule)
            .compatGlassID("youtubePlayerBar", in: self.playerNamespace)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            self.playerAreaFade
        }
    }

    /// The same progress + options controls (no thumbnail/title — the video is
    /// right there), laid over a bottom scrim. Reuses `youtubeOptionsSection`,
    /// which already collapses quality/captions into menus on narrow widths.
    private var videoOverlayControls: some View {
        GeometryReader { proxy in
            let optionsTier: OptionsTier = proxy.size.width >= Self.fullOptionsWidth ? .full : .reduced
            let optionsWidth = Self.youtubeOptionsWidth(
                tier: optionsTier,
                hasPersonalAccount: self.hasPersonalAccount,
                isLive: self.youtubePlayer.isLive,
                hasAlternateAudio: self.hasAlternateAudio
            )

            HStack(spacing: 10) {
                self.youtubeProgressSection(showsHeatmap: true)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: 52)
                    .layoutPriority(1)

                self.youtubeOptionsSection(tier: optionsTier)
                    .frame(width: optionsWidth, height: 52)
            }
        }
        .frame(height: 52)
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .padding(.bottom, 10)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    private var playerAreaFade: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor).opacity(0),
                Color(nsColor: .windowBackgroundColor).opacity(0.22),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Updated Player Layout

    private func videoDetailsSection(usesCompactDetails: Bool) -> some View {
        HStack(spacing: 8) {
            PlayerBarArtworkView(
                width: 57,
                height: 32,
                cornerRadius: 6,
                glowSources: self.currentVideoGlowSources,
                glowIdentity: self.currentVideoGlowIdentity,
                glowTargetSize: CGSize(width: 64, height: 36),
                showsHoverOverlay: false
            ) {
                CachedAsyncImage(
                    url: self.youtubePlayer.currentVideo?.thumbnailURL,
                    targetSize: CGSize(width: 64, height: 36)
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 57, height: 32)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                // When the video is playing docked with no watch view on screen
                // (the "keep playing on navigate-away" option), the thumbnail
                // returns the user to the video. Shown as a subtle overlay hint.
                .overlay {
                    if self.youtubePlayer.isPlayingDockedWithoutWatchView {
                        Image(systemName: "rectangle.expand.vertical")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                }
            }
            .accessibilityHidden(self.youtubePlayer.currentVideo == nil)
            .contentShape(.rect)
            .onTapGesture {
                guard self.youtubePlayer.isPlayingDockedWithoutWatchView else { return }
                HapticService.toggle()
                self.youtubePlayer.requestReturnToWatchView()
            }
            .help(self.youtubePlayer.isPlayingDockedWithoutWatchView
                ? String(localized: "Return to video")
                : "")

            if !usesCompactDetails {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        PlayerBarMarqueeText(
                            text: self.videoDetailsTitle,
                            font: .system(size: 13),
                            color: .primary,
                            height: 13,
                            reduceMotion: self.reduceMotion
                        )
                        .id(self.currentTitleIdentity)

                        if self.hasDearrow {
                            Button {
                                self.youtubePlayer.showsDearrowOriginal.toggle()
                            } label: {
                                Image(systemName: self.youtubePlayer.showsDearrowOriginal ? "arrow.uturn.backward.circle.fill" : "arrow.triangle.swap")
                                    .font(.system(size: 10))
                                    .foregroundStyle(self.youtubePlayer.showsDearrowOriginal ? .orange : SponsorSegment.brandColor)
                            }
                            .buttonStyle(.plain)
                            .help(self.youtubePlayer.showsDearrowOriginal
                                ? String(localized: "Show DeArrow title")
                                : String(localized: "Show original title"))
                            .accessibilityLabel(self.youtubePlayer.showsDearrowOriginal
                                ? String(localized: "Show DeArrow title")
                                : String(localized: "Show original title"))
                        }
                    }

                    if self.isShowingChapterPreview {
                        Spacer()
                            .frame(height: 11)
                    } else {
                        PlayerBarMetadataButton(
                            text: self.youtubePlayer.currentVideo?.channelName ?? String(localized: "YouTube"),
                            isEnabled: self.canNavigateToCurrentChannel,
                            action: self.openCurrentChannel
                        )
                    }
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            }

            // Like/dislike moved to video metadata area (YouTubeWatchView)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    private var currentVideoGlowSources: [URL] {
        guard let video = self.youtubePlayer.currentVideo else { return [] }
        return self.uniqueURLs([
            self.fallbackThumbnailURL(for: video.videoId),
            video.thumbnailURL,
        ])
    }

    private var currentVideoGlowIdentity: String? {
        guard let video = self.youtubePlayer.currentVideo else { return nil }
        return video.videoId
    }

    private func fallbackThumbnailURL(for videoId: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoId)/mqdefault.jpg")
    }

    private func uniqueURLs(_ urls: [URL?]) -> [URL] {
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard let url, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    private var currentTitleIdentity: String {
        [
            self.youtubePlayer.currentVideo?.id ?? "none",
            self.youtubePlayer.currentVideo?.title ?? "none",
            self.chapterPreviewMarker?.id ?? "none",
            self.youtubePlayer.showsDearrowOriginal ? "orig" : "dearrow",
            self.youtubePlayer.dearrowTitle ?? "none",
        ].joined(separator: "|")
    }

    private var videoDetailsTitle: String {
        // DeArrow takes priority over chapter preview for the base title
        let baseTitle: String = {
            if self.youtubePlayer.showsDearrowOriginal,
               let orig = self.youtubePlayer.dearrowOriginalTitle
            {
                return orig
            }
            return self.youtubePlayer.dearrowTitle
                ?? self.youtubePlayer.currentVideo?.title
                ?? String(localized: "Not Playing")
        }()

        // Overlay chapter preview on top if active
        guard let chapterPreviewMarker, let chapterTitle = chapterPreviewMarker.title else {
            return baseTitle
        }
        if let subtitle = chapterPreviewMarker.subtitle {
            return "\(subtitle) · \(chapterTitle)"
        }
        return chapterTitle
    }

    private var hasDearrow: Bool {
        self.youtubePlayer.dearrowTitle != nil
    }

    private var isShowingChapterPreview: Bool {
        self.chapterPreviewMarker?.title != nil
    }

    private func youtubeProgressSection(showsHeatmap: Bool = false) -> some View {
        VStack(spacing: 2) {
            self.youtubeTransportControls
                .frame(height: 28)

            Group {
                if self.youtubePlayer.isShowingAd {
                    PlayerBarAdIndicator()
                } else {
                    YouTubePlayerProgressLaneHost(
                        accent: Self.brandAccent,
                        markers: self.chapterProgressMarkers,
                        segments: self.chapterProgressSegments,
                        canSeek: self.canSeek,
                        isLoading: self.isProgressLoading,
                        currentSeekIdentity: self.currentSeekIdentity,
                        segmentMarkers: self.segmentFractionMarkers,
                        heatmap: showsHeatmap ? self.youtubePlayer.heatmap : [],
                        onMarkerPreviewChange: { marker in
                            self.chapterPreviewMarker = marker
                        },
                        onHoverFractionChange: self.mode == .videoOverlay
                            ? { fraction in self.hoverPreviewFraction = fraction }
                            : nil
                    )
                }
            }
            .zIndex(1)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Storyboard scrub preview, floating over the video above the bar
        // (and above the "most replayed" band), YouTube-style. Only on the
        // on-video overlay bar, and only when a storyboard spec resolved.
        .overlay(alignment: .topLeading) {
            if let hoverFraction = self.hoverPreviewFraction,
               self.mode == .videoOverlay,
               !self.youtubePlayer.isLive,
               !self.isProgressLoading,
               self.youtubePlayer.duration > 0,
               let spec = self.youtubePlayer.storyboardSpec
            {
                GeometryReader { proxy in
                    let halfWidth = StoryboardHoverPreview.previewWidth / 2
                    StoryboardHoverPreview(
                        spec: spec,
                        fraction: hoverFraction,
                        duration: self.youtubePlayer.duration
                    )
                    // The lane's track spans this section's full width, so the
                    // hovered fraction maps 1:1 onto proxy width; clamp so the
                    // bubble never spills past the bar's ends. The track sits
                    // ~36pt below the section top, so a center 54pt above the
                    // top edge leaves the bubble clear of the heatmap band.
                    .position(
                        x: min(
                            max(halfWidth, proxy.size.width * hoverFraction),
                            max(halfWidth, proxy.size.width - halfWidth)
                        ),
                        // Lift clear of the chapter tooltip when the video has chapters.
                        y: -StoryboardHoverPreview.totalHeight / 2 + 6
                            - (self.youtubePlayer.chapters.isEmpty ? 0 : Self.chapterScrubLift)
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Converts SponsorBlock segments (seconds) to fraction pairs for the progress lane.
    private var segmentFractionMarkers: [PlayerBarSegmentMarker] {
        let dur = self.youtubePlayer.duration
        // During an ad the <video> is the ad clip: its duration/timeline are
        // unrelated to the content's SponsorBlock segments, so drawing them
        // would smear meaningless bars across the ad's progress lane.
        guard dur > 0, !self.youtubePlayer.isShowingAd else { return [] }
        return self.youtubePlayer.sponsorSegments.map { seg in
            PlayerBarSegmentMarker(
                fractionStart: seg.start / dur,
                fractionEnd: seg.end / dur,
                color: seg.color
            )
        }
    }

    private var youtubeTransportControls: some View {
        HStack(spacing: 6) {
            if self.youtubePlayer.isLive {
                Button {
                    HapticService.playback()
                    self.youtubePlayer.seekToLive()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(self.youtubePlayer.isAtLiveEdge ? Color.red : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text("LIVE", comment: "Button that jumps to the live edge of a stream")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(self.youtubePlayer.isAtLiveEdge ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Jump to live"))
                .accessibilityLabel(String(localized: "Jump to live"))
            }

            PlayerBarIconButton(
                action: {
                    HapticService.playback()
                    self.youtubePlayer.seekBackward()
                },
                accessibilityLabel: String(localized: "Back 30 seconds"),
                icon: {
                    Image(systemName: "gobackward.30")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                }
            )
            .disabled(!self.canSeek)

            PlayerBarIconButton(
                action: {
                    HapticService.playback()
                    self.youtubePlayer.playPause()
                },
                accessibilityID: AccessibilityID.YouTubeContent.watchPlayPause,
                accessibilityLabel: self.youtubePlayer.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
                icon: {
                    Image(systemName: self.youtubePlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 12, height: 20)
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            )
            .compatGlassID("youtubePlayPause", in: self.playerNamespace)
            .disabled(self.youtubePlayer.currentVideo == nil)

            PlayerBarIconButton(
                action: {
                    HapticService.playback()
                    self.youtubePlayer.seekForward()
                },
                accessibilityLabel: String(localized: "Forward 30 seconds"),
                icon: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.primary)
                }
            )
            .disabled(!self.canSeek)

            PlayerBarIconButton(
                action: self.toggleYouTubeVolumeOverlay,
                accessibilityLabel: String(localized: "Volume"),
                accessibilityValue: "\(Int(self.displayedVolume * 100))%",
                icon: {
                    Image(systemName: self.volumeIcon)
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 10, height: 15)
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
            )
            .playerBarVolumeOverlay(isPresented: self.$showsVolumeOverlay) {
                PlayerBarVolumeOverlay(
                    value: self.$volumeValue,
                    isAdjusting: self.$isAdjustingVolume,
                    volumeIcon: self.volumeIcon,
                    accent: Self.brandAccent,
                    onSetVolume: { newValue in
                        self.youtubePlayer.volume = newValue
                    }
                )
            }
        }
    }

    private func youtubeOptionsSection(tier: OptionsTier) -> some View {
        HStack(spacing: 6) {
            self.fullViewButton

            switch tier {
            case .full:
                if self.hasPersonalAccount {
                    self.watchLaterButton
                }
                self.airPlayButton
                // Live streams can't be downloaded — hide the button for them.
                if !self.youtubePlayer.isLive {
                    self.downloadButton
                }
                self.compactCaptionsMenu
                self.compactAudioMenu
                self.compactQualityMenu
            case .reduced:
                self.overflowMenu
                self.compactQualityMenu
            }

            self.pipButton
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private var fullViewButton: some View {
        PlayerBarIconButton(
            action: self.openYouTubeFullView,
            accessibilityID: AccessibilityID.YouTubeContent.watchFullView,
            accessibilityLabel: String(localized: "Full view"),
            icon: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
            }
        )
        .disabled(self.youtubePlayer.currentVideo == nil)
    }

    private var watchLaterButton: some View {
        PlayerBarIconButton(
            action: {
                Task {
                    await self.youtubePlayer.toggleWatchLater()
                }
            },
            isSelected: self.youtubePlayer.isInWatchLater,
            accessibilityID: AccessibilityID.YouTubeContent.watchLaterButton,
            accessibilityLabel: String(localized: "Add to Watch Later"),
            icon: {
                Image(systemName: self.youtubePlayer.isInWatchLater ? "clock.fill" : "clock")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(self.youtubePlayer.isInWatchLater ? Self.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        )
        .symbolEffect(.bounce, value: self.youtubePlayer.isInWatchLater)
        .disabled(self.youtubePlayer.currentVideo == nil)
    }

    private var airPlayButton: some View {
        PlayerBarIconButton(
            action: {
                HapticService.toggle()
                self.youtubePlayer.showAirPlayPicker(at: self.airPlayAnchor.screenPoint)
            },
            accessibilityLabel: String(localized: "AirPlay"),
            icon: {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 10, height: 16)
                    .foregroundStyle(.primary)
            }
        )
        .background {
            AirPlayPickerAnchorView(anchor: self.airPlayAnchor)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .disabled(self.youtubePlayer.currentVideo == nil)
    }

    private var downloadButton: some View {
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

    private var pipButton: some View {
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
    private var overflowMenu: some View {
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

    private var compactCaptionsMenu: some View {
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
    private var hasAlternateAudio: Bool {
        self.youtubePlayer.audioTracks.count > 1
    }

    @ViewBuilder private var audioMenuItems: some View {
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

    @ViewBuilder private var compactAudioMenu: some View {
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

    private var compactQualityMenu: some View {
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

    private var currentSeekIdentity: String {
        self.youtubePlayer.currentVideo?.videoId ?? "none"
    }

    private var chapterProgressMarkers: [PlayerBarProgressMarker] {
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

    private var chapterProgressSegments: [PlayerBarProgressSegment] {
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
    private var canSeek: Bool {
        self.youtubePlayer.duration > 0 && !self.youtubePlayer.isShowingAd
    }

    private var isProgressLoading: Bool {
        self.youtubePlayer.isPlaybackLoading
    }

    private var canNavigateToCurrentChannel: Bool {
        self.youtubeStore != nil && self.currentChannelId != nil
    }

    private var currentChannelId: String? {
        guard let channelId = self.youtubePlayer.currentVideo?.channelId, !channelId.isEmpty else {
            return nil
        }
        return channelId
    }

    private func openCurrentChannel() {
        guard let channelId = self.currentChannelId else { return }
        self.youtubeStore?.navigationPath.append(YouTubeRoute.channel(channelId: channelId))
    }

    private var volumeIcon: String {
        if self.displayedVolume == 0 {
            "speaker.slash.fill"
        } else if self.displayedVolume < 0.5 {
            "speaker.wave.1.fill"
        } else {
            "speaker.wave.2.fill"
        }
    }

    private var displayedVolume: Double {
        self.isAdjustingVolume ? self.volumeValue : self.youtubePlayer.volume
    }

    private func toggleYouTubeVolumeOverlay() {
        HapticService.toggle()
        let isPresented = !self.showsVolumeOverlay
        withAnimation(AppAnimation.quick) {
            self.showsVolumeOverlay = isPresented
        }
    }

    private func openYouTubeFullView() {
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
private struct YouTubePlayerProgressLaneHost: View {
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

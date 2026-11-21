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

    @MainActor static var brandAccent: Color {
        SettingsManager.shared.accentColor
    }

    static let fullVideoDetailsWidth: CGFloat = 294
    static let compactVideoDetailsWidth: CGFloat = 72

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
    static let detailsCollapseWidth: CGFloat = 600
    /// At/above this bar width full title/channel details are shown alongside
    /// the progress lane and full options without compressing the scrubber.
    static let fullDetailsWidth: CGFloat = 840
    /// At/above this bar width every option button is shown inline; below it they
    /// collapse into the overflow menu.
    static let fullOptionsWidth: CGFloat = 760
    /// When the video has chapters, the progress lane floats a chapter tooltip
    /// above the track; lift the scrub bubble just enough that its timestamp
    /// capsule sits a little above the chapter tooltip instead of landing on it
    /// (close, with a small gap — not floating far above).
    /// ponytail: fixed heuristic; nudge if the two ever touch or drift apart.
    private static let chapterScrubLift: CGFloat = 22

    struct ChapterProgressSpan {
        let chapter: YouTubeChapter
        let start: TimeInterval
        let end: TimeInterval
    }

    @Environment(AuthService.self) private var authService
    @Environment(YouTubePlayerService.self) var youtubePlayer
    @Environment(YouTubeViewModelStore.self) var youtubeStore: YouTubeViewModelStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Namespace for glass effect morphing.
    @Namespace private var playerNamespace

    @State var volumeValue: Double = 1.0
    @State var isAdjustingVolume = false
    @State var showsVolumeOverlay = false
    @State private var chapterPreviewMarker: PlayerBarProgressMarker?
    @State private var hoverPreviewFraction: Double?
    @State private var settings = SettingsManager.shared
    @State private var dearrowCache = DearrowCache.shared
    @State var showsSpeedQualityPopover = false
    @State var airPlayAnchor = AirPlayPickerAnchor()

    var body: some View {
        self.content
            .task(id: "\(self.youtubePlayer.currentVideo?.videoId ?? "")-\(self.settings.dearrowEnabled)") {
                guard self.settings.dearrowEnabled,
                      let video = self.youtubePlayer.currentVideo
                else { return }
                if !video.title.isEmpty {
                    self.dearrowCache.registerOriginalTitle(video.title, for: video.videoId)
                }
                self.dearrowCache.fetchOneIfNeeded(videoId: video.videoId)
            }
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

    @ViewBuilder private var content: some View {
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

    var hasPersonalAccount: Bool {
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

    private var activeDearrowTitle: String? {
        guard self.settings.dearrowEnabled,
              let videoId = self.youtubePlayer.currentVideo?.videoId
        else { return nil }
        return self.dearrowCache.dearrowTitle(for: videoId)
    }

    private var currentTitleIdentity: String {
        [
            self.youtubePlayer.currentVideo?.id ?? "none",
            self.youtubePlayer.currentVideo?.title ?? "none",
            self.chapterPreviewMarker?.id ?? "none",
            self.youtubePlayer.showsDearrowOriginal ? "orig" : "dearrow",
            self.activeDearrowTitle ?? "none",
        ].joined(separator: "|")
    }

    private var videoDetailsTitle: String {
        // DeArrow takes priority over chapter preview for the base title
        let baseTitle: String = {
            if self.settings.dearrowEnabled,
               !self.youtubePlayer.showsDearrowOriginal,
               let dearrow = self.activeDearrowTitle
            {
                return dearrow
            }
            if self.settings.dearrowEnabled,
               self.youtubePlayer.showsDearrowOriginal,
               let orig = self.youtubePlayer.dearrowOriginalTitle
            {
                return orig
            }
            return self.youtubePlayer.currentVideo?.title
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
        self.activeDearrowTitle != nil
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
}

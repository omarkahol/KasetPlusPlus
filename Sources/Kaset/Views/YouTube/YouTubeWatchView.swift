import AppKit
import SwiftUI

// MARK: - YouTubeWatchView

/// Watch page for a YouTube video: the extracted video surface with native
/// controls, metadata, and the related list.
///
/// The surface is the singleton `YouTubeWatchWebView`, docked here while
/// this view owns it. Navigating away while playing hands the surface off
/// to the floating window (`YouTubeVideoWindowController`).
struct YouTubeWatchView: View {
    @MainActor static var brandAccent: Color {
        SettingsManager.shared.accentColor
    }

    let video: YouTubeVideo

    @Environment(AuthService.self) var authService
    @Environment(AccountService.self) var accountService
    @Environment(YouTubePlayerService.self) var youtubePlayer
    @Environment(\.openURL) var openURL
    @Environment(\.openWindow) var openWindow
    @State var viewModel: YouTubeWatchViewModel

    init(video: YouTubeVideo, client: any YouTubeClientProtocol) {
        self.video = video
        self._viewModel = State(
            initialValue: YouTubeWatchViewModel(video: video, client: client)
        )
    }

    @State var commentDraft = ""
    @State var settings = SettingsManager.shared
    @State var networkMonitor = NetworkMonitor.shared
    @State var lyricsSearchQuery = ""
    @State var showsDownloadSheet = false
    @State var showsSavePopover = false

    @State var commentSearchQuery = ""
    @State var liveChatDraft = ""

    /// Whether the "Collaborators" picker (for multi-channel uploads) is showing.
    @State var showsCollaborators = false

    /// Whether the trailing inspector (Suggested / Comments / Live Chat) is open.
    @AppStorage("youtubeWatchInspectorOpen") var showsInspector = false

    /// Active tab inside the trailing inspector.
    @State var inspectorTab: WatchInspectorTab = .suggested

    @State var showsSummary = false
    @State var showsDescription = false
    @State var summaryCoordinator = VideoSummaryCoordinator()
    @State var lyricsService = LyricsSearchService()
    @State var lyricsExpandedID: Int?

    private var resolvedTitle: String {
        let fallbackTitle = self.viewModel.data.videoTitle ?? self.video.title
        guard self.settings.dearrowEnabled else {
            return fallbackTitle
        }
        if self.youtubePlayer.showsDearrowOriginal,
           let orig = self.youtubePlayer.dearrowOriginalTitle
        {
            return orig
        }
        return self.youtubePlayer.dearrowTitle ?? fallbackTitle
    }

    private var hasDearrow: Bool {
        self.settings.dearrowEnabled && self.youtubePlayer.dearrowTitle != nil
    }

    private var askAccountScope: YouTubeAskAccountScopeObservation {
        YouTubeAskAccountScopeObservation(
            authenticationGeneration: self.authService.accountIdentityGeneration,
            hasPersonalAccount: self.authService.hasPersonalAccount,
            accountScopeID: self.accountService.currentAccountScopeID,
            isPrimaryAccount: self.accountService.currentAccount?.isPrimary,
            verifiedIdentitySequence: self.accountService.verifiedIdentitySequence
        )
    }

    private var isInspectorPresented: Binding<Bool> {
        Binding(
            get: { self.showsInspector && !self.settings.distractionFreeEnabled },
            set: { self.showsInspector = $0 }
        )
    }

    var body: some View {
        Group {
            if self.settings.isOfflineModeEnabled {
                ErrorView(
                    title: String(localized: "Offline Mode Enabled"),
                    message: String(localized: "Turn off Offline Mode to stream YouTube videos.")
                ) {
                    self.settings.isOfflineModeEnabled = false
                    Task { await self.viewModel.load() }
                }
            } else if !self.networkMonitor.isConnected {
                ErrorView(
                    title: String(localized: "No Connection"),
                    message: String(localized: "Please check your internet connection and try again.")
                ) {
                    Task { await self.viewModel.load() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        self.videoSurface
                            .contextMenu { self.videoContextMenu }

                        self.primaryBelowVideoColumn
                    }
                    .frame(maxWidth: Self.maxVideoStageWidth, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .disabled(self.viewModel.ask.isExpanded)
        // PROTOTYPE: full-bleed ambient color behind the page. `.ignoresSafeArea`
        // (inside the host) lets it bleed under the bottom player-bar inset,
        // so the bar's Liquid Glass capsule refracts the live color. Hosted in
        // a child view so ITS body — not this whole page — is what re-renders
        // on the 1 Hz playback-progress updates the live style follows.
        .background {
            WatchAmbientBackground(video: self.video)
        }
        // The in-page metadata shows the title; keep the bar clean.
        .navigationTitle(String(localized: ""))
        // Let the ambient reach under the nav bar, like the other accent pages.
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .toolbar {
            if self.viewModel.ask.isAvailable {
                ToolbarItem(placement: .primaryAction) {
                    YouTubeAskToolbarButton(viewModel: self.viewModel.ask)
                }
            }
            if !self.settings.distractionFreeEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        self.showsInspector.toggle()
                    } label: {
                        Label(
                            String(localized: "Suggested"),
                            systemImage: "sidebar.right"
                        )
                    }
                    .help(String(localized: "Suggested"))
                    .keyboardShortcut("i", modifiers: [.command, .option])
                }
            }
        }
        .inspector(isPresented: self.isInspectorPresented) {
            self.watchInspectorContent
                .inspectorColumnWidth(min: 300, ideal: 360, max: 440)
        }
        .overlay {
            WatchAskFloatingOverlayHost(
                videoId: self.video.videoId,
                viewModel: self.viewModel.ask
            )
        }
        .youtubeAskAccessibilityAnnouncements(viewModel: self.viewModel.ask)
        .toolbar {
            self.ambientStylePicker
        }
        .onChange(of: self.youtubePlayer.showsDownloadSheet) { _, newValue in
            if newValue {
                self.showsDownloadSheet = true
                self.youtubePlayer.showsDownloadSheet = false
            }
        }
        .sheet(isPresented: self.$showsDownloadSheet) {
            YouTubeDownloadSheet(
                videoId: self.video.videoId,
                videoTitle: self.viewModel.data.videoTitle ?? self.video.title
            )
        }
        .task(id: self.video.videoId) {
            self.startOrAdoptPlayback()
        }
        .task(id: "\(self.video.videoId)-\(self.settings.dearrowEnabled)") {
            guard self.settings.dearrowEnabled else { return }
            let origTitle = self.viewModel.data.videoTitle ?? self.video.title
            DearrowCache.shared.registerOriginalTitle(origTitle, for: self.video.videoId)
            DearrowCache.shared.fetchOneIfNeeded(videoId: self.video.videoId)
        }
        .task(id: self.askAccountScope) {
            let accountScope = self.askAccountScope
            await self.viewModel.load(accountScope: accountScope)
            // Feed the related list to the player so the bar's next/previous
            // buttons can skip between videos.
            if self.youtubePlayer.currentVideo?.videoId == self.video.videoId {
                self.youtubePlayer.setUpNext(self.upNextQueue)
                self.youtubePlayer.setChapters(self.viewModel.data.chapters)
                self.youtubePlayer.setHeatmap(self.viewModel.data.heatmap)
            }
        }
        .onDisappear {
            self.viewModel.cancel()
            self.youtubePlayer.inlineSurfaceWillDisappear(videoId: self.video.videoId)
            if self.youtubePlayer.currentVideo?.videoId == self.video.videoId {
                self.youtubePlayer.inlineVideoOnScreen = false
            }
            self.viewModel.stopLiveChat()
        }
    }

    // MARK: - Ambient Style Picker

    /// Toolbar control to switch ambient styles live on the watch page.
    /// Binds to the same `SettingsManager` value as the Settings → YouTube
    /// tab, so there is a single source of truth.
    @ToolbarContentBuilder private var ambientStylePicker: some ToolbarContent {
        let isAmbientActive = self.settings.resolvedAmbientStyle != .off
        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("Ambient", selection: self.$settings.ambientBackdropStyle) {
                    ForEach(AmbientBackdropStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "paintpalette")
                    .foregroundStyle(isAmbientActive ? Self.brandAccent : .primary)
            }
            .tint(isAmbientActive ? Self.brandAccent : .primary)
            .help(String(localized: "Ambient backdrop style"))
        }
    }

    // MARK: - Responsive Layout Columns

    private static let maxVideoStageWidth: CGFloat = 1120

    /// Primary column below the video (metadata, description, summary, lyrics, chapters).
    private var primaryBelowVideoColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.metadataSection

            if let description = self.descriptionText {
                self.descriptionSection(description)
            }

            if self.showsSummary, !self.isLiveStream {
                Divider()
                self.summarySection
            }

            if self.youtubePlayer.showsLyrics, !self.isLiveStream {
                Divider()
                self.lyricsSection
            }

            if !self.viewModel.data.chapters.isEmpty {
                Divider()
                WatchChaptersSection(
                    chapters: self.viewModel.data.chapters,
                    videoId: self.video.videoId,
                    onSeek: self.seekToChapter
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trailing macOS inspector hosting Suggested videos and Comments / Live Chat.
    private var watchInspectorContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: self.$inspectorTab) {
                Text(String(localized: "Suggested"))
                    .tag(WatchInspectorTab.suggested)
                Text(self.viewModel.hasLiveChat ? String(localized: "Live Chat") : String(localized: "Comments"))
                    .tag(WatchInspectorTab.comments)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Switch between comments and suggested videos"))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            switch self.inspectorTab {
            case .suggested:
                ScrollView {
                    self.relatedColumn
                        .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .comments:
                if self.viewModel.hasLiveChat {
                    self.liveChatSection(height: nil)
                        .padding(16)
                } else {
                    ScrollView {
                        self.commentsSection
                            .padding(16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Video Surface

    /// Whether this view currently presents the live playback surface.
    private var presentsLiveSurface: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .inline
    }

    /// Whether this view's video is currently playing in the floating window.
    private var playsInFloatingWindow: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
            && self.youtubePlayer.surfaceLocation == .floating
    }

    private var videoSurface: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay {
                if self.presentsLiveSurface {
                    // Clean video surface. Controls live either in the docked bar or,
                    // when "controls on video" is enabled, overlaid on the video here
                    // (reusing the exact same YouTubePlayerBar in `.videoOverlay` mode).
                    YouTubeWatchSurfaceView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            VideoHoverControlsOverlay()
                        }
                        // Loading state: the WebView surface is black until the stream
                        // is ready, so show a spinner over it instead of a blank frame.
                        // For a members-only video the user can't play, no stream ever
                        // arrives — show YouTube's real gate notice instead of spinning.
                        .overlay {
                            if let gate = self.viewModel.membersGate {
                                self.membersGateCard(gate)
                                    .transition(.opacity)
                            } else if self.youtubePlayer.isPlaybackLoading {
                                ZStack {
                                    Rectangle().fill(.black)
                                    ProgressView()
                                        .controlSize(.large)
                                        .tint(.white)
                                }
                                .transition(.opacity)
                            }
                        }
                        .animation(.easeInOut(duration: 0.25), value: self.youtubePlayer.isPlaybackLoading)
                        .animation(.easeInOut(duration: 0.25), value: self.viewModel.membersGate == nil)
                        // YouTube-style "up next" countdown card when a finished video is
                        // about to autoplay the next one.
                        .overlay {
                            YouTubeAutoplayCountdownOverlay()
                        }
                        .animation(.easeInOut(duration: 0.25), value: self.youtubePlayer.autoplayPendingVideo == nil)
                        // "Ad" badge: a server-side (SSAI) ad can still slip past the
                        // blocker; label it so it's clear this isn't the content.
                        .overlay(alignment: .topLeading) {
                            if self.youtubePlayer.isShowingAd {
                                Text("Ad", comment: "Badge shown while a YouTube ad is playing")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.yellow, in: .rect(cornerRadius: 3))
                                    .padding(10)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: self.youtubePlayer.isShowingAd)
                        .overlay(alignment: .topTrailing) {
                            SponsorBlockSkipNoticeOverlay()
                                .padding(16)
                        }
                        // When the video scrolls out of the watch page, bring the docked
                        // bar back so playback stays controllable.
                        .onAppear { self.youtubePlayer.inlineVideoOnScreen = true }
                        .onScrollVisibilityChange(threshold: 0.35) { visible in
                            self.youtubePlayer.inlineVideoOnScreen = visible
                        }
                } else if self.playsInFloatingWindow {
                    // Native PiP-style placeholder while the video plays in the
                    // pop-out window.
                    VStack(spacing: 12) {
                        Image(systemName: "pip.exit")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("This video is playing in the pop-out player.", comment: "Watch view placeholder while popped out")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            self.youtubePlayer.dockInline()
                            HapticService.toggle()
                        } label: {
                            Text("Move Video Here", comment: "Button that docks the popped-out video back inline")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchMoveHere)
                    }
                } else {
                    Button {
                        self.startOrAdoptPlayback()
                    } label: {
                        CachedAsyncImage(
                            url: self.video.thumbnailURL,
                            targetSize: CGSize(width: 1280, height: 720)
                        ) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Rectangle().fill(.black)
                        }
                        .overlay {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 8)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Play video"))
                }
            }
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.watchSurface)
    }

    /// Starts playback of this view's video, or adopts the surface if this
    /// video is already playing (e.g. docking back from the floating window).
    func startOrAdoptPlayback(startAt: Double? = nil) {
        if self.youtubePlayer.currentVideo?.videoId == self.video.videoId {
            if self.youtubePlayer.surfaceLocation == .floating {
                self.youtubePlayer.dockInline()
            }
        } else {
            self.youtubePlayer.play(
                video: self.video,
                usesCookieFreeDataStore: self.authService.shouldUseCookieFreePlaybackDataStore,
                startAt: startAt
            )
        }
        self.youtubePlayer.setUpNext(self.upNextQueue)
        self.youtubePlayer.setChapters(self.viewModel.data.chapters)
        self.youtubePlayer.setHeatmap(self.viewModel.data.heatmap)
        self.youtubePlayer.activeInlineVideoId = self.video.videoId
    }

    // MARK: - Metadata

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.resolvedTitle)
                    .font(.title2.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(0)

                if self.settings.dearrowEnabled {
                    HStack(spacing: 4) {
                        if self.hasDearrow {
                            Button {
                                self.youtubePlayer.showsDearrowOriginal.toggle()
                            } label: {
                                Image(systemName: self.youtubePlayer.showsDearrowOriginal
                                    ? "arrow.uturn.backward.circle.fill" : "arrow.triangle.swap")
                                    .font(.system(size: 13))
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

                        Button {
                            let origTitle = self.viewModel.data.videoTitle ?? self.video.title
                            self.openWindow(
                                id: DearrowTitlesWindow.windowID,
                                value: DearrowTitlesWindowContext(
                                    videoId: self.video.videoId,
                                    originalTitle: origTitle.isEmpty ? nil : origTitle
                                )
                            )
                        } label: {
                            Image(systemName: "target")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(self.hasDearrow ? SponsorSegment.brandColor : .secondary)
                                .frame(width: 24, height: 24)
                                .compatGlass(interactive: true, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "DeArrow Titles & Voting"))
                        .accessibilityLabel(String(localized: "DeArrow Titles & Voting"))
                    }
                    .fixedSize(horizontal: true, vertical: true)
                    .layoutPriority(1)
                }
            }

            // Views · published (left) + like/dislike (right) — same row
            let meta = [
                self.viewModel.data.viewCountText ?? self.video.viewCountText,
                self.viewModel.data.publishedText ?? self.video.publishedText,
            ].compactMap(\.self)
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Channel on the left, engagement actions on the right (YouTube-style
            // two sides). Drops onto a wrapped line when the column is too narrow
            // so buttons and text NEVER clip or overflow!
            if !self.viewModel.collaborators.isEmpty {
                self.collaboratorsRow(self.viewModel.collaborators)
                FlowLayout(spacing: 8, lineSpacing: 8) { self.engagementButtons }
            } else if let channel = self.viewModel.data.channel {
                ViewThatFits(in: .horizontal) {
                    // Wide: 1 row
                    HStack(alignment: .center, spacing: 12) {
                        self.channelInfoLink(channel)
                        self.channelActionButtons
                        Spacer(minLength: 16)
                        HStack(spacing: 8) { self.engagementButtons }
                    }

                    // Narrow: 2 rows
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 12) {
                            self.channelInfoLink(channel)
                            self.channelActionButtons
                        }
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            self.engagementButtons
                        }
                    }
                }
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) { self.engagementButtons }
            }

            // KasetPlus tools (AI Summary).
            if !self.isLiveStream, self.aiSummaryAvailable {
                FlowLayout(spacing: 8, lineSpacing: 8) { self.toolsButtons }
            }
        }
    }

    // MARK: Channel & action button groups

    @ViewBuilder private var engagementButtons: some View {
        if self.hasPersonalAccount {
            self.likeDislikeButtons
            self.saveButton
        }
        self.shareButton
        self.downloadButton
    }

    @ViewBuilder private var channelActionButtons: some View {
        if self.hasPersonalAccount {
            self.subscribeButton
            self.membershipButton
            self.notificationBellButton
        }
    }

    private func channelInfoLink(_ channel: YouTubeChannel) -> some View {
        NavigationLink(value: YouTubeRoute.channel(channelId: channel.channelId)) {
            HStack(spacing: 10) {
                CachedAsyncImage(
                    url: channel.thumbnailURL,
                    targetSize: CGSize(width: 36, height: 36)
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle().fill(.quaternary)
                }
                .frame(width: 36, height: 36)
                .clipShape(.circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let subscriberCountText = channel.subscriberCountText {
                        Text(subscriberCountText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// KasetPlus-only tools: on-device AI summary.
    @ViewBuilder private var toolsButtons: some View {
        if !self.isLiveStream, self.aiSummaryAvailable {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.showsSummary.toggle()
                }
                if self.showsSummary, self.summaryCoordinator.tldr == nil, !self.summaryCoordinator.isLoading {
                    self.generateSummary()
                }
            } label: {
                self.togglePillLabel(
                    systemImage: "sparkles",
                    label: Text("Summary", comment: "Toggle AI video summary in YouTube watch view"),
                    isActive: self.showsSummary
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func togglePillLabel(systemImage: String, label: Text, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? Self.brandAccent : .secondary)
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .padding(.horizontal, 13)
        .frame(height: 34)
        .compatGlass(interactive: true, in: Capsule())
    }

    private var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(self.video.videoId)")
    }

    /// Native macOS share sheet for the video link.
    @ViewBuilder private var shareButton: some View {
        if let url = self.watchURL {
            ShareLink(item: url) {
                self.actionPillLabel("square.and.arrow.up", Text("Share", comment: "Share the video"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// Direct Download pill — opens the app's download sheet (replaced the
    /// overflow "…" menu, which only held Download + Copy link).
    private var downloadButton: some View {
        self.actionPill("arrow.down.circle", Text("Download", comment: "Download the video")) {
            self.showsDownloadSheet = true
        }
    }

    /// "Save" — opens the add-to-playlist popover (Watch Later, the user's
    /// playlists, and creating a new one). Mirrors YouTube's web Save button.
    /// A pill action button whose glass capsule shows icon + label when there's
    /// room, and collapses to icon-only when there isn't — it never truncates
    /// the label.
    private func actionPill(_ systemImage: String, _ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            self.actionPillLabel(systemImage, label)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func actionPillLabel(_ systemImage: String, _ label: Text) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                label
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 13)
            .frame(height: 34)

            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 36, height: 34)
        }
        .compatGlass(interactive: true, in: Capsule())
    }

    private var saveButton: some View {
        self.actionPill("bookmark", Text("Save", comment: "Save video to a playlist")) {
            self.showsSavePopover = true
        }
        .popover(isPresented: self.$showsSavePopover, arrowEdge: .bottom) {
            YouTubeSaveToPlaylistView(videoId: self.video.videoId, client: self.viewModel.client)
        }
    }

    /// Like / dislike as a single segmented pill (thumb-up + count · divider ·
    /// thumb-down + count), matching YouTube's joined control.
    private var likeDislikeButtons: some View {
        HStack(spacing: 0) {
            Button {
                Task { await self.youtubePlayer.toggleLike() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.youtubePlayer.currentRating == .like
                        ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.system(size: 13))
                    if let likes = self.youtubePlayer.rydLikes {
                        Text(YouTubePlayerService.formatCount(likes))
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(self.youtubePlayer.currentRating == .like ? Self.brandAccent : .secondary)
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            Button {
                Task { await self.youtubePlayer.toggleDislike() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: self.youtubePlayer.currentRating == .dislike
                        ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.system(size: 13))
                    if let dislikes = self.youtubePlayer.rydDislikes {
                        Text(YouTubePlayerService.formatCount(dislikes))
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(self.youtubePlayer.currentRating == .dislike ? Self.brandAccent : .secondary)
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 34)
        .fixedSize()
        .compatGlass(interactive: true, in: Capsule())
    }
}

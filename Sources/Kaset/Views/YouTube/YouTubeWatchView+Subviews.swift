import AppKit
import SwiftUI

// MARK: - WatchAmbientBackground

/// Hosts the ambient backdrop and owns every playback-progress read it needs.
///
/// Deliberately a separate child view: with `@Observable` tracking, the view
/// whose BODY reads `progress`/`duration` is the one invalidated by the 1 Hz
/// bridge updates. Keeping those reads out of `YouTubeWatchView.body` means
/// the watch page (metadata, comments, related) no longer re-evaluates every
/// second during playback — only this tiny host does.
struct WatchAmbientBackground: View {
    let video: YouTubeVideo

    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var settings = SettingsManager.shared

    var body: some View {
        AmbientVideoBackdrop(
            videoId: self.video.videoId,
            thumbnailURL: self.video.thumbnailURL,
            style: self.settings.resolvedAmbientStyle,
            liveFraction: self.liveFraction,
            storyboardSpec: self.storyboardSpec
        )
        .ignoresSafeArea()
    }

    private var isCurrentVideo: Bool {
        self.youtubePlayer.currentVideo?.videoId == self.video.videoId
    }

    /// 0…1 playback position, only while THIS view's video is the one playing,
    /// for the `.live` storyboard color. `nil` otherwise (guards NaN when
    /// duration is still 0 at cold load).
    private var liveFraction: Double? {
        guard self.isCurrentVideo, self.youtubePlayer.duration > 0 else { return nil }
        return min(max(self.youtubePlayer.progress / self.youtubePlayer.duration, 0), 1)
    }

    /// Storyboard spec for the fine-grained `.live` color, but only while THIS
    /// view's video is the one playing — so a previous video's sheets never
    /// tint a newly-opened watch page.
    private var storyboardSpec: String? {
        guard self.isCurrentVideo else { return nil }
        return self.youtubePlayer.storyboardSpec
    }
}

// MARK: - WatchAskFloatingOverlayHost

/// Hosts the floating Ask overlay and owns the 1 Hz `progress` read so playback
/// ticks invalidate only the overlay instead of the entire watch page.
struct WatchAskFloatingOverlayHost: View {
    let videoId: String
    let viewModel: YouTubeAskViewModel

    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        YouTubeAskFloatingOverlay(
            viewModel: self.viewModel,
            playerOffsetMilliseconds: self.playerOffsetMilliseconds
        )
    }

    private var playerOffsetMilliseconds: Int64 {
        guard self.youtubePlayer.currentVideo?.videoId == self.videoId else {
            return 0
        }
        return YouTubeAskPlayerOffset.milliseconds(for: self.youtubePlayer.progress)
    }
}

// MARK: - WatchChaptersSection

/// The chapters rail, extracted so the active-chapter highlight's 1 Hz
/// `progress` reads invalidate only this section — not the whole watch page
/// (see `WatchAmbientBackground` for the observation-scoping rationale).
struct WatchChaptersSection: View {
    let chapters: [YouTubeChapter]
    let videoId: String
    let onSeek: (YouTubeChapter) -> Void

    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters", comment: "Video chapters section header")
                .font(.title3.bold())

            CarouselShelf(
                accessibilityLabel: String(localized: "Video chapters"),
                pageFraction: 0.82,
                showsControls: true,
                controlVerticalAlignment: .center,
                contentInset: 0
            ) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(self.chapters) { chapter in
                        Button {
                            self.onSeek(chapter)
                        } label: {
                            ChapterCard(chapter: chapter, isActive: self.isActiveChapter(chapter))
                        }
                        .buttonStyle(.interactiveRow)
                        .accessibilityLabel(
                            String(localized: "Jump to chapter: \(chapter.title)")
                        )
                        .disabled(!self.canSeekToChapter(chapter))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.chaptersSection)
    }

    private func canSeekToChapter(_ chapter: YouTubeChapter) -> Bool {
        if let chapterVideoId = chapter.videoId, chapterVideoId != self.videoId {
            return false
        }
        guard self.youtubePlayer.currentVideo?.videoId == self.videoId else {
            return true
        }
        return self.youtubePlayer.duration > 0
            && !self.youtubePlayer.isPlaybackLoading
            && !self.youtubePlayer.isShowingAd
    }

    private func isActiveChapter(_ chapter: YouTubeChapter) -> Bool {
        guard self.youtubePlayer.currentVideo?.videoId == self.videoId else { return false }
        let currentTime = self.youtubePlayer.progress
        guard currentTime >= chapter.startTime else { return false }
        if let endTime = chapter.endTime {
            return currentTime < endTime
        }
        guard let index = self.chapters.firstIndex(where: { $0.id == chapter.id }) else {
            return false
        }
        let nextIndex = self.chapters.index(after: index)
        guard nextIndex < self.chapters.endIndex else { return true }
        return currentTime < self.chapters[nextIndex].startTime
    }
}

// MARK: - ChapterCard

struct ChapterCard: View {
    let chapter: YouTubeChapter
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            self.thumbnail
                .frame(width: 160, height: 90)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(self.chapter.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(self.chapter.timeText ?? Self.formatTime(self.chapter.startTime))
                    .font(.caption)
                    .foregroundStyle(self.isActive ? YouTubeWatchView.brandAccent : .secondary)
            }
        }
        .padding(8)
        .frame(width: 176, alignment: .leading)
        .background(self.isActive ? YouTubeWatchView.brandAccent.opacity(0.14) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 10))
    }

    private var thumbnail: some View {
        CachedAsyncImage(
            url: self.chapter.thumbnailURL,
            targetSize: CGSize(width: 192, height: 108)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "text.append")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - RelatedVideoRow

/// Compact related-rail row sized for the right column.
struct RelatedVideoRow: View, Equatable {
    let video: YouTubeVideo
    @State private var dearrowCache = DearrowCache.shared
    @State private var settings = SettingsManager.shared

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.video.id == rhs.video.id
            && lhs.video.watchedPercent == rhs.video.watchedPercent
    }

    private var displayTitle: String {
        guard self.settings.dearrowEnabled else { return self.video.title }
        return self.dearrowCache.dearrowTitle(for: self.video.videoId) ?? self.video.title
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VideoThumbnailView(video: self.video)
                .frame(width: 140)

            VStack(alignment: .leading, spacing: 3) {
                Text(self.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let channelName = self.video.channelName {
                    Text(channelName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let viewCountText = self.video.viewCountText {
                    Text(viewCountText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovered in
            if isHovered {
                DirectVideoStreamResolver.shared.prefetchStreamURL(videoId: self.video.videoId)
            }
        }
        .task(id: "\(self.video.videoId)-\(self.settings.dearrowEnabled)") {
            guard self.settings.dearrowEnabled else { return }
            self.dearrowCache.registerOriginalTitle(self.video.title, for: self.video.videoId)
            self.dearrowCache.fetchOneIfNeeded(videoId: self.video.videoId)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - AccessibilityID Additions

extension AccessibilityID.YouTubeContent {
    static let watchSurface = "youtubeContent.watchSurface"
    static let chaptersSection = "youtubeContent.chaptersSection"
    static let commentsSection = "youtubeContent.commentsSection"
    static let commentField = "youtubeContent.commentField"
    static let commentPostButton = "youtubeContent.commentPostButton"
    static let subscribeButton = "youtubeContent.subscribeButton"
    static let watchMoveHere = "youtubeContent.watchMoveHere"
}

// MARK: - CollaboratorAvatarStack

/// Overlapping avatar cluster for a collaboration upload's owner row, matching
/// YouTube's stacked-avatar look.
struct CollaboratorAvatarStack: View {
    let urls: [URL]

    var body: some View {
        HStack(spacing: -10) {
            ForEach(Array(self.urls.prefix(3).enumerated()), id: \.offset) { _, url in
                CachedAsyncImage(
                    url: url,
                    targetSize: CGSize(width: 36, height: 36)
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle().fill(.quaternary)
                }
                .frame(width: 32, height: 32)
                .clipShape(.circle)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
        }
    }
}

// MARK: - CollaboratorsPopover

/// The "Collaborators" picker for a multi-channel upload: each credited channel
/// with its own Subscribe button and notification "bell".
struct CollaboratorsPopover: View {
    let collaborators: [VideoCollaborator]
    let viewModel: YouTubeWatchViewModel
    let showsControls: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Collaborators", comment: "Header for the multi-channel collaboration picker")
                .font(.headline)

            ForEach(self.collaborators) { collaborator in
                CollaboratorRow(
                    collaborator: collaborator,
                    viewModel: self.viewModel,
                    showsControls: self.showsControls
                )
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - CollaboratorRow

/// A single collaborator inside the picker: avatar, name + verified badge,
/// handle · subscribers, and a Subscribe/bell control mirroring the watch page's
/// single-channel one.
struct CollaboratorRow: View {
    @MainActor static var brandAccent: Color {
        SettingsManager.shared.accentColor
    }

    let collaborator: VideoCollaborator
    let viewModel: YouTubeWatchViewModel
    let showsControls: Bool

    private var isSubscribed: Bool {
        self.viewModel.isSubscribed(toCollaborator: self.collaborator.channelId)
    }

    private var preference: ChannelNotificationPreference? {
        self.viewModel.collaboratorNotification[self.collaborator.channelId]
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(
                url: self.collaborator.avatarURL,
                targetSize: CGSize(width: 40, height: 40)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 40, height: 40)
            .clipShape(.circle)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(self.collaborator.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if self.collaborator.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = self.collaborator.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if self.showsControls {
                self.control
            }
        }
    }

    @ViewBuilder private var control: some View {
        if self.isSubscribed, let preference {
            self.bellMenu(preference)
        } else {
            Button {
                Task { await self.viewModel.toggleSubscribed(collaborator: self.collaborator) }
            } label: {
                Text(self.isSubscribed
                    ? String(localized: "Subscribed")
                    : String(localized: "Subscribe"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(self.isSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .compatGlass(
                        interactive: true,
                        tint: self.isSubscribed ? nil : Self.brandAccent,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func bellMenu(_ preference: ChannelNotificationPreference) -> some View {
        Menu {
            Picker(String(localized: "Notifications"), selection: self.selection(preference)) {
                ForEach(preference.options) { option in
                    Label(option.label, systemImage: option.level.symbolName).tag(option.id)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button(role: .destructive) {
                Task { await self.viewModel.toggleSubscribed(collaborator: self.collaborator) }
            } label: {
                Label(preference.unsubscribeLabel, systemImage: "person.fill.xmark")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: preference.currentLevel.symbolName)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .compatGlass(interactive: true, tint: nil, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Notification settings"))
    }

    private func selection(_ preference: ChannelNotificationPreference) -> Binding<String> {
        Binding(
            get: { preference.current?.id ?? "" },
            set: { newID in
                guard let option = preference.options.first(where: { $0.id == newID }) else { return }
                Task {
                    await self.viewModel.setNotificationPreference(
                        option, forCollaborator: self.collaborator.channelId
                    )
                }
            }
        )
    }
}

// MARK: - FlowLayout

/// Left-to-right layout that wraps its subviews onto new lines when they don't
/// fit the available width — used so the watch action buttons flow onto
/// multiple lines instead of cramming into one row.
/// ponytail: leading-aligned chips only; that's all the action bar needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + self.spacing + size.width > maxWidth {
                totalHeight += rowHeight + self.lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? self.spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, (x - bounds.minX) + size.width > bounds.width {
                x = bounds.minX
                y += rowHeight + self.lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + self.spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - VideoHoverControlsOverlay

/// Isolated hover-reveal overlay for `YouTubePlayerBar(mode: .videoOverlay)` so
/// pointer movement over the video never re-evaluates `YouTubeWatchView` or its inspector.
struct VideoHoverControlsOverlay: View {
    @Environment(YouTubePlayerService.self) private var youtubePlayer
    @State private var settings = SettingsManager.shared
    @State private var overlayControlsVisible = false
    @State private var overlayHideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .contentShape(Rectangle())
            if self.settings.controlsOnVideoEnabled, self.overlayControlsVisible {
                YouTubePlayerBar(mode: .videoOverlay)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover { phase in
            guard self.settings.controlsOnVideoEnabled else { return }
            switch phase {
            case .active:
                self.revealOverlayControls()
            case .ended:
                guard !self.youtubePlayer.isControlOverlayPinned else { return }
                self.overlayHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.overlayControlsVisible = false
                }
            }
        }
        .onDisappear {
            self.overlayHideTask?.cancel()
        }
    }

    private func revealOverlayControls() {
        if !self.overlayControlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) { self.overlayControlsVisible = true }
        }
        self.overlayHideTask?.cancel()
        self.overlayHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !self.youtubePlayer.isControlOverlayPinned else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.overlayControlsVisible = false }
        }
    }
}

// MARK: - WatchInspectorTab

enum WatchInspectorTab: String, CaseIterable {
    case suggested
    case comments
}

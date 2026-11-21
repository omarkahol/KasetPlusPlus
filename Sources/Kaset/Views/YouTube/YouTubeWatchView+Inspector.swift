import AppKit
import SwiftUI

extension YouTubeWatchView {
    // MARK: - Related Column

    /// The queue the transport/up-next follows: the endless Mix (each track
    /// carrying the mix context so auto-advance keeps the mix) when one is
    /// playing, otherwise the related rail.
    var upNextQueue: [YouTubeVideo] {
        let mix = self.viewModel.data.mixVideos
        guard !mix.isEmpty else { return self.viewModel.data.related }
        return mix.map { $0.inMix(self.viewModel.data.mixPlaylistId) }
    }

    var relatedColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                self.relatedHeader
                self.relatedSkeleton
            case let .error(error):
                self.relatedHeader
                ErrorView(
                    title: error.title,
                    message: error.message,
                    isRetryable: error.isRetryable
                ) {
                    Task {
                        await self.viewModel.load()
                    }
                }
            case .loaded, .loadingMore:
                if !self.viewModel.data.mixVideos.isEmpty {
                    self.mixBox
                }
                self.relatedHeader
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(self.viewModel.data.related) { related in
                        NavigationLink(value: YouTubeRoute.watch(related)) {
                            RelatedVideoRow(video: related)
                                .equatable()
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }
            }
        }
    }

    private var relatedHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Related", comment: "Related videos section header")
                .font(.title3.bold())
            Spacer(minLength: 12)
            self.autoplayToggle
        }
    }

    /// YouTube-style "Autoplay" switch: when on, a finished video advances to the
    /// next suggested video. Off by default. Lives in the related header, like
    /// YouTube's up-next autoplay toggle.
    private var autoplayToggle: some View {
        Toggle(isOn: Binding(
            get: { self.settings.youtubeAutoplayEnabled },
            set: { self.settings.youtubeAutoplayEnabled = $0 }
        )) {
            Text("Autoplay", comment: "Toggle: automatically play the next suggested video")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
    }

    private var relatedSkeleton: some View {
        ForEach(0 ..< 5, id: \.self) { _ in
            HStack(spacing: 12) {
                SkeletonView.rectangle(cornerRadius: 8)
                    .frame(width: 140, height: 79)
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonView.rectangle(cornerRadius: 4)
                        .frame(width: 160, height: 12)
                    SkeletonView.rectangle(cornerRadius: 4)
                        .frame(width: 100, height: 10)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Byline + "N/total" position under the queue title (either may be absent).
    private var mixBoxSubtitle: String? {
        let parts = [self.viewModel.data.mixDescription, self.viewModel.data.mixPosition]
            .compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Mix's own boxed panel (title + "Mixes are playlists YouTube makes for
    /// you" + the endless queue), mirroring YouTube's up-next Mix card: a
    /// fixed-height, internally-scrolling list with the current track
    /// highlighted. The list is whatever YouTube returned for this video, so it
    /// updates on its own as you move through the mix.
    private var mixBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.viewModel.data.mixTitle ?? String(localized: "Mix"))
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = self.mixBoxSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(self.viewModel.data.mixVideos) { mixVideo in
                        NavigationLink(
                            value: YouTubeRoute.watch(
                                mixVideo.inMix(self.viewModel.data.mixPlaylistId)
                            )
                        ) {
                            RelatedVideoRow(video: mixVideo)
                                .padding(6)
                                .background(
                                    mixVideo.videoId == self.video.videoId
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: .rect(cornerRadius: 8)
                                )
                        }
                        .buttonStyle(.interactiveRow)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 340)
        }
        .compatGlass(interactive: false, tint: nil, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Comments

    var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Comments", comment: "Comments section header")
                    .font(.title3.bold())

                Spacer()

                if self.viewModel.canSortComments {
                    Menu {
                        Button {
                            Task { await self.viewModel.setCommentSort(.top) }
                        } label: {
                            if self.viewModel.commentSort == .top {
                                Label("Top comments", systemImage: "checkmark")
                            } else {
                                Text("Top comments", comment: "Comment sort: most relevant")
                            }
                        }
                        Button {
                            Task { await self.viewModel.setCommentSort(.newest) }
                        } label: {
                            if self.viewModel.commentSort == .newest {
                                Label("Newest first", systemImage: "checkmark")
                            } else {
                                Text("Newest first", comment: "Comment sort: most recent")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 11))
                            Text("Sort by", comment: "Comment sort menu label")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            self.commentComposer

            // Comment search
            let filteredComments = self.commentSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty
                ? self.viewModel.comments
                : self.viewModel.comments.filter { comment in
                    comment.text.localizedCaseInsensitiveContains(self.commentSearchQuery)
                }

            if !self.viewModel.comments.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(
                        String(localized: "Search comments…"),
                        text: self.$commentSearchQuery
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    if !self.commentSearchQuery.isEmpty {
                        Button {
                            self.commentSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                }
            }

            if filteredComments.isEmpty, !self.commentSearchQuery.isEmpty {
                Text("No matching comments.", comment: "Empty comment search")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if self.viewModel.comments.isEmpty, !self.viewModel.isLoadingComments {
                Text("No comments yet.", comment: "Empty comments section")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(filteredComments) { comment in
                        CommentThread(comment: comment, viewModel: self.viewModel, allowsActions: self.hasPersonalAccount)
                    }
                }
            }

            if self.viewModel.isLoadingComments {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if self.viewModel.canLoadMoreComments {
                Button {
                    Task {
                        await self.viewModel.loadMoreComments()
                    }
                } label: {
                    Text("Show more comments", comment: "Load more comments button")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Self.brandAccent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentsSection)
    }

    // MARK: - Live Chat

    /// The live-chat panel. `height` is the TOTAL panel height — the header sits
    /// at the top, the composer at the bottom, and the message list fills the
    /// space between — so beside the video the whole card matches the video
    /// height exactly instead of overshooting it.
    func liveChatSection(height: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("Live chat", comment: "Live chat panel header")
                    .font(.title3.bold())
            }

            Group {
                if self.viewModel.liveChatMessages.isEmpty {
                    VStack(spacing: 8) {
                        if self.viewModel.liveChatLoaded {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text("No messages yet", comment: "Empty live chat state")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(self.viewModel.liveChatMessages) { message in
                                    LiveChatRow(message: message)
                                        .id(message.id)
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id("live-chat-bottom")
                            }
                            .padding(10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: self.viewModel.liveChatMessages.count) { _, _ in
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("live-chat-bottom", anchor: .bottom)
                            }
                        }
                        .onAppear {
                            proxy.scrollTo("live-chat-bottom", anchor: .bottom)
                        }
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.06))
            }

            if self.viewModel.canSendLiveChat {
                self.liveChatComposer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : height, alignment: .top)
    }

    private var liveChatComposer: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "Chat…", comment: "Live chat message field placeholder"),
                text: self.$liveChatDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1 ... 3)
            .onSubmit { self.sendLiveChatDraft() }

            Button(action: self.sendLiveChatDraft) {
                if self.viewModel.isSendingLiveChat {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Self.brandAccent)
                }
            }
            .buttonStyle(.plain)
            .disabled(
                self.viewModel.isSendingLiveChat
                    || self.liveChatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityLabel(String(localized: "Send chat message"))
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        }
    }

    private func sendLiveChatDraft() {
        let text = self.liveChatDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await self.viewModel.sendLiveChatMessage(text: text) {
                self.liveChatDraft = ""
            }
        }
    }

    private var commentComposer: some View {
        HStack(spacing: 10) {
            TextField(
                self.hasPersonalAccount && self.viewModel.canComment
                    ? String(localized: "Add a comment…")
                    : String(localized: "Sign in to comment"),
                text: self.$commentDraft
            )
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .disabled(!self.hasPersonalAccount || !self.viewModel.canComment)
            .onSubmit {
                self.submitComment()
            }
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentField)

            Button {
                self.submitComment()
            } label: {
                Group {
                    if self.viewModel.isPostingComment {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 30, height: 30)
                .foregroundStyle(self.hasCommentDraft ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .compatGlass(
                    interactive: true,
                    tint: self.hasCommentDraft && self.viewModel.canComment ? Self.brandAccent : nil,
                    in: Circle()
                )
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(
                !self.hasPersonalAccount
                    || !self.viewModel.canComment
                    || self.viewModel.isPostingComment
                    || self.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityLabel(String(localized: "Post comment"))
            .accessibilityIdentifier(AccessibilityID.YouTubeContent.commentPostButton)
        }
    }

    var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }

    /// Whether the composer holds postable text (drives the send accent).
    private var hasCommentDraft: Bool {
        !self.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitComment() {
        let draft = self.commentDraft
        Task {
            if await self.viewModel.postComment(text: draft) {
                self.commentDraft = ""
            }
        }
    }
}

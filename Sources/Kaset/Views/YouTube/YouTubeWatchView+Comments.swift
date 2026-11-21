import AppKit
import SwiftUI

// MARK: - CommentThread

/// A comment with its action row (like/dislike, replies) and, when
/// expanded, its indented reply thread.
struct CommentThread: View {
    let comment: YouTubeComment
    let viewModel: YouTubeWatchViewModel
    let allowsActions: Bool

    @State private var showsReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentRow(
                comment: self.comment,
                isLiked: self.viewModel.likedComments.contains(self.comment.id),
                isDisliked: self.viewModel.dislikedComments.contains(self.comment.id),
                onLike: {
                    Task {
                        await self.viewModel.likeComment(self.comment)
                    }
                },
                onDislike: {
                    Task {
                        await self.viewModel.dislikeComment(self.comment)
                    }
                },
                allowsActions: self.allowsActions
            )

            if self.comment.repliesContinuation != nil {
                Button {
                    self.showsReplies.toggle()
                    if self.showsReplies {
                        Task {
                            await self.viewModel.loadReplies(for: self.comment)
                        }
                    }
                } label: {
                    Label(
                        self.showsReplies
                            ? String(localized: "Hide replies")
                            : String(localized: "View replies"),
                        systemImage: self.showsReplies ? "chevron.up" : "chevron.down"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.leading, 38)
            }

            if self.showsReplies {
                if self.viewModel.loadingReplies.contains(self.comment.id) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 38)
                } else if let replies = self.viewModel.repliesByComment[self.comment.id] {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(replies) { reply in
                            CommentRow(
                                comment: reply,
                                isLiked: self.viewModel.likedComments.contains(reply.id),
                                isDisliked: self.viewModel.dislikedComments.contains(reply.id),
                                onLike: {
                                    Task {
                                        await self.viewModel.likeComment(reply)
                                    }
                                },
                                onDislike: {
                                    Task {
                                        await self.viewModel.dislikeComment(reply)
                                    }
                                },
                                allowsActions: self.allowsActions
                            )
                        }
                    }
                    .padding(.leading, 38)
                }
            }
        }
    }
}

// MARK: - Comment timestamp links

/// Parses a `M:SS`, `MM:SS`, or `H:MM:SS` timestamp token into total seconds.
func parseCommentTimestamp(_ token: String) -> Int? {
    let parts = token.split(separator: ":").map { Int($0) }
    guard !parts.contains(nil) else { return nil }
    let nums = parts.compactMap(\.self)
    switch nums.count {
    case 2: return nums[0] * 60 + nums[1]
    case 3: return nums[0] * 3600 + nums[1] * 60 + nums[2]
    default: return nil
    }
}

// MARK: - CommentTimestampRegex

enum CommentTimestampRegex {
    static let shared = try? NSRegularExpression(
        pattern: "(?<![\\d:])\\d{1,2}:\\d{2}(?::\\d{2})?(?![\\d:])"
    )
}

/// Builds an attributed comment where in-range timestamps (`M:SS` / `H:MM:SS`)
/// become `kasetseek://<seconds>` links, matching YouTube. Timestamps past the
/// video's duration stay plain text; when the duration is unknown (0) nothing
/// is linked. Character offsets (not UTF-16) are used so emoji don't shift the
/// link ranges.
func commentAttributedText(_ text: String, duration: TimeInterval) -> AttributedString {
    var result = AttributedString(text)
    guard duration > 0, let regex = CommentTimestampRegex.shared else { return result }
    let ns = text as NSString
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let stringRange = Range(match.range, in: text) else { continue }
        let token = String(text[stringRange])
        guard let seconds = parseCommentTimestamp(token), Double(seconds) <= duration else { continue }

        let startOffset = text.distance(from: text.startIndex, to: stringRange.lowerBound)
        let chars = result.characters
        guard let start = chars.index(chars.startIndex, offsetBy: startOffset, limitedBy: chars.endIndex),
              let end = chars.index(start, offsetBy: token.count, limitedBy: chars.endIndex)
        else { continue }
        result[start ..< end].link = URL(string: "kasetseek://\(seconds)")
        result[start ..< end].foregroundColor = .accentColor
    }
    return result
}

// MARK: - LiveChatRow

/// One live-chat message: small avatar, author (colored by role), and the
/// message text. Author role badges (owner/moderator/member/verified) match
/// YouTube's live chat.
struct LiveChatRow: View {
    let message: YouTubeLiveChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            self.avatar

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(self.message.author)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(self.authorColor)
                        .lineLimit(1)

                    if self.message.isOwner {
                        self.badge("crown.fill", .yellow)
                    }
                    if self.message.isModerator {
                        self.badge("wrench.adjustable.fill", .blue)
                    }
                    if self.message.isMember {
                        self.badge("star.fill", .green)
                    }
                    if self.message.isVerified {
                        self.badge("checkmark.seal.fill", .secondary)
                    }

                    if let timestampText = self.message.timestampText {
                        Text(timestampText)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Text(self.message.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var authorColor: Color {
        if self.message.isOwner {
            return .yellow
        }
        if self.message.isModerator {
            return .blue
        }
        if self.message.isMember {
            return .green
        }
        return .secondary
    }

    private var avatar: some View {
        CachedAsyncImage(
            url: self.message.authorAvatarURL,
            targetSize: CGSize(width: 24, height: 24)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(.quaternary)
        }
        .frame(width: 24, height: 24)
        .clipShape(.circle)
    }

    private func badge(_ systemName: String, _ color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

// MARK: - CommentRow

/// One comment: avatar, author + time, text, and working like/dislike.
/// The author (avatar/name) navigates to their channel.
struct CommentRow: View {
    let comment: YouTubeComment
    let isLiked: Bool
    let isDisliked: Bool
    let onLike: () -> Void
    let onDislike: () -> Void
    let allowsActions: Bool

    @Environment(YouTubePlayerService.self) private var youtubePlayer

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            self.authorLink {
                self.avatar
            }

            VStack(alignment: .leading, spacing: 3) {
                if self.comment.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    self.authorLink { self.authorNameLabel }

                    if self.comment.authorIsVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(Text("Verified", comment: "Verified channel badge"))
                    }

                    if let badgeURL = self.comment.memberBadgeThumbnailURL {
                        CachedAsyncImage(url: badgeURL, targetSize: CGSize(width: 16, height: 16)) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "star.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(width: 16, height: 16)
                        .help(Text(self.comment.memberBadgeTooltip ?? String(localized: "Member", comment: "Channel member badge")))
                    }

                    if let publishedText = self.comment.publishedText {
                        Text(publishedText)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(commentAttributedText(self.comment.text, duration: self.youtubePlayer.duration))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "kasetseek", let host = url.host, let seconds = Double(host)
                        else { return .systemAction }
                        self.youtubePlayer.seek(to: seconds)
                        return .handled
                    })

                HStack(spacing: 14) {
                    Button(action: self.onLike) {
                        HStack(spacing: 4) {
                            Image(systemName: self.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.system(size: 11))
                            if let likeCountText = self.comment.likeCountText, !likeCountText.isEmpty {
                                Text(likeCountText)
                                    .font(.system(size: 11))
                            }
                        }
                        .foregroundStyle(self.isLiked ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.allowsActions || self.comment.likeAction == nil)
                    .accessibilityLabel(String(localized: "Like comment"))

                    Button(action: self.onDislike) {
                        Image(systemName: self.isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 11))
                            .foregroundStyle(self.isDisliked ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!self.allowsActions || self.comment.dislikeAction == nil)
                    .accessibilityLabel(String(localized: "Dislike comment"))

                    if self.comment.isHeartedByCreator {
                        self.creatorHeart
                    }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The author's name. The video's creator is shown in a filled accent pill,
    /// matching YouTube's highlighting of the uploader's own comments.
    @ViewBuilder private var authorNameLabel: some View {
        if self.comment.authorIsChannelOwner {
            Text(self.comment.author)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary))
        } else {
            Text(self.comment.author)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    /// YouTube's "hearted by creator" marker: the creator's avatar with a small
    /// heart, shown on comments the uploader liked.
    private var creatorHeart: some View {
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(url: self.comment.creatorHeartAvatarURL, targetSize: CGSize(width: 16, height: 16)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(.quaternary)
            }
            .frame(width: 16, height: 16)
            .clipShape(.circle)

            Image(systemName: "heart.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
                .padding(1)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .offset(x: 3, y: 3)
        }
        .help(Text("Hearted by creator", comment: "Comment hearted by the video's creator"))
    }

    /// Wraps content in a channel link when the author's channel is known.
    @ViewBuilder
    private func authorLink(@ViewBuilder content: () -> some View) -> some View {
        if let channelId = self.comment.authorChannelId {
            NavigationLink(value: YouTubeRoute.channel(channelId: channelId)) {
                content()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private var avatar: some View {
        CachedAsyncImage(
            url: self.comment.authorAvatarURL,
            targetSize: CGSize(width: 28, height: 28)
        ) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
        }
        .frame(width: 28, height: 28)
        .clipShape(.circle)
    }
}

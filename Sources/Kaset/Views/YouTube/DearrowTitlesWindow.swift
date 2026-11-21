import SwiftUI

/// Window displaying all community-submitted DeArrow titles for a YouTube video,
/// allowing the user to inspect vote counts and upvote or downvote titles.
struct DearrowTitlesWindow: View {
    static let windowID = "dearrow-titles"

    let videoId: String

    @State private var cache = DearrowCache.shared
    @State private var titles: [DearrowTitle] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var votingTitleUUID: String?
    @State private var voteError: String?

    private var originalTitle: String {
        if let cached = self.cache.originalTitle(for: self.videoId), !cached.isEmpty {
            return cached
        }
        if let originalEntry = self.titles.first(where: { $0.original }) {
            return originalEntry.displayTitle
        }
        return self.videoId
    }

    private var activeDearrowTitle: String? {
        guard self.cache.hasDearrow(for: self.videoId) else { return nil }
        return self.cache.displayTitle(for: self.videoId, original: self.originalTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.headerView
            Divider()

            if let voteError {
                self.voteErrorBanner(message: voteError)
                Divider()
            }

            self.contentView
        }
        .frame(minWidth: 380, minHeight: 360)
        .task(id: self.videoId) {
            await self.loadTitles()
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Original YouTube Title"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(self.originalTitle)
                .font(.headline)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func voteErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                self.voteError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.1))
    }

    @ViewBuilder
    private var contentView: some View {
        if self.isLoading, self.titles.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text(String(localized: "Loading DeArrow titles..."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if let loadError, self.titles.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "Retry")) {
                    Task {
                        await self.loadTitles()
                    }
                }
                .compatGlassProminentButton()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if self.titles.isEmpty {
            ContentUnavailableView(
                String(localized: "No DeArrow Titles"),
                systemImage: "text.bubble",
                description: Text(String(localized: "No community titles have been submitted for this video yet."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(self.titles) { entry in
                        self.titleRow(entry)
                    }
                }
                .padding(16)
            }
        }
    }

    private func titleRow(_ entry: DearrowTitle) -> some View {
        let isActive = !entry.original && entry.displayTitle == self.activeDearrowTitle
        let currentVote = self.cache.userVote(for: self.videoId, titleUUID: entry.uuid)
        let isVoting = self.votingTitleUUID == entry.uuid

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayTitle)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text("\(entry.votes)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if isActive {
                        self.badge(String(localized: "Active"), color: SponsorSegment.brandColor)
                    }
                    if entry.original {
                        self.badge(String(localized: "Original"), color: .secondary)
                    }
                    if entry.locked {
                        self.badge(String(localized: "Locked"), color: .orange)
                    }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if isVoting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 52, height: 24)
                } else {
                    Button {
                        Task {
                            await self.submitVote(for: entry, downvote: false)
                        }
                    } label: {
                        Image(systemName: currentVote == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(currentVote == .up ? SponsorSegment.brandColor : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .compatGlass(interactive: true, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .disabled(self.votingTitleUUID != nil)
                    .help(String(localized: "Upvote title"))
                    .accessibilityLabel(String(localized: "Upvote title"))

                    Button {
                        Task {
                            await self.submitVote(for: entry, downvote: true)
                        }
                    } label: {
                        Image(systemName: currentVote == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(currentVote == .down ? .orange : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .compatGlass(interactive: true, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .disabled(self.votingTitleUUID != nil)
                    .help(String(localized: "Downvote title"))
                    .accessibilityLabel(String(localized: "Downvote title"))
                }
            }
            .fixedSize()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .compatGlass(in: .rect(cornerRadius: 10))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SponsorSegment.brandColor, lineWidth: 1.5)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: - Actions

    private func loadTitles() async {
        self.isLoading = true
        self.loadError = nil
        do {
            let fetched = try await self.cache.fetchAllTitles(videoId: self.videoId)
            self.titles = fetched
        } catch {
            self.loadError = error.localizedDescription
        }
        self.isLoading = false
    }

    private func submitVote(for entry: DearrowTitle, downvote: Bool) async {
        self.votingTitleUUID = entry.uuid
        self.voteError = nil
        do {
            try await self.cache.vote(videoId: self.videoId, title: entry, downvote: downvote)
            if let updated = self.cache.cachedAllTitles(for: self.videoId) {
                self.titles = updated
            }
        } catch {
            self.voteError = error.localizedDescription
        }
        self.votingTitleUUID = nil
    }
}

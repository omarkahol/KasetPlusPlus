import AppKit
import SwiftUI

extension YouTubeWatchView {
    // MARK: - Description

    /// The video's description text from the watch page, if any (non-empty).
    var descriptionText: String? {
        guard let text = self.viewModel.data.descriptionText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            return nil
        }
        return text
    }

    /// Collapsible description box: a 3-line preview by default (like YouTube),
    /// with a "Show more"/"Show less" toggle when there's more to see.
    func descriptionSection(_ text: String) -> some View {
        // ponytail: cheap "is it long enough to need a toggle" heuristic — a few
        // newlines or a paragraph's worth of text. Avoids measuring truncation.
        let isExpandable = text.count > 160 || text.filter { $0 == "\n" }.count >= 3

        return VStack(alignment: .leading, spacing: 8) {
            Text(Self.makeDescriptionAttributed(text))
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .tint(.accentColor)
                .textSelection(.enabled)
                .lineLimit(self.showsDescription ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Timestamps seek in-place; real links open in the browser.
                .environment(\.openURL, OpenURLAction { url in self.handleDescriptionLink(url) })

            if isExpandable {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { self.showsDescription.toggle() }
                } label: {
                    Text(self.showsDescription
                        ? String(localized: "Show less", comment: "Collapse the video description")
                        : String(localized: "Show more", comment: "Expand the video description"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))
        // Tapping the whole card expands it (only while collapsed — once open,
        // taps pass through to text selection / links; collapse via "Show less").
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            guard isExpandable, !self.showsDescription else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.showsDescription = true }
        }
    }

    /// Right-click menu on the video surface — the local subset of YouTube's own
    /// video context menu (copy links, embed, pop out). Loop / Stats-for-nerds
    /// need player-side plumbing the fork doesn't have yet, so they're omitted.
    @ViewBuilder var videoContextMenu: some View {
        let videoURL = "https://www.youtube.com/watch?v=\(self.video.videoId)"

        Button {
            self.copyToPasteboard(videoURL)
        } label: {
            Label("Copy video URL", systemImage: "link")
        }

        Button {
            self.copyToPasteboard("\(videoURL)&t=\(Int(self.youtubePlayer.progress))s")
        } label: {
            Label("Copy URL at current time", systemImage: "clock")
        }

        Button {
            self.copyToPasteboard(
                "<iframe width=\"560\" height=\"315\" src=\"https://www.youtube.com/embed/\(self.video.videoId)\" frameborder=\"0\" allowfullscreen></iframe>"
            )
        } label: {
            Label("Copy embed code", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        Button {
            DownloadManager.shared.downloadVideo(
                id: self.video.videoId,
                title: self.viewModel.data.videoTitle ?? self.video.title,
                artistsDisplay: self.viewModel.data.channel?.name ?? self.video.channelName ?? "",
                thumbnailURL: self.video.thumbnailURL
            )
        } label: {
            Label(String(localized: "Download Video"), systemImage: "arrow.down.circle")
        }

        if self.youtubePlayer.surfaceLocation == .inline {
            Divider()
            Button {
                self.youtubePlayer.popOutToWindow()
            } label: {
                Label("Mini player", systemImage: "pip.enter")
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func handleDescriptionLink(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == Self.seekLinkScheme, let seconds = Double(url.host() ?? "") {
            self.youtubePlayer.seek(to: seconds)
            return .handled
        }
        return .systemAction
    }

    private static let seekLinkScheme = "kaset-seek"

    private static let descriptionLinkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let descriptionTimestampRegex = try? NSRegularExpression(
        pattern: #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#
    )

    /// Builds an attributed description: real URLs become browser links, and
    /// `mm:ss` / `h:mm:ss` timestamps become `kaset-seek://<seconds>` links that
    /// seek the player. Segment-by-segment so NSString (UTF-16) ranges from the
    /// detectors line up with the produced `AttributedString`.
    private static func makeDescriptionAttributed(_ text: String) -> AttributedString {
        struct Hit { let range: NSRange
            let url: URL
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [Hit] = []

        if let detector = Self.descriptionLinkDetector {
            for match in detector.matches(in: text, range: full) {
                if let url = match.url {
                    hits.append(Hit(range: match.range, url: url))
                }
            }
        }

        if let regex = Self.descriptionTimestampRegex {
            for match in regex.matches(in: text, range: full) {
                // Don't turn a timestamp inside a matched URL into a seek link.
                guard !hits.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) else { continue }
                func group(_ index: Int) -> Int {
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? 0 : (Int(ns.substring(with: range)) ?? 0)
                }
                let seconds = group(1) * 3600 + group(2) * 60 + group(3)
                if let url = URL(string: "\(Self.seekLinkScheme)://\(seconds)") {
                    hits.append(Hit(range: match.range, url: url))
                }
            }
        }

        hits.sort { $0.range.location < $1.range.location }

        var result = AttributedString()
        var cursor = 0
        for hit in hits where hit.range.location >= cursor {
            if hit.range.location > cursor {
                result += AttributedString(ns.substring(with: NSRange(location: cursor, length: hit.range.location - cursor)))
            }
            var segment = AttributedString(ns.substring(with: hit.range))
            segment.link = hit.url
            result += segment
            cursor = hit.range.location + hit.range.length
        }
        if cursor < ns.length {
            result += AttributedString(ns.substring(from: cursor))
        }
        return result
    }

    // MARK: - AI Summary

    /// Whether on-device summarization is usable right now (macOS 26 + a ready model).
    var aiSummaryAvailable: Bool {
        self.summaryCoordinator.isAvailable
    }

    /// A live broadcast has no transcript to summarize and no lyrics, so both
    /// toggles (and their panels) are hidden. Combines the fetched metadata flag
    /// with the player's live state so it still holds when the video was opened
    /// without live metadata (e.g. from a notification).
    var isLiveStream: Bool {
        self.youtubePlayer.isLive || self.video.isLive
    }

    var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI Summary", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if self.summaryCoordinator.isLoading {
                    ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                }
            }

            if self.summaryCoordinator.isLoading {
                Text("Reading the transcript and summarizing on-device…", comment: "AI summary loading")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let error = self.summaryCoordinator.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let tldr = self.summaryCoordinator.tldr {
                Text(tldr)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if !self.summaryCoordinator.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(self.summaryCoordinator.keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(.secondary).frame(width: 5, height: 5).padding(.top, 6)
                                Text(point).font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                if let audience = self.summaryCoordinator.audience, !audience.isEmpty {
                    Text(audience)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            Text("Generated on-device from the video's captions. May be imperfect.", comment: "AI summary disclaimer")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.06)) }
    }

    func generateSummary() {
        let title = self.viewModel.data.videoTitle ?? self.video.title
        self.summaryCoordinator.summarize(videoId: self.video.videoId, title: title)
    }

    // MARK: - Lyrics Section

    var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Lyrics", systemImage: "music.quarternote.3")
                    .font(.headline)
                Spacer()
                if self.lyricsService.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
            }

            // Editable search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField(
                    String(localized: "Search artist - title..."),
                    text: self.$lyricsSearchQuery
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    self.lyricsExpandedID = nil
                    self.performLyricsSearch()
                }
                if !self.lyricsSearchQuery.isEmpty {
                    Button {
                        self.lyricsSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    self.lyricsExpandedID = nil
                    self.performLyricsSearch()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            }

            if self.lyricsService.results.isEmpty, !self.lyricsService.isLoading {
                Text("No lyrics found for this song.", comment: "Empty lyrics state")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(self.lyricsService.results.prefix(3), id: \.id) { track in
                    self.lyricsTrackRow(track)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.06))
        }
        .onAppear {
            if self.lyricsSearchQuery.isEmpty {
                self.lyricsSearchQuery = self.viewModel.data.videoTitle ?? self.video.title
            }
            self.performLyricsSearch()
        }
        .onChange(of: self.video.videoId) { _, _ in
            self.lyricsExpandedID = nil
            self.lyricsSearchQuery = self.viewModel.data.videoTitle ?? self.video.title
            self.performLyricsSearch()
        }
    }

    private func lyricsTrackRow(_ track: LRCLibModel) -> some View {
        let isExpanded = self.lyricsExpandedID == track.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.lyricsExpandedID = isExpanded ? nil : track.id
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "text.justify" : "music.note")
                        .font(.callout)
                        .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.trackName ?? track.artistName ?? String(localized: "Unknown"))
                            .font(.system(size: 12, weight: .semibold))
                        if let artist = track.artistName {
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isExpanded ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let lyrics = track.syncedLyrics ?? track.plainLyrics {
                ScrollView {
                    Text(Self.stripTimestamps(lyrics))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.04))
                }
                .padding(.top, 6)
            }
        }
    }

    private func performLyricsSearch() {
        self.lyricsService.search(query: self.lyricsSearchQuery)
    }

    private static func stripTimestamps(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\[\\d{2}:\\d{2}\\.\\d{2}\\]",
            with: "",
            options: .regularExpression
        )
    }

    var subscribeButton: some View {
        Button {
            Task {
                await self.viewModel.toggleSubscribed()
            }
        } label: {
            Text(
                self.viewModel.isSubscribed
                    ? String(localized: "Subscribed")
                    : String(localized: "Subscribe")
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(self.viewModel.isSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 16)
            // Same height as the avatar / name + subscriber-count block.
            .frame(height: 36)
            .compatGlass(
                interactive: true,
                tint: self.viewModel.isSubscribed ? nil : Self.brandAccent,
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.YouTubeContent.subscribeButton)
    }

    /// The channel to open a membership (Join / Abbonati) page for: the watch
    /// page's parsed owner, falling back to the source card's channel.
    private var membershipChannelId: String? {
        self.viewModel.data.channel?.channelId ?? self.video.channelId
    }

    /// "Join" (Abbonati) button shown next to Subscribe when the channel offers a
    /// paid membership. Paid flows aren't handled in-app — it opens YouTube.
    @ViewBuilder var membershipButton: some View {
        if self.viewModel.data.channelOffersMembership, let channelId = self.membershipChannelId {
            self.abbonatiButton(channelId: channelId)
        }
    }

    /// The Join / Abbonati capsule that opens the channel's YouTube membership
    /// page in the browser (no in-app payment flow). Reused by the members-only
    /// gate card so joining is one click from the blocked video.
    private func abbonatiButton(channelId: String) -> some View {
        Button {
            self.openMembership(channelId: channelId)
        } label: {
            Text("Join", comment: "Button to join a channel's paid membership (Abbonati)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .compatGlass(interactive: true, tint: Self.brandAccent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Opens the channel's YouTube membership page. Membership/payment is handled
    /// on YouTube, never in-app.
    private func openMembership(channelId: String) {
        guard let url = URL(string: "https://www.youtube.com/channel/\(channelId)/join") else { return }
        self.openURL(url)
    }

    /// Members-only gate: replaces the endless spinner for a members-only video
    /// the signed-in user can't play. Shows YouTube's own dynamic reason /
    /// subreason plus a Join (Abbonati) action.
    func membersGateCard(_ gate: YouTubePlayability) -> some View {
        ZStack {
            Rectangle().fill(.black)
            VStack(spacing: 12) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color(red: 0.18, green: 0.55, blue: 0.34))

                if let reason = gate.reason {
                    Text(reason)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }

                if let subreason = gate.subreason {
                    Text(subreason)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }

                if let channelId = self.membershipChannelId {
                    self.abbonatiButton(channelId: channelId)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 520)
        }
    }

    /// The subscription notification "bell": a menu to pick the notification
    /// level (labels + options come straight from YouTube) or unsubscribe. Shown
    /// only when subscribed and YouTube exposed the preference.
    @ViewBuilder var notificationBellButton: some View {
        if self.viewModel.isSubscribed, let preference = self.viewModel.notificationPreference {
            Menu {
                Picker(String(localized: "Notifications"), selection: self.notificationSelection) {
                    ForEach(preference.options) { option in
                        Label(option.label, systemImage: option.level.symbolName).tag(option.id)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button(role: .destructive) {
                    Task { await self.viewModel.toggleSubscribed() }
                } label: {
                    Label(preference.unsubscribeLabel, systemImage: "person.fill.xmark")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: preference.currentLevel.symbolName)
                        .font(.system(size: 13))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .compatGlass(interactive: true, tint: nil, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(String(localized: "Notification settings"))
        }
    }

    /// Binding driving the notification-level picker (applies the choice on change).
    private var notificationSelection: Binding<String> {
        Binding(
            get: { self.viewModel.notificationPreference?.current?.id ?? "" },
            set: { newID in
                guard let option = self.viewModel.notificationPreference?.options
                    .first(where: { $0.id == newID })
                else { return }
                Task { await self.viewModel.setNotificationPreference(option) }
            }
        )
    }

    // MARK: - Collaborators

    /// The owner row for a collaboration upload: a stacked avatar cluster and the
    /// credited channel names, tapping either the row or the trailing pill opens
    /// the "Collaborators" picker with a Subscribe + bell per channel.
    func collaboratorsRow(_ collaborators: [VideoCollaborator]) -> some View {
        let allSubscribed = collaborators.allSatisfy {
            self.viewModel.isSubscribed(toCollaborator: $0.channelId)
        }
        return HStack(spacing: 12) {
            Button {
                self.showsCollaborators = true
            } label: {
                HStack(spacing: 10) {
                    CollaboratorAvatarStack(urls: collaborators.compactMap(\.avatarURL))
                    self.collaboratorNames(collaborators)
                        .font(.system(size: 13))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if self.hasPersonalAccount {
                Button {
                    self.showsCollaborators = true
                } label: {
                    Text(allSubscribed
                        ? String(localized: "Subscribed")
                        : String(localized: "Subscribe"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(allSubscribed ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .compatGlass(
                            interactive: true,
                            tint: allSubscribed ? nil : Self.brandAccent,
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .popover(isPresented: self.$showsCollaborators, arrowEdge: .bottom) {
            CollaboratorsPopover(
                collaborators: collaborators,
                viewModel: self.viewModel,
                showsControls: self.hasPersonalAccount
            )
        }
    }

    /// The credited channel names joined the way YouTube shows them — "A and B",
    /// each followed by its verified badge.
    private func collaboratorNames(_ collaborators: [VideoCollaborator]) -> Text {
        var result = Text("")
        for (index, collaborator) in collaborators.enumerated() {
            if index > 0 {
                let separator = index == collaborators.count - 1
                    ? " \(String(localized: "and")) "
                    : ", "
                result = Text("\(result)\(Text(separator).foregroundStyle(.secondary))")
            }
            result = Text("\(result)\(Text(collaborator.name).fontWeight(.semibold))")
            if collaborator.isVerified {
                result = Text("\(result) \(Text(Image(systemName: "checkmark.seal.fill")).foregroundStyle(.secondary))")
            }
        }
        return result
    }

    // MARK: - Chapters

    /// Seek target chosen in `WatchChaptersSection` (which gates tappability
    /// on the player state, so no re-guard is needed here).
    func seekToChapter(_ chapter: YouTubeChapter) {
        if self.youtubePlayer.currentVideo?.videoId != self.video.videoId {
            self.startOrAdoptPlayback(startAt: chapter.startTime)
            return
        }
        self.youtubePlayer.seek(to: chapter.startTime)
    }
}

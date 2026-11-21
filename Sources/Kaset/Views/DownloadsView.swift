import SwiftUI

// MARK: - DownloadsScope

enum DownloadsScope: Sendable {
    case music
    case video
}

// MARK: - DownloadsView

/// Displays locally downloaded songs for 100% offline playback.
struct DownloadsView: View {
    var scope: DownloadsScope = .music
    @State private var downloadManager = DownloadManager.shared
    @Environment(PlayerService.self) private var playerService
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateAdded
    @State private var navigationPath = NavigationPath()
    @State private var playingVideoItem: DownloadedSong?

    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded
        case title
        case artist

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .dateAdded: String(localized: "Recently Downloaded")
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            }
        }
    }

    var body: some View {
        Group {
            if self.scope == .music {
                NavigationStack(path: self.$navigationPath) {
                    self.mainContent
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PlayerBar()
                        .playerBarMusicNavigation(path: self.$navigationPath)
                }
            } else {
                self.mainContent
            }
        }
        .sheet(item: self.$playingVideoItem) { item in
            DownloadedVideoPlayerSheet(
                title: item.title,
                fileURL: self.downloadManager.mediaFileURL(for: item)
            )
        }
    }

    private var mainContent: some View {
        Group {
            if self.scopedSongs.isEmpty {
                self.emptyStateView
            } else {
                self.contentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .localizedNavigationTitle("Downloads")
        .toolbar {
            if !self.scopedSongs.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Picker(String(localized: "Sort by"), selection: self.$sortOption) {
                            ForEach(SortOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .help(String(localized: "Sort options"))
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        NSWorkspace.shared.open(
                            self.scope == .video
                                ? self.downloadManager.videosDirectory
                                : self.downloadManager.downloadsDirectory
                        )
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help(String(localized: "Show in Finder"))
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: self.scope == .music ? "arrow.down.circle" : "video.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(String(localized: "No Downloads Yet"))
                .font(.title2.bold())

            Text(self.scope == .music
                ? String(localized: "Click the download button next to any song, album, or playlist to listen completely offline.")
                : String(localized: "Click the download button on any YouTube video to watch completely offline."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Content View

    private var contentView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                self.headerView
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)

                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "Filter downloads…"), text: self.$searchText)
                        .textFieldStyle(.plain)
                    if !self.searchText.isEmpty {
                        Button {
                            self.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                let songs = self.filteredSongs
                if songs.isEmpty {
                    Text(String(localized: "No matching downloads found"))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 32)
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, item in
                        self.downloadRow(item, index: index, allItems: songs)
                            .id(item.id)

                        if index < songs.count - 1 {
                            Divider()
                                .padding(.leading, 72)
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: self.scope == .music ? [.blue, .cyan] : [.red, .orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                Image(systemName: self.scope == .music ? "arrow.down.circle.fill" : "play.rectangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Downloads"))
                    .font(.largeTitle.bold())

                let count = self.scopedSongs.count
                let countText = self.scope == .music
                    ? String(localized: "\(count) songs • Available Offline")
                    : String(localized: "\(count) videos • Available Offline")
                Text(countText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if self.scope == .music {
                        Button {
                            self.playAll(shuffled: false)
                        } label: {
                            Label(String(localized: "Play All"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(self.filteredSongs.isEmpty)

                        Button {
                            self.playAll(shuffled: true)
                        } label: {
                            Label(String(localized: "Shuffle"), systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(self.filteredSongs.isEmpty)
                    } else {
                        Button {
                            if let first = self.filteredSongs.first {
                                self.playingVideoItem = first
                            }
                        } label: {
                            Label(String(localized: "Play All"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(self.filteredSongs.isEmpty)

                        Button {
                            if let random = self.filteredSongs.randomElement() {
                                self.playingVideoItem = random
                            }
                        } label: {
                            Label(String(localized: "Shuffle"), systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(self.filteredSongs.isEmpty)
                    }
                }
                .padding(.top, 4)
            }

            Spacer()
        }
    }

    // MARK: - Row

    private func downloadRow(_ item: DownloadedSong, index: Int, allItems: [DownloadedSong]) -> some View {
        let isCurrent = self.playerService.currentTrack?.videoId == item.videoId
        let song = item.toSong(baseDirectory: self.downloadManager.downloadsDirectory)

        return HoverObservingRow { isHovered in
            Button {
                self.playSong(at: index, in: allItems)
            } label: {
                HStack(spacing: 12) {
                    // Index or Now Playing Indicator
                    Group {
                        if isCurrent {
                            NowPlayingIndicator(isPlaying: self.playerService.isPlaying, size: 14)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 28, alignment: .trailing)

                    // Artwork
                    ZStack(alignment: .bottomTrailing) {
                        if let artworkURL = song.thumbnailURL {
                            CachedAsyncImage(url: artworkURL, targetSize: CGSize(width: 44, height: 44)) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 6))
                        } else {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 6))
                        }

                        if item.mediaType == .video {
                            Image(systemName: "video.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(.black.opacity(0.7), in: .rect(cornerRadius: 3))
                                .padding(2)
                        }
                    }

                    // Metadata
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            .lineLimit(1)

                        Text(item.artistsDisplay)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Like Button
                    LikeButton(song: song, isRowHovered: isHovered)

                    // Album / Playlist column
                    Text(item.albumTitle ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)

                    // Duration
                    Text(item.duration.map { self.formatDuration($0) } ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)

                    // Context Menu / Delete Button
                    Menu {
                        self.downloadMenuItems(for: item, song: song, index: index, allItems: allItems)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28, alignment: .trailing)
                    .opacity(isHovered ? 1 : 0)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            self.downloadMenuItems(for: item, song: song, index: index, allItems: allItems)
        }
    }

    @ViewBuilder
    private func downloadMenuItems(
        for item: DownloadedSong,
        song: Song,
        index: Int,
        allItems: [DownloadedSong]
    ) -> some View {
        Button(String(localized: "Play")) {
            self.playSong(at: index, in: allItems)
        }

        if item.mediaType == .audio {
            Button(String(localized: "Play Next")) {
                SongActionsHelper.addToQueueNext(song, playerService: self.playerService)
            }

            Button(String(localized: "Add to Queue")) {
                SongActionsHelper.addToQueueLast(song, playerService: self.playerService)
            }
        } else {
            Button(String(localized: "Open in Default App")) {
                let fileURL = self.downloadManager.mediaFileURL(for: item)
                NSWorkspace.shared.open(fileURL)
            }
        }

        Divider()

        Button(String(localized: "Show in Finder")) {
            let fileURL = self.downloadManager.mediaFileURL(for: item)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }

        Divider()

        Button(role: .destructive) {
            self.downloadManager.removeDownload(videoId: item.videoId)
        } label: {
            Label(String(localized: "Remove Download"), systemImage: "trash")
        }
    }

    // MARK: - Helpers

    private var scopedSongs: [DownloadedSong] {
        switch self.scope {
        case .music:
            self.downloadManager.downloadedSongs.filter { $0.mediaType == .audio }
        case .video:
            self.downloadManager.downloadedSongs.filter { $0.mediaType == .video }
        }
    }

    private var filteredSongs: [DownloadedSong] {
        var result = self.scopedSongs

        if !self.searchText.isEmpty {
            let query = self.searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(query)
                    || $0.artistsDisplay.lowercased().contains(query)
                    || ($0.albumTitle?.lowercased().contains(query) ?? false)
            }
        }

        switch self.sortOption {
        case .dateAdded:
            result.sort { $0.downloadDate > $1.downloadDate }
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            result.sort { $0.artistsDisplay.localizedCaseInsensitiveCompare($1.artistsDisplay) == .orderedAscending }
        }

        return result
    }

    private func playSong(at index: Int, in items: [DownloadedSong]) {
        let item = items[index]
        if item.mediaType == .video {
            self.playingVideoItem = item
            return
        }

        let audioItems = items.filter { $0.mediaType == .audio }
        let songs = audioItems.map { $0.toSong(baseDirectory: self.downloadManager.downloadsDirectory) }
        let targetIndex = audioItems.firstIndex(where: { $0.id == item.id }) ?? 0
        Task {
            await self.playerService.playQueue(songs, startingAt: targetIndex)
        }
    }

    private func playAll(shuffled: Bool) {
        if self.scope == .video {
            if shuffled {
                if let random = self.filteredSongs.randomElement() {
                    self.playingVideoItem = random
                }
            } else if let first = self.filteredSongs.first {
                self.playingVideoItem = first
            }
            return
        }

        let audioItems = self.filteredSongs.filter { $0.mediaType == .audio }
        var songs = audioItems.map { $0.toSong(baseDirectory: self.downloadManager.downloadsDirectory) }
        if shuffled {
            songs.shuffle()
        }
        Task {
            await self.playerService.playQueue(songs, startingAt: 0)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

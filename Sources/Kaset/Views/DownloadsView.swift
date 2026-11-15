// swiftlint:disable file_length
import SwiftUI

// MARK: - DownloadsView

/// Displays locally downloaded songs for 100% offline playback.
struct DownloadsView: View {
    @State private var downloadManager = DownloadManager.shared
    @Environment(PlayerService.self) private var playerService
    @State private var searchText = ""
    @State private var sortOption: SortOption = .dateAdded
    @State private var navigationPath = NavigationPath()

    enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded
        case title
        case artist

        var id: String { self.rawValue }

        var displayName: String {
            switch self {
            case .dateAdded: String(localized: "Recently Downloaded")
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            }
        }
    }

    var body: some View {
        NavigationStack(path: self.$navigationPath) {
            Group {
                if self.downloadManager.downloadedSongs.isEmpty {
                    self.emptyStateView
                } else {
                    self.contentView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .localizedNavigationTitle("Downloads")
            .toolbar {
                if !self.downloadManager.downloadedSongs.isEmpty {
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
                            NSWorkspace.shared.open(self.downloadManager.downloadsDirectory)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help(String(localized: "Show in Finder"))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar()
                .playerBarMusicNavigation(path: self.$navigationPath)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(String(localized: "No Downloads Yet"))
                .font(.title2.bold())

            Text(String(localized: "Click the download button next to any song, album, or playlist to listen completely offline."))
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
                    TextField(String(localized: "Filter downloaded songs…"), text: self.$searchText)
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
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Downloads"))
                    .font(.largeTitle.bold())

                let count = self.downloadManager.downloadedSongs.count
                Text(String(localized: "\(count) songs • Available Offline"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        self.playAll(shuffled: false)
                    } label: {
                        Label(String(localized: "Play All"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button {
                        self.playAll(shuffled: true)
                    } label: {
                        Label(String(localized: "Shuffle"), systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
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
                        Button(String(localized: "Play")) {
                            self.playSong(at: index, in: allItems)
                        }

                        Button(String(localized: "Play Next")) {
                            SongActionsHelper.addToQueueNext(song, playerService: self.playerService)
                        }

                        Button(String(localized: "Add to Queue")) {
                            SongActionsHelper.addToQueueLast(song, playerService: self.playerService)
                        }

                        Divider()

                        Button(String(localized: "Show in Finder")) {
                            let fileURL = item.fileURL(baseDirectory: self.downloadManager.downloadsDirectory)
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }

                        Divider()

                        Button(role: .destructive) {
                            self.downloadManager.removeDownload(videoId: item.videoId)
                        } label: {
                            Label(String(localized: "Remove Download"), systemImage: "trash")
                        }
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
            Button(String(localized: "Play")) {
                self.playSong(at: index, in: allItems)
            }

            Button(String(localized: "Play Next")) {
                SongActionsHelper.addToQueueNext(song, playerService: self.playerService)
            }

            Button(String(localized: "Add to Queue")) {
                SongActionsHelper.addToQueueLast(song, playerService: self.playerService)
            }

            Divider()

            Button(String(localized: "Show in Finder")) {
                let fileURL = item.fileURL(baseDirectory: self.downloadManager.downloadsDirectory)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }

            Divider()

            Button(role: .destructive) {
                self.downloadManager.removeDownload(videoId: item.videoId)
            } label: {
                Label(String(localized: "Remove Download"), systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private var filteredSongs: [DownloadedSong] {
        var result = self.downloadManager.downloadedSongs

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
        let songs = items.map { $0.toSong(baseDirectory: self.downloadManager.downloadsDirectory) }
        Task {
            await self.playerService.playQueue(songs, startingAt: index)
        }
    }

    private func playAll(shuffled: Bool) {
        var songs = self.filteredSongs.map { $0.toSong(baseDirectory: self.downloadManager.downloadsDirectory) }
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

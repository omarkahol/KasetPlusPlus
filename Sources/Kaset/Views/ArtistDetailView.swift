// swiftlint:disable file_length

import SwiftUI

/// Detail view for an artist showing their songs and albums.
struct ArtistDetailView: View {
    let artist: Artist
    var playerBarNavigationAction: PlayerBarNavigationAction = .disabled
    @State var viewModel: ArtistDetailViewModel
    @Environment(PlayerService.self) private var playerService
    @Environment(AuthService.self) private var authService
    @Environment(FavoritesManager.self) private var favoritesManager
    @Environment(SongLikeStatusManager.self) private var likeStatusManager

    init(
        artist: Artist,
        viewModel: ArtistDetailViewModel,
        playerBarNavigationAction: PlayerBarNavigationAction = .disabled
    ) {
        self.artist = artist
        self.playerBarNavigationAction = playerBarNavigationAction
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            switch self.viewModel.loadingState {
            case .idle, .loading:
                LoadingView(String(localized: "Loading artist..."))
            case .loaded, .loadingMore:
                if let detail = viewModel.artistDetail {
                    self.contentView(detail)
                } else {
                    ErrorView(title: String(localized: "Unable to load artist"), message: String(localized: "Artist not found")) {
                        Task { await self.viewModel.load() }
                    }
                }
            case let .error(error):
                ErrorView(error: error) {
                    Task { await self.viewModel.load() }
                }
            }
        }
        .accentBackground(from: self.viewModel.artistDetail?.thumbnailURL?.highQualityThumbnailURL)
        .navigationTitle(self.artist.name)
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .error = self.viewModel.loadingState {} else {
                PlayerBar()
                    .environment(\.playerBarNavigationAction, self.playerBarNavigationAction)
                    .environment(\.playerBarCurrentArtistID, self.artist.id)
            }
        }
        .task {
            if self.viewModel.loadingState == .idle {
                await self.viewModel.load()
            }
        }
        .refreshable {
            await self.viewModel.refresh()
        }
    }

    // MARK: - Views

    private func contentView(_ detail: ArtistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                self.headerView(detail)
                    .padding(.horizontal, DetailContentLayout.horizontalInset)

                Divider()
                    .padding(.horizontal, DetailContentLayout.horizontalInset)

                // Songs section (vertical list — inset like other non-shelf content)
                if !detail.songs.isEmpty {
                    self.songsSection()
                        .padding(.horizontal, DetailContentLayout.horizontalInset)
                }

                // Latest episodes (includes live radio streams). Episodes are
                // kept out of orderedSections because they use their own card
                // layout and route.
                if !detail.episodes.isEmpty {
                    self.episodesSection(detail.episodes)
                }

                if !detail.orderedSections.isEmpty {
                    ForEach(detail.orderedSections) { section in
                        switch section.content {
                        case let .albums(albums):
                            self.albumsSection(
                                albums,
                                title: section.title,
                                shelfKind: self.albumShelfKind(for: section.title)
                            )
                        case let .artists(artists):
                            self.artistsSection(artists, title: section.title)
                        case let .playlists(playlists):
                            self.playlistsSection(playlists, title: section.title)
                        }
                    }
                } else {
                    // Fallback for older/parser-test ArtistDetail values that do
                    // not populate orderedSections.
                    if !detail.albums.isEmpty {
                        self.albumsSection(detail.albums)
                    }

                    if !detail.singles.isEmpty {
                        self.singlesSection(detail.singles)
                    }

                    if !detail.playlistsByArtist.isEmpty {
                        self.playlistsByArtistSection(detail.playlistsByArtist)
                    }

                    if !detail.relatedArtists.isEmpty {
                        self.relatedArtistsSection(detail.relatedArtists)
                    }
                }

                // Podcast shows owned by this artist.
                if !detail.podcasts.isEmpty {
                    self.podcastsSection(detail.podcasts)
                }
            }
            .padding(.vertical, 24)
        }
        // The ScrollView stays edge-to-edge: non-scrolling content is inset via
        // padding above, while horizontal shelves pass `contentInset` so their
        // tracks reach the under-sidebar band and slide under the floating glass
        // on macOS 26. The accent backdrop (ignores safe area) refracts through.
        .topFade(style: .contentMask)
    }

    private func headerView(_ detail: ArtistDetail) -> some View {
        HStack(alignment: .top, spacing: 20) {
            // Thumbnail
            CachedAsyncImage(url: detail.thumbnailURL?.highQualityThumbnailURL, targetSize: CGSize(width: 180, height: 180)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 180, height: 180)
            .clipShape(.circle)

            // Info
            VStack(alignment: .leading, spacing: 8) {
                if let headerTypeLabel = self.headerTypeLabel(for: detail) {
                    Text(headerTypeLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }

                Text(detail.name)
                    .font(.title)
                    .fontWeight(.bold)

                if let monthlyAudience = detail.monthlyAudience {
                    Text(monthlyAudience)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer()

                HStack(spacing: 12) {
                    if detail.profileKind == .artist {
                        // Shuffle button - shuffles all artist's songs (fetches if needed)
                        Button {
                            let intent = self.playerService.beginMusicPlaybackIntent()
                            Task {
                                await self.viewModel.shuffleAllSongs(intent: intent, playerService: self.playerService)
                            }
                        } label: {
                            Label(String(localized: "Shuffle"), systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(detail.songs.isEmpty && !detail.hasMoreSongs)
                    }

                    // Mix button - plays personalized radio with mix of artists
                    // Only shown if mix data is available from the API
                    // Passing nil for startVideoId lets the API pick a random starting point on the server
                    // in addition to client-side shuffling applied when the mix tracks are played
                    if let mixPlaylistId = detail.mixPlaylistId {
                        Button {
                            self.viewModel.playMix(
                                playlistId: mixPlaylistId,
                                startVideoId: nil,
                                playerService: self.playerService
                            )
                        } label: {
                            Label(String(localized: "Mix"), systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    // Subscribe button
                    if detail.channelId != nil, self.hasPersonalAccount {
                        self.subscribeButton(detail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Returns the text for the subscribe button.
    private func subscribeButtonText(_ detail: ArtistDetail) -> String {
        let baseText = detail.isSubscribed
            ? (detail.subscribedButtonText ?? String(localized: "Subscribed"))
            : (detail.unsubscribedButtonText ?? String(localized: "Subscribe"))

        if let subscriberCount = detail.subscriberCount, !subscriberCount.isEmpty {
            return "\(baseText) \(subscriberCount)"
        }
        return baseText
    }

    private func headerTypeLabel(for detail: ArtistDetail) -> String? {
        switch detail.profileKind {
        case .artist:
            String(localized: "Artist")
        case .profile:
            String(localized: "Profile")
        case .unknown:
            nil
        }
    }

    @ViewBuilder
    private func subscribeButton(_ detail: ArtistDetail) -> some View {
        if detail.isSubscribed {
            Button {
                HapticService.toggle()
                Task {
                    await self.viewModel.toggleSubscription()
                }
            } label: {
                if self.viewModel.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Text(self.subscribeButtonText(detail))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(self.viewModel.isSubscribing)
        } else {
            Button {
                HapticService.toggle()
                Task {
                    await self.viewModel.toggleSubscription()
                }
            } label: {
                if self.viewModel.isSubscribing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Text(self.subscribeButtonText(detail))
                        .foregroundStyle(.white)
                }
            }
            .compatGlassProminentButton()
            .controlSize(.large)
            .disabled(self.viewModel.isSubscribing)
        }
    }

    private func songsSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(self.viewModel.artistDetail?.songsSectionTitle ?? String(localized: "Top songs"))
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // See all button - navigates to full top songs view
                if self.viewModel.hasMoreSongs, let detail = viewModel.artistDetail {
                    NavigationLink(value: TopSongsDestination(
                        artistId: detail.id,
                        artistName: detail.name,
                        title: detail.songsSectionTitle ?? String(localized: "Top songs"),
                        songs: detail.songs,
                        songsBrowseId: detail.songsBrowseId,
                        songsParams: detail.songsParams
                    )) {
                        Text(String(localized: "See all"))
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(self.viewModel.displayedSongs.enumerated()), id: \.offset) { index, song in
                    self.topSongRow(song, index: index)

                    if index < self.viewModel.displayedSongs.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
        }
    }

    /// Song row for top songs section - fetches all songs and plays as queue.
    private func topSongRow(_ song: Song, index: Int) -> some View {
        let isCurrentSong = self.playerService.currentTrack?.videoId == song.videoId
        let isPlaying = isCurrentSong && self.playerService.isPlaying

        return HoverObservingRow { isHovered in
            HStack(spacing: 12) {
                // Thumbnail
                SongThumbnailView(song: song, size: 40, cornerRadius: 4)
                    .allowsHitTesting(false)

                // Title (with optional explicit badge)
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 14))
                        .foregroundStyle(isCurrentSong ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if song.isExplicit == true {
                        ExplicitBadge()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)

                // Artist column
                Text(song.artistsDisplay)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                    .allowsHitTesting(false)

                // Album column (if available)
                if let album = song.album {
                    Text(album.title)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                        .allowsHitTesting(false)
                } else {
                    Text(String(localized: ""))
                        .frame(width: 150, alignment: .leading)
                        .allowsHitTesting(false)
                }

                // Favorite toggle
                LikeButton(song: song, isRowHovered: isHovered, allowsActions: self.hasPersonalAccount)

                // Download button
                DownloadButton(song: song, isRowHovered: isHovered)

                // Play / Pause button
                Button {
                    Task {
                        if isPlaying {
                            await self.playerService.pause()
                        } else if isCurrentSong {
                            await self.playerService.resume()
                        } else {
                            self.viewModel.playTopSong(song, displayedIndex: index, playerService: self.playerService)
                        }
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCurrentSong ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .opacity(isCurrentSong || isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
                .animation(.easeInOut(duration: 0.12), value: isPlaying)
                .help(isPlaying ? String(localized: "Pause") : String(localized: "Play"))

                // Duration
                Text(song.durationDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
                    .allowsHitTesting(false)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background {
                Button {
                    self.viewModel.playTopSong(song, displayedIndex: index, playerService: self.playerService)
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.interactiveRow(cornerRadius: 6))
            }
        }
        .contextMenu {
            Button {
                self.viewModel.playTopSong(song, displayedIndex: index, playerService: self.playerService)
            } label: {
                Label(String(localized: "Play"), systemImage: "play.fill")
            }

            if self.authService.hasPersonalAccount {
                Divider()

                FavoritesContextMenu.menuItem(for: song, manager: self.favoritesManager)

                Divider()

                LikeDislikeContextMenu(song: song, likeStatusManager: self.likeStatusManager)
            }

            Divider()

            StartRadioContextMenu.menuItem(for: song, playerService: self.playerService)

            if self.authService.hasPersonalAccount {
                Divider()

                Button {
                    SongActionsHelper.addToLibrary(song, playerService: self.playerService)
                } label: {
                    Label(String(localized: "Add to Library"), systemImage: "plus.circle")
                }

                Divider()

                AddToPlaylistContextMenu(song: song, client: self.viewModel.client)
            }

            Divider()

            ShareContextMenu.menuItem(for: song)

            Divider()

            AddToQueueContextMenu(song: song, playerService: self.playerService)

            Divider()

            DownloadSongContextMenu(song: song)

            // Go to Album - show if album has valid browse ID
            if let album = song.album, album.hasNavigableId {
                Divider()

                let playlist = Playlist(
                    id: album.id,
                    title: album.title,
                    description: nil,
                    thumbnailURL: album.thumbnailURL ?? song.thumbnailURL,
                    trackCount: album.trackCount,
                    author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
                )
                NavigationLink(value: playlist) {
                    Label(String(localized: "Go to Album"), systemImage: "square.stack")
                }
            }
        }
    }

    private func albumsSection(
        _ albums: [Album],
        title: String = "Albums",
        shelfKind: ArtistShelfKind = .albums
    ) -> some View {
        CarouselShelfSection(
            accessibilityLabel: title,
            items: albums,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            ArtistShelfHeader(title: title, shelfKind: shelfKind, detail: self.viewModel.artistDetail)
        } itemContent: { album in
            NavigationLink(value: self.playlistFromAlbum(album)) {
                ArtistShelfMediaCard(
                    title: album.title,
                    subtitle: album.year,
                    thumbnailURL: album.thumbnailURL,
                    placeholderIcon: "square.stack"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistsSection(_ playlists: [Playlist], title: String) -> some View {
        CarouselShelfSection(
            accessibilityLabel: title,
            items: playlists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            ArtistShelfHeader(title: title, shelfKind: .playlistsByArtist, detail: self.viewModel.artistDetail)
        } itemContent: { playlist in
            NavigationLink(value: playlist) {
                ArtistShelfMediaCard(
                    title: playlist.title,
                    subtitle: Self.playlistSubtitle(for: playlist),
                    thumbnailURL: playlist.thumbnailURL,
                    placeholderIcon: "music.note.list"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func artistsSection(_ artists: [Artist], title: String) -> some View {
        CarouselShelfSection(
            accessibilityLabel: title,
            items: artists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            ArtistShelfHeader(title: title, shelfKind: .relatedArtists, detail: self.viewModel.artistDetail)
        } itemContent: { artist in
            NavigationLink(value: artist) {
                ArtistShelfMediaCard(
                    title: artist.name,
                    subtitle: artist.subtitle,
                    thumbnailURL: artist.thumbnailURL,
                    placeholderIcon: "person.fill",
                    shape: .circle,
                    alignment: .center,
                    subtitleLineLimit: 2
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func episodesSection(_ episodes: [ArtistEpisode]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Latest episodes"),
            items: episodes,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            ArtistShelfHeader(
                title: "Latest episodes",
                shelfKind: .episodes,
                detail: self.viewModel.artistDetail
            )
        } itemContent: { episode in
            Button {
                let intent = self.playerService.beginMusicPlaybackIntent()
                Task {
                    await self.playerService.playEpisode(episode, intent: intent)
                }
            } label: {
                ArtistEpisodeCard(episode: episode)
            }
            .buttonStyle(.plain)
        }
    }

    private func singlesSection(_ singles: [Album]) -> some View {
        self.albumsSection(singles, title: "Singles & EPs", shelfKind: .singles)
    }

    private func playlistsByArtistSection(_ playlists: [Playlist]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Playlists"),
            items: playlists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            ArtistShelfHeader(title: "Playlists", shelfKind: .playlistsByArtist, detail: self.viewModel.artistDetail)
        } itemContent: { playlist in
            NavigationLink(value: playlist) {
                ArtistShelfMediaCard(
                    title: playlist.title,
                    thumbnailURL: playlist.thumbnailURL,
                    placeholderIcon: "music.note.list"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func podcastsSection(_ podcasts: [PodcastShow]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Podcasts"),
            items: podcasts,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            ArtistShelfHeader(title: "Podcasts", shelfKind: .podcasts, detail: self.viewModel.artistDetail)
        } itemContent: { show in
            NavigationLink(value: show) {
                ArtistShelfMediaCard(
                    title: show.title,
                    thumbnailURL: show.thumbnailURL,
                    placeholderIcon: "mic"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func relatedArtistsSection(_ artists: [Artist]) -> some View {
        CarouselShelfSection(
            accessibilityLabel: String(localized: "Fans might also like"),
            items: artists,
            contentInset: DetailContentLayout.horizontalInset
        ) {
            ArtistShelfHeader(
                title: "Fans might also like",
                shelfKind: .relatedArtists,
                detail: self.viewModel.artistDetail
            )
        } itemContent: { artist in
            NavigationLink(value: artist) {
                ArtistShelfMediaCard(
                    title: artist.name,
                    thumbnailURL: artist.thumbnailURL,
                    placeholderIcon: "person.fill",
                    size: 120,
                    shape: .circle,
                    alignment: .center
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistFromAlbum(_ album: Album) -> Playlist {
        Playlist(
            id: album.id,
            title: album.title,
            description: nil,
            thumbnailURL: album.thumbnailURL,
            trackCount: album.trackCount,
            author: Artist.inline(name: album.artistsDisplay, namespace: "album-artist")
        )
    }

    private static func playlistSubtitle(for playlist: Playlist) -> String? {
        if let authorName = playlist.author?.name, !authorName.isEmpty {
            return authorName
        }
        if let trackCount = playlist.trackCount {
            return trackCount == 1 ? "1 song" : "\(trackCount) songs"
        }
        return nil
    }

    private func albumShelfKind(for title: String) -> ArtistShelfKind {
        let lowercasedTitle = title.lowercased()
        return lowercasedTitle.contains("single")
            || lowercasedTitle.contains(" ep")
            || lowercasedTitle.hasPrefix("ep")
            ? .singles
            : .albums
    }

    private var hasPersonalAccount: Bool {
        self.authService.hasPersonalAccount
    }
}

#Preview {
    let artist = Artist(
        id: "test",
        name: "Test Artist",
        thumbnailURL: nil
    )
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    ArtistDetailView(
        artist: artist,
        viewModel: ArtistDetailViewModel(
            artist: artist,
            client: client
        )
    )
    .environment(PlayerService())
}

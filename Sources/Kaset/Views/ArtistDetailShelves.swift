import SwiftUI

// MARK: - ArtistShelfMediaCard

/// Reusable shelf card for square (albums, playlists, podcasts) and circular
/// (artists, related artists) items on `ArtistDetailView`.
struct ArtistShelfMediaCard: View {
    enum ArtworkShape {
        case roundedRect
        case circle
    }

    let title: String
    var subtitle: String?
    var thumbnailURL: URL?
    let placeholderIcon: String
    var size: CGFloat = 140
    var shape: ArtworkShape = .roundedRect
    var alignment: HorizontalAlignment = .leading
    var subtitleLineLimit: Int = 1

    private var textAlignment: TextAlignment {
        self.alignment == .center ? .center : .leading
    }

    private var frameAlignment: Alignment {
        self.alignment == .center ? .center : .leading
    }

    var body: some View {
        VStack(alignment: self.alignment, spacing: 8) {
            CachedAsyncImage(
                url: self.thumbnailURL?.highQualityThumbnailURL,
                targetSize: CGSize(width: self.size, height: self.size)
            ) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: self.placeholderIcon)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: self.size, height: self.size)
            .clipShape(self.shape == .circle ? AnyShape(.circle) : AnyShape(.rect(cornerRadius: 8)))

            Text(self.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(self.textAlignment)
                .frame(width: self.size, alignment: self.frameAlignment)

            if let subtitle = self.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(self.subtitleLineLimit)
                    .multilineTextAlignment(self.textAlignment)
                    .frame(width: self.size, alignment: self.frameAlignment)
            }
        }
    }
}

// MARK: - ArtistEpisodeCard

/// Card for an artist episode or live radio item in the episodes shelf.
struct ArtistEpisodeCard: View {
    let episode: ArtistEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CachedAsyncImage(
                    url: self.episode.thumbnailURL?.highQualityThumbnailURL,
                    targetSize: CGSize(width: 220, height: 124)
                ) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "play.rectangle")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 220, height: 124)
                .clipShape(.rect(cornerRadius: 8))

                if self.episode.isLive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                        Text("LIVE", comment: "Live badge on artist episode card")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .tracking(0.5)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red, in: .capsule)
                    .padding(8)
                }
            }

            Text(self.episode.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 220, alignment: .leading)

            if let subtitle = self.episode.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 220, alignment: .leading)
            }
        }
    }
}

// MARK: - ArtistShelfHeader

/// Section header for artist shelves with an optional "See all" navigation link.
struct ArtistShelfHeader: View {
    let title: String
    let shelfKind: ArtistShelfKind
    let detail: ArtistDetail?

    var body: some View {
        HStack {
            Text(LocalizedStringKey(self.title))
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            if let detail = self.detail,
               let more = detail.moreEndpoints[self.shelfKind]
            {
                self.seeAllLink(more: more, sectionTitle: self.title, artistName: detail.name)
            }
        }
    }

    @ViewBuilder
    private func seeAllLink(
        more: ShelfMoreEndpoint,
        sectionTitle: String,
        artistName: String
    ) -> some View {
        switch more.pageType {
        case .playlist:
            // Playlist-backed See-all destinations reuse the existing
            // `Playlist` navigation route so `PlaylistDetailView` can render
            // the full list.
            NavigationLink(value: Playlist(
                id: more.browseId,
                title: sectionTitle,
                description: nil,
                thumbnailURL: nil,
                trackCount: nil,
                author: Artist.inline(name: artistName, namespace: "playlist-author")
            )) {
                Text(String(localized: "See all")).font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        case .artist, .discography:
            NavigationLink(value: ArtistSeeAllDestination(
                artistName: artistName,
                sectionTitle: sectionTitle,
                endpoint: more
            )) {
                Text(String(localized: "See all")).font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}

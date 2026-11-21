import Foundation

// MARK: - LyricsOvhModel

struct LyricsOvhModel: Decodable {
    let lyrics: String?
}

// MARK: - LyricsOvhProvider

/// Free plain lyrics provider querying `api.lyrics.ovh`.
final class LyricsOvhProvider: LyricsProvider {
    let name = "Lyrics.ovh"

    func search(info: LyricsSearchInfo) async -> LyricResult {
        let artist = LyricsTitleSanitizer.sanitizeArtist(info.artist)
        let title = LyricsTitleSanitizer.sanitizeTitle(info.title)

        guard !artist.isEmpty, !title.isEmpty,
              let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)")
        else {
            return .unavailable
        }

        var request = URLRequest(url: url)
        request.setValue("Kaset/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return .unavailable
            }

            let result = try JSONDecoder().decode(LyricsOvhModel.self, from: data)
            guard let lyrics = result.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !lyrics.isEmpty else {
                return .unavailable
            }

            return .plain(Lyrics(text: lyrics, source: "Source: \(self.name)"))
        } catch {
            return .unavailable
        }
    }
}

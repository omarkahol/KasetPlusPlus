import Foundation
import SwiftUI

extension SettingsManager {
    // MARK: - Launch Page Options

    /// Available pages to launch the app with.
    enum LaunchPage: String, CaseIterable, Identifiable {
        case home
        case explore
        case charts
        case moodsAndGenres
        case newReleases
        case likedMusic
        case playlists
        case lastUsed

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .home: String(localized: "Home")
            case .explore: String(localized: "Explore")
            case .charts: String(localized: "Charts")
            case .moodsAndGenres: String(localized: "Moods & Genres")
            case .newReleases: String(localized: "New Releases")
            case .likedMusic: String(localized: "Liked Music")
            case .playlists: String(localized: "Playlists")
            case .lastUsed: String(localized: "Last Used")
            }
        }

        /// Converts LaunchPage to NavigationItem for navigation.
        var navigationItem: NavigationItem {
            switch self {
            case .home: .home
            case .explore: .explore
            case .charts: .charts
            case .moodsAndGenres: .moodsAndGenres
            case .newReleases: .newReleases
            case .likedMusic: .likedMusic
            case .playlists: .library
            case .lastUsed: .home // Fallback, actual value comes from lastUsedPage
            }
        }
    }

    // MARK: - Content Language

    /// Available language options for app UI localization.
    enum ContentLanguage: String, CaseIterable, Identifiable {
        case system
        case arabic
        case german
        case english
        case spanish
        case french
        case indonesian
        case italian
        case korean
        case dutch
        case polish
        case portuguese
        case russian
        case swedish
        case turkish
        case ukrainian
        case simplifiedChinese
        case traditionalChinese

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .system: String(localized: "System Default")
            case .arabic: "العربية"
            case .dutch: "Nederlands"
            case .english: "English"
            case .french: "Français"
            case .german: "Deutsch"
            case .indonesian: "Bahasa Indonesia"
            case .italian: "Italiano"
            case .korean: "한국어"
            case .polish: "Polski"
            case .portuguese: "Português"
            case .russian: "Русский"
            case .spanish: "Español"
            case .simplifiedChinese: "简体中文"
            case .swedish: "Svenska"
            case .traditionalChinese: "繁體中文"
            case .turkish: "Türkçe"
            case .ukrainian: "Українська"
            }
        }

        /// The language code for bundle lookup, or `nil` for the system default.
        var languageCode: String? {
            switch self {
            case .system: nil
            case .arabic: "ar"
            case .dutch: "nl"
            case .english: "en"
            case .french: "fr"
            case .german: "de"
            case .indonesian: "id"
            case .italian: "it"
            case .korean: "ko"
            case .polish: "pl"
            case .portuguese: "pt"
            case .russian: "ru"
            case .spanish: "es"
            // Chinese is distinguished by script, not region, matching Apple's
            // localization identifiers. Verified against the InnerTube API: these
            // same codes are valid `hl` values and return correctly-scripted
            // responses, so no separate API mapping is needed.
            case .simplifiedChinese: "zh-Hans"
            case .swedish: "sv"
            case .traditionalChinese: "zh-Hant"
            case .turkish: "tr"
            case .ukrainian: "uk"
            }
        }

        /// The language code for YouTube Music API requests (`hl` parameter).
        /// Returns the explicit language code or derives one from the system locale,
        /// falling back to `"en"`.
        var apiLanguageCode: String {
            self.apiLanguageCode(for: Locale.current)
        }

        /// Resolves the API language code against an injectable system locale.
        func apiLanguageCode(for systemLocale: Locale) -> String {
            if let languageCode = self.languageCode {
                return languageCode
            }

            let language = systemLocale.language
            guard let languageCode = language.languageCode?.identifier else {
                return "en"
            }

            return switch (languageCode, language.script?.identifier) {
            case ("zh", "Hans"): "zh-Hans"
            case ("zh", "Hant"): "zh-Hant"
            default: languageCode
            }
        }

        /// The region code for API requests (`gl` parameter), so trends, home
        /// chips, and search reflect the chosen language's country (e.g. Italian
        /// → YouTube Italy). `.system` follows the Mac's region.
        var apiRegionCode: String {
            switch self {
            case .system: Locale.current.region?.identifier ?? "US"
            case .arabic: "SA"
            case .dutch: "NL"
            case .english: "US"
            case .french: "FR"
            case .german: "DE"
            case .indonesian: "ID"
            case .italian: "IT"
            case .korean: "KR"
            case .polish: "PL"
            case .portuguese: "BR"
            case .russian: "RU"
            case .simplifiedChinese: "CN"
            case .spanish: "ES"
            case .swedish: "SE"
            case .traditionalChinese: "TW"
            case .turkish: "TR"
            case .ukrainian: "UA"
            }
        }

        /// The locale matching this language selection.
        var locale: Locale {
            if let code = self.languageCode {
                Locale(identifier: code)
            } else {
                Locale.current
            }
        }
    }

    // MARK: - Media Control Style

    /// Controls which buttons appear in the Now Playing widget (Control Center).
    enum MediaControlStyle: String, CaseIterable, Identifiable {
        case skipForwardBackward
        case nextPreviousTrack

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .skipForwardBackward: "Skip Forward/Backward"
            case .nextPreviousTrack: "Next/Previous Track"
            }
        }
    }

    // MARK: - Playback Audio Quality

    /// Preferred audio quality for playback through the YouTube Music WebView.
    enum PlaybackAudioQuality: String, CaseIterable, Identifiable {
        case auto
        case low
        case normal
        case high

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .auto: "Auto"
            case .low: "Low"
            case .normal: "Normal"
            case .high: "High"
            }
        }
    }

    // MARK: - Download Audio Format

    /// Video quality options for offline downloads mapped directly to yt-dlp format selectors.
    enum VideoDownloadQuality: String, CaseIterable, Identifiable, Codable {
        case best
        case res1080p = "1080p"
        case res720p = "720p"
        case res480p = "480p"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .best:
                String(localized: "Best Available")
            case .res1080p:
                String(localized: "1080p (Full HD)")
            case .res720p:
                String(localized: "720p (HD)")
            case .res480p:
                String(localized: "480p (SD)")
            }
        }

        var formatSelector: String {
            switch self {
            case .best:
                "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best"
            case .res1080p:
                "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[acodec^=mp4a]/bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best[height<=1080]"
            case .res720p:
                "bestvideo[height<=720][vcodec^=avc1]+bestaudio[acodec^=mp4a]/bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]/best[height<=720]"
            case .res480p:
                "bestvideo[height<=480][vcodec^=avc1]+bestaudio[acodec^=mp4a]/bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/best[height<=480][ext=mp4]/best[height<=480]"
            }
        }

        var ytDlpArguments: [String] {
            ["-f", self.formatSelector, "--merge-output-format", "mp4"]
        }

        var fileExtension: String {
            "mp4"
        }
    }

    /// Audio quality/format options for offline downloads mapped directly to yt-dlp arguments.
    enum DownloadAudioFormat: String, CaseIterable, Identifiable, Codable {
        case bestAudio = "best"
        case mp3_320 = "mp3"
        case opus

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .bestAudio:
                String(localized: "Best Audio (M4A / AAC)")
            case .mp3_320:
                String(localized: "MP3 (320 kbps)")
            case .opus:
                String(localized: "Opus (High Quality)")
            }
        }

        var ytDlpArguments: [String] {
            switch self {
            case .bestAudio:
                ["-x", "--audio-format", "m4a", "--audio-quality", "0"]
            case .mp3_320:
                ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
            case .opus:
                ["-x", "--audio-format", "opus", "--audio-quality", "0"]
            }
        }

        var fileExtension: String {
            switch self {
            case .bestAudio: "m4a"
            case .mp3_320: "mp3"
            case .opus: "opus"
            }
        }
    }

    /// The default directory for offline downloads (~/Music/KasetPlus Downloads).
    static var defaultDownloadDirectory: URL {
        if let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first {
            return musicDir.appendingPathComponent("KasetPlus Downloads", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Kaset", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The default directory for offline video downloads (~/Movies/KasetPlus Downloads).
    static var defaultVideoDownloadDirectory: URL {
        if let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            return moviesDir.appendingPathComponent("KasetPlus Downloads", isDirectory: true)
        }
        return Self.defaultDownloadDirectory
    }
}

import AppKit
import Foundation
import Observation
import SwiftUI

/// Manages user preferences persisted via UserDefaults.
@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults: UserDefaults

    // MARK: - Settings Keys

    enum Keys {
        static let appSource = "settings.appSource"
        static let youTubeMusicEnabled = "settings.youTubeMusicEnabled"
        static let showNowPlayingNotifications = "settings.showNowPlayingNotifications"
        static let defaultLaunchPage = "settings.defaultLaunchPage"
        static let lastUsedPage = "settings.lastUsedPage"
        static let hapticFeedbackEnabled = "settings.hapticFeedbackEnabled"
        static let telemetryEnabled = "settings.telemetryEnabled"
        static let rememberPlaybackSettings = "settings.rememberPlaybackSettings"
        static let lastFMEnabled = "settings.lastFMEnabled"
        static let enabledServices = "settings.enabledServices"
        static let scrobblePercentThreshold = "settings.scrobblePercentThreshold"
        static let scrobbleMinSeconds = "settings.scrobbleMinSeconds"
        static let mediaControlStyle = "settings.mediaControlStyle"
        static let playbackAudioQuality = "settings.playbackAudioQuality"
        static let syncedLyricsEnabled = "settings.syncedLyricsEnabled"
        static let romanizationEnabled = "settings.romanizationEnabled"
        static let contentLanguage = "settings.contentLanguage"
        static let keepMiniPlayerOnTop = "settings.keepMiniPlayerOnTop"
        static let keepYouTubeVideoOnTop = "settings.keepYouTubeVideoOnTop"
        static let showMenuBarExtra = "settings.showMenuBarExtra"
        static let smartShuffleEnabled = "settings.smartShuffleEnabled"
        static let smartShuffleSuggestEveryN = "settings.smartShuffleSuggestEveryN"
        static let smartShuffleBurst = "settings.smartShuffleBurst"
        static let smartShuffleSuggestionsAhead = "settings.smartShuffleSuggestionsAhead"
        static let ambientBackdropEnabled = "settings.ambientBackdropEnabled"
        static let ambientBackdropStyle = "settings.ambientBackdropStyle"
        static let controlsOnVideo = "settings.controlsOnVideo"
        static let popOutVideoOnNavigateAway = "settings.popOutVideoOnNavigateAway"
        static let keepPlayingVideoOnNavigateAway = "settings.keepPlayingVideoOnNavigateAway"
        static let sponsorBlockEnabled = "settings.sponsorBlock.enabled"
        static let sponsorBlockCategories = "settings.sponsorBlock.categories"
        static let adBlockEnabled = "settings.adBlock.enabled"
        static let returnYouTubeDislikesEnabled = "settings.ryd.enabled"
        static let dearrowEnabled = "settings.dearrow.enabled"
        static let dearrowUserID = "settings.dearrow.userID"
        static let discordRichPresenceEnabled = "settings.discord.richPresence.enabled"
        static let hasCompletedInitialOnboarding = "settings.onboarding.completed"
        static let distractionFreeEnabled = "settings.distractionFree.enabled"
        static let youtubeAutoplayEnabled = "settings.youtube.autoplay.enabled"
        static let forceOriginalAudioLanguage = "settings.youtube.forceOriginalAudioLanguage"
        static let accentColorHex = "settings.accentColorHex"
        static let downloadAudioFormat = "settings.downloadAudioFormat"
        static let videoDownloadQuality = "settings.videoDownloadQuality"
        static let downloadDirectoryPath = "settings.downloadDirectoryPath"
        static let customYtdlpPath = "settings.customYtdlpPath"
        static let customFfmpegPath = "settings.customFfmpegPath"
        static let maxConcurrentDownloads = "settings.maxConcurrentDownloads"
        static let isOfflineModeEnabled = "isOfflineModeEnabled"
        static let isFastNativeStreamingEnabled = "settings.isFastNativeStreamingEnabled"
        #if DEBUG
            static let useLegacyMacOS15UI = "settings.debug.useLegacyMacOS15UI"
        #endif
    }

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
        case best = "best"
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
        case opus = "opus"

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

    // MARK: - Settings Properties

    /// The active content source (YouTube Music or regular YouTube).
    var appSource: AppSource {
        didSet {
            self.defaults.set(self.appSource.rawValue, forKey: Keys.appSource)
        }
    }

    /// The app-wide accent color. Drives the root `.tint(...)` (so every standard
    /// control follows) and the brand accent used by custom UI (`Self.brandAccent`
    /// in the player, watch page, etc.). Defaults to the KasetPlus brand color.
    var accentColor: Color {
        didSet {
            self.defaults.set(Self.hex(from: self.accentColor), forKey: Keys.accentColorHex)
        }
    }

    /// The default brand accent (used when the user hasn't picked a custom one).
    static var defaultAccentColor: Color { PackageResourceLookup.brandAccent }

    /// Whether a custom accent (different from the brand default) is in effect.
    var isUsingCustomAccent: Bool {
        self.defaults.string(forKey: Keys.accentColorHex) != nil
    }

    /// Restores the brand accent and forgets any custom choice.
    func resetAccentColor() {
        self.defaults.removeObject(forKey: Keys.accentColorHex)
        // Assigning re-persists the hex; remove it again so `isUsingCustomAccent`
        // reflects "default" and a fresh install stays keyless.
        self.accentColor = Self.defaultAccentColor
        self.defaults.removeObject(forKey: Keys.accentColorHex)
    }

    /// Serializes a color to a `#RRGGBB` sRGB hex string for persistence.
    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .init(srgbRed: 1, green: 0, blue: 0.337, alpha: 1)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Parses a `#RRGGBB` sRGB hex string back into a color.
    static func color(fromHex hex: String) -> Color? {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// Whether the YouTube Music experience is available. When off, the Music
    /// surface, its source toggle, and the Music settings tab are hidden and the
    /// app stays on regular YouTube (feature request #8).
    var youTubeMusicEnabled: Bool {
        didSet {
            self.defaults.set(self.youTubeMusicEnabled, forKey: Keys.youTubeMusicEnabled)
            if !self.youTubeMusicEnabled, self.appSource == .music {
                self.appSource = .video
            }
        }
    }

    /// Whether to show system notifications when the track changes.
    var showNowPlayingNotifications: Bool {
        didSet {
            self.defaults.set(self.showNowPlayingNotifications, forKey: Keys.showNowPlayingNotifications)
        }
    }

    /// The default page to show when the app launches.
    var defaultLaunchPage: LaunchPage {
        didSet {
            self.defaults.set(self.defaultLaunchPage.rawValue, forKey: Keys.defaultLaunchPage)
        }
    }

    /// Whether haptic feedback is enabled.
    var hapticFeedbackEnabled: Bool {
        didSet {
            self.defaults.set(self.hapticFeedbackEnabled, forKey: Keys.hapticFeedbackEnabled)
        }
    }

    /// Whether anonymous breakage telemetry is sent (see `Telemetry`). Opt-out.
    var telemetryEnabled: Bool {
        didSet {
            self.defaults.set(self.telemetryEnabled, forKey: Keys.telemetryEnabled)
        }
    }

    /// Whether to remember shuffle/repeat settings across app restarts.
    var rememberPlaybackSettings: Bool {
        didSet {
            self.defaults.set(self.rememberPlaybackSettings, forKey: Keys.rememberPlaybackSettings)
            // Clear stale values when setting is disabled to prevent unexpected restoration
            if !self.rememberPlaybackSettings {
                self.defaults.removeObject(forKey: "playerShuffleEnabled")
                self.defaults.removeObject(forKey: "playerShuffleMode")
                self.defaults.removeObject(forKey: "playerRepeatMode")
            }
        }
    }

    /// Which buttons to show in the Now Playing widget: skip forward/backward or next/previous track.
    var mediaControlStyle: MediaControlStyle {
        didSet {
            self.defaults.set(self.mediaControlStyle.rawValue, forKey: Keys.mediaControlStyle)
        }
    }

    /// Preferred audio quality for playback through the YouTube Music WebView.
    var playbackAudioQuality: PlaybackAudioQuality {
        didSet {
            self.defaults.set(self.playbackAudioQuality.rawValue, forKey: Keys.playbackAudioQuality)
        }
    }

    /// Per-service enabled flags stored as a dictionary.
    private var enabledServices: [String: Bool] {
        didSet {
            self.defaults.set(self.enabledServices, forKey: Keys.enabledServices)
        }
    }

    /// Whether a specific scrobbling service is enabled by name.
    func isServiceEnabled(_ serviceName: String) -> Bool {
        self.enabledServices[serviceName] ?? false
    }

    /// Sets the enabled state for a specific scrobbling service by name.
    func setServiceEnabled(_ serviceName: String, _ enabled: Bool) {
        self.enabledServices[serviceName] = enabled
    }

    /// Whether Last.fm scrobbling is enabled (backward-compatible convenience).
    var lastFMEnabled: Bool {
        get { self.isServiceEnabled("Last.fm") }
        set { self.setServiceEnabled("Last.fm", newValue) }
    }

    /// Percentage of track duration required before scrobbling (0.0–1.0).
    var scrobblePercentThreshold: Double {
        didSet {
            self.defaults.set(self.scrobblePercentThreshold, forKey: Keys.scrobblePercentThreshold)
        }
    }

    /// Minimum seconds of play time before scrobbling (overrides percentage for long tracks).
    var scrobbleMinSeconds: TimeInterval {
        didSet {
            self.defaults.set(self.scrobbleMinSeconds, forKey: Keys.scrobbleMinSeconds)
        }
    }

    /// The last page the user was on (for "Last Used" option).
    var lastUsedPage: LaunchPage {
        didSet {
            self.defaults.set(self.lastUsedPage.rawValue, forKey: Keys.lastUsedPage)
        }
    }

    /// Whether synced lyrics are preferred.
    var syncedLyricsEnabled: Bool {
        didSet {
            self.defaults.set(self.syncedLyricsEnabled, forKey: Keys.syncedLyricsEnabled)
        }
    }

    /// Whether romanization of non-Latin lyrics is enabled.
    var romanizationEnabled: Bool {
        didSet {
            self.defaults.set(self.romanizationEnabled, forKey: Keys.romanizationEnabled)
        }
    }

    /// Whether the mini player floats above other windows.
    var keepMiniPlayerOnTop: Bool {
        didSet {
            self.defaults.set(self.keepMiniPlayerOnTop, forKey: Keys.keepMiniPlayerOnTop)
        }
    }

    /// Whether the popped-out YouTube video window floats above standard windows.
    var keepYouTubeVideoOnTop: Bool {
        didSet {
            self.defaults.set(self.keepYouTubeVideoOnTop, forKey: Keys.keepYouTubeVideoOnTop)
        }
    }

    /// Whether to show the native menu bar extra player item.
    var showMenuBarExtra: Bool {
        didSet {
            self.defaults.set(self.showMenuBarExtra, forKey: Keys.showMenuBarExtra)
        }
    }

    // MARK: - Smart Shuffle defaults & ranges (single source of truth)

    /// Default cadence: insert a burst of suggestions every N originals.
    static let smartShuffleSuggestEveryNDefault = 3
    /// Valid range for the insert-every-N cadence.
    static let smartShuffleSuggestEveryNRange = 1 ... 6
    /// Default number of suggestions inserted at each slot.
    static let smartShuffleBurstDefault = 1
    /// Valid range for the per-insertion burst.
    static let smartShuffleBurstRange = 1 ... 5
    /// Default number of suggestions to keep queued ahead of the current track.
    static let smartShuffleSuggestionsAheadDefault = 20
    /// Valid range for how many suggestions to keep queued ahead.
    static let smartShuffleSuggestionsAheadRange = 5 ... 100

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Whether Smart Shuffle (the third shuffle state) is available from the shuffle button.
    var smartShuffleEnabled: Bool {
        didSet {
            self.defaults.set(self.smartShuffleEnabled, forKey: Keys.smartShuffleEnabled)
        }
    }

    /// Smart Shuffle interleave cadence: insert a burst of suggestions every N songs (1...6).
    var smartShuffleSuggestEveryN: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleSuggestEveryN, to: Self.smartShuffleSuggestEveryNRange)
            if clamped != self.smartShuffleSuggestEveryN {
                self.smartShuffleSuggestEveryN = clamped
            }
            self.defaults.set(clamped, forKey: Keys.smartShuffleSuggestEveryN)
        }
    }

    /// Smart Shuffle burst: how many suggestions to insert at each slot (1...5).
    var smartShuffleBurst: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleBurst, to: Self.smartShuffleBurstRange)
            if clamped != self.smartShuffleBurst {
                self.smartShuffleBurst = clamped
            }
            self.defaults.set(clamped, forKey: Keys.smartShuffleBurst)
        }
    }

    /// Smart Shuffle: how many suggestions to keep queued ahead of the current track (5...100).
    var smartShuffleSuggestionsAhead: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleSuggestionsAhead, to: Self.smartShuffleSuggestionsAheadRange)
            if clamped != self.smartShuffleSuggestionsAhead {
                self.smartShuffleSuggestionsAhead = clamped
            }
            self.defaults.set(clamped, forKey: Keys.smartShuffleSuggestionsAhead)
        }
    }

    /// Whether the ambient color backdrop is shown on the YouTube watch page.
    /// Applies to regular YouTube videos only, not the Music experience.
    var ambientBackdropEnabled: Bool {
        didSet {
            self.defaults.set(self.ambientBackdropEnabled, forKey: Keys.ambientBackdropEnabled)
        }
    }

    /// Whether playback controls are shown on the video itself (YouTube-style)
    /// instead of the docked bar, on the YouTube watch page.
    var controlsOnVideoEnabled: Bool {
        didSet {
            self.defaults.set(self.controlsOnVideoEnabled, forKey: Keys.controlsOnVideo)
        }
    }

    /// Whether YouTube videos automatically switch to their original audio track
    /// instead of auto-dubbed tracks when multiple audio tracks are available.
    var forceOriginalAudioLanguage: Bool {
        didSet {
            self.defaults.set(self.forceOriginalAudioLanguage, forKey: Keys.forceOriginalAudioLanguage)
        }
    }

    /// The chosen ambient backdrop style when the feature is enabled.
    var ambientBackdropStyle: AmbientBackdropStyle {
        didSet {
            self.defaults.set(self.ambientBackdropStyle.rawValue, forKey: Keys.ambientBackdropStyle)
        }
    }

    /// Whether a playing YouTube video pops out into the floating window when
    /// the user navigates away from the inline watch view. When disabled,
    /// playback stops instead. Applies to regular YouTube videos only, not the
    /// Music experience.
    var popOutVideoOnNavigateAway: Bool {
        didSet {
            self.defaults.set(self.popOutVideoOnNavigateAway, forKey: Keys.popOutVideoOnNavigateAway)
        }
    }

    /// Whether a playing YouTube video keeps playing docked — controlled from
    /// the bottom player bar, with no floating pop-out window — when the user
    /// navigates away from the inline watch view. When on, this takes precedence
    /// over `popOutVideoOnNavigateAway`; the user returns to the video from the
    /// bar. Off by default so existing behavior is unchanged. Regular YouTube
    /// videos only, not the Music experience.
    var keepPlayingVideoOnNavigateAway: Bool {
        didSet {
            self.defaults.set(self.keepPlayingVideoOnNavigateAway, forKey: Keys.keepPlayingVideoOnNavigateAway)
        }
    }

    /// Whether SponsorBlock auto-skip is enabled for YouTube videos.
    var sponsorBlockEnabled: Bool {
        didSet {
            self.defaults.set(self.sponsorBlockEnabled, forKey: Keys.sponsorBlockEnabled)
        }
    }

    /// SponsorBlock categories to skip (e.g. sponsor, selfpromo, intro).
    var sponsorBlockCategories: [String] {
        didSet {
            self.defaults.set(self.sponsorBlockCategories, forKey: Keys.sponsorBlockCategories)
        }
    }

    /// Whether the built-in ad blocker is enabled. Blocks ad/tracking domains
    /// in all WebViews and auto-skips YouTube in-video ads.
    var adBlockEnabled: Bool {
        didSet {
            self.defaults.set(self.adBlockEnabled, forKey: Keys.adBlockEnabled)
        }
    }

    /// Whether Return YouTube Dislikes is enabled. Shows dislike counts
    /// fetched from the RYD API next to the dislike button in the player bar.
    var returnYouTubeDislikesEnabled: Bool {
        didSet {
            self.defaults.set(self.returnYouTubeDislikesEnabled, forKey: Keys.returnYouTubeDislikesEnabled)
        }
    }

    /// Whether Discord Rich Presence is enabled. Publishes the current track
    /// or video to the local Discord client over its IPC socket (issue #34).
    var discordRichPresenceEnabled: Bool {
        didSet {
            self.defaults.set(self.discordRichPresenceEnabled, forKey: Keys.discordRichPresenceEnabled)
        }
    }

    /// Whether DeArrow is enabled. Replaces clickbait video titles with
    /// community-submitted accurate titles from the DeArrow API.
    var dearrowEnabled: Bool {
        didSet {
            self.defaults.set(self.dearrowEnabled, forKey: Keys.dearrowEnabled)
        }
    }

    /// Persistent local user ID for DeArrow title voting & submissions.
    /// Lazily generates and persists a 36-character UUID string on first use.
    var dearrowUserID: String {
        if let existing = self.defaults.string(forKey: Keys.dearrowUserID), existing.count >= 30 {
            return existing
        }
        let generated = UUID().uuidString
        self.defaults.set(generated, forKey: Keys.dearrowUserID)
        return generated
    }

    /// Distraction-free mode: hides the comments and the related-videos rail on
    /// the YouTube watch page so only the video and its metadata remain.
    var distractionFreeEnabled: Bool {
        didSet {
            self.defaults.set(self.distractionFreeEnabled, forKey: Keys.distractionFreeEnabled)
        }
    }

    /// YouTube-style autoplay: when a video finishes, automatically play the next
    /// suggested (up-next) video. Off by default; the fork otherwise stops at the
    /// end (YouTube's own autonav is always disabled).
    var youtubeAutoplayEnabled: Bool {
        didSet {
            self.defaults.set(self.youtubeAutoplayEnabled, forKey: Keys.youtubeAutoplayEnabled)
        }
    }

    /// Whether the one-time first-launch onboarding (the addons walkthrough)
    /// has been completed. The full onboarding — changelog → Continue → Addons →
    /// Done — is shown only once, on first launch. Later versions surface just the
    /// changelog (What's New), without the addons step.
    var hasCompletedInitialOnboarding: Bool {
        didSet {
            self.defaults.set(self.hasCompletedInitialOnboarding, forKey: Keys.hasCompletedInitialOnboarding)
        }
    }

    /// Available SponsorBlock segment categories.
    static let sponsorBlockCategoryOptions: [(id: String, label: String)] = [
        ("sponsor", String(localized: "Sponsor")),
        ("selfpromo", String(localized: "Self-promotion")),
        ("interaction", String(localized: "Interaction Reminder")),
        ("intro", String(localized: "Intro")),
        ("outro", String(localized: "Outro")),
        ("preview", String(localized: "Preview / Recap")),
        ("music_offtopic", String(localized: "Non-Music")),
        ("filler", String(localized: "Filler")),
    ]

    /// The style the YouTube watch page should actually render: the chosen
    /// style when enabled, `.off` when the feature is disabled.
    var resolvedAmbientStyle: AmbientBackdropStyle {
        self.ambientBackdropEnabled ? self.ambientBackdropStyle : .off
    }

    /// The language used for the app interface and API content.
    var contentLanguage: ContentLanguage {
        didSet {
            self.defaults.set(self.contentLanguage.rawValue, forKey: Keys.contentLanguage)
            AppLocalization.setLanguage(self.contentLanguage.languageCode)
            APICache.shared.invalidateAll()
        }
    }

    #if DEBUG
        /// Debug-only switch that forces the app to render macOS 15 fallback UI on newer OS versions.
        var useLegacyMacOS15UI: Bool {
            didSet {
                self.defaults.set(self.useLegacyMacOS15UI, forKey: Keys.useLegacyMacOS15UI)
            }
        }
    #else
        /// Release builds always use the native UI for the host OS.
        let useLegacyMacOS15UI = false
    #endif

    /// Preferred audio quality/format for offline downloads.
    var downloadAudioFormat: DownloadAudioFormat {
        didSet {
            self.defaults.set(self.downloadAudioFormat.rawValue, forKey: Keys.downloadAudioFormat)
        }
    }

    /// Preferred video quality for offline downloads.
    var videoDownloadQuality: VideoDownloadQuality {
        didSet {
            self.defaults.set(self.videoDownloadQuality.rawValue, forKey: Keys.videoDownloadQuality)
        }
    }

    /// Custom download directory path on disk.
    var downloadDirectoryPath: String {
        didSet {
            self.defaults.set(self.downloadDirectoryPath, forKey: Keys.downloadDirectoryPath)
        }
    }

    /// Resolved URL of the download directory.
    var resolvedDownloadDirectory: URL {
        URL(fileURLWithPath: self.downloadDirectoryPath, isDirectory: true)
    }

    /// User-specified custom path to yt-dlp binary (if any).
    var customYtdlpPath: String {
        didSet {
            self.defaults.set(self.customYtdlpPath, forKey: Keys.customYtdlpPath)
        }
    }

    /// User-specified custom path to ffmpeg binary (if any).
    var customFfmpegPath: String {
        didSet {
            self.defaults.set(self.customFfmpegPath, forKey: Keys.customFfmpegPath)
        }
    }

    /// Maximum concurrent downloads allowed at once (1...5).
    var maxConcurrentDownloads: Int {
        didSet {
            let clamped = min(max(self.maxConcurrentDownloads, 1), 5)
            if clamped != self.maxConcurrentDownloads {
                self.maxConcurrentDownloads = clamped
            }
            self.defaults.set(clamped, forKey: Keys.maxConcurrentDownloads)
        }
    }

    /// Whether Offline Mode is enabled. When enabled, only downloaded tracks will play natively via AVPlayer.
    var isOfflineModeEnabled: Bool {
        didSet {
            self.defaults.set(self.isOfflineModeEnabled, forKey: Keys.isOfflineModeEnabled)
        }
    }

    /// Whether fast native audio streaming (bypassing WebView via yt-dlp) is enabled.
    var isFastNativeStreamingEnabled: Bool {
        didSet {
            self.defaults.set(self.isFastNativeStreamingEnabled, forKey: Keys.isFastNativeStreamingEnabled)
        }
    }

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Load persisted settings or use defaults
        self.showNowPlayingNotifications = defaults.object(forKey: Keys.showNowPlayingNotifications) as? Bool ?? true
        self.isOfflineModeEnabled = defaults.object(forKey: Keys.isOfflineModeEnabled) as? Bool ?? false
        self.isFastNativeStreamingEnabled = defaults.object(forKey: Keys.isFastNativeStreamingEnabled) as? Bool ?? false
        if let rawValue = defaults.string(forKey: Keys.lastUsedPage),
           let page = LaunchPage(rawValue: rawValue)
        {
            self.lastUsedPage = page
        } else {
            self.lastUsedPage = .home
        }
        self.hapticFeedbackEnabled = defaults.object(forKey: Keys.hapticFeedbackEnabled) as? Bool ?? true
        self.telemetryEnabled = defaults.object(forKey: Keys.telemetryEnabled) as? Bool ?? true
        self.rememberPlaybackSettings = defaults.object(forKey: Keys.rememberPlaybackSettings) as? Bool ?? false

        // Load per-service enabled flags, migrating from legacy lastFMEnabled if needed
        if let stored = defaults.dictionary(forKey: Keys.enabledServices) as? [String: Bool] {
            self.enabledServices = stored
        } else if let legacyEnabled = defaults.object(forKey: Keys.lastFMEnabled) as? Bool {
            // Migrate from single-service flag to dictionary
            self.enabledServices = ["Last.fm": legacyEnabled]
        } else {
            self.enabledServices = [:]
        }
        self.scrobblePercentThreshold = defaults.object(forKey: Keys.scrobblePercentThreshold) as? Double ?? 0.5
        self.scrobbleMinSeconds = defaults.object(forKey: Keys.scrobbleMinSeconds) as? Double ?? 240
        self.syncedLyricsEnabled = defaults.object(forKey: Keys.syncedLyricsEnabled) as? Bool ?? true
        self.romanizationEnabled = defaults.object(forKey: Keys.romanizationEnabled) as? Bool ?? true
        self.keepMiniPlayerOnTop = defaults.object(forKey: Keys.keepMiniPlayerOnTop) as? Bool ?? false
        // Default on: the fork's pop-out has always floated on top; the toggle lets users turn it off.
        self.keepYouTubeVideoOnTop = defaults.object(forKey: Keys.keepYouTubeVideoOnTop) as? Bool ?? true
        self.showMenuBarExtra = defaults.object(forKey: Keys.showMenuBarExtra) as? Bool ?? true
        self.smartShuffleEnabled = defaults.object(forKey: Keys.smartShuffleEnabled) as? Bool ?? true
        // Property observers do not fire for assignments in init, so clamp persisted values here too.
        self.smartShuffleSuggestEveryN = Self.clamp(
            defaults.object(forKey: Keys.smartShuffleSuggestEveryN) as? Int ?? Self.smartShuffleSuggestEveryNDefault,
            to: Self.smartShuffleSuggestEveryNRange
        )
        self.smartShuffleBurst = Self.clamp(
            defaults.object(forKey: Keys.smartShuffleBurst) as? Int ?? Self.smartShuffleBurstDefault,
            to: Self.smartShuffleBurstRange
        )
        self.smartShuffleSuggestionsAhead = Self.clamp(
            defaults.object(forKey: Keys.smartShuffleSuggestionsAhead) as? Int ?? Self.smartShuffleSuggestionsAheadDefault,
            to: Self.smartShuffleSuggestionsAheadRange
        )
        self.ambientBackdropEnabled = defaults.object(forKey: Keys.ambientBackdropEnabled) as? Bool ?? true
        self.controlsOnVideoEnabled = defaults.object(forKey: Keys.controlsOnVideo) as? Bool ?? true
        self.forceOriginalAudioLanguage = defaults.object(forKey: Keys.forceOriginalAudioLanguage) as? Bool ?? false
        self.popOutVideoOnNavigateAway = defaults.object(forKey: Keys.popOutVideoOnNavigateAway) as? Bool ?? true
        self.keepPlayingVideoOnNavigateAway = defaults.object(forKey: Keys.keepPlayingVideoOnNavigateAway) as? Bool ?? false
        self.sponsorBlockEnabled = defaults.object(forKey: Keys.sponsorBlockEnabled) as? Bool ?? false
        self.sponsorBlockCategories = defaults.object(forKey: Keys.sponsorBlockCategories) as? [String] ?? ["sponsor", "selfpromo", "interaction"]
        self.adBlockEnabled = defaults.object(forKey: Keys.adBlockEnabled) as? Bool ?? false
        self.returnYouTubeDislikesEnabled = defaults.object(forKey: Keys.returnYouTubeDislikesEnabled) as? Bool ?? false
        self.dearrowEnabled = defaults.object(forKey: Keys.dearrowEnabled) as? Bool ?? false
        self.discordRichPresenceEnabled = defaults.object(forKey: Keys.discordRichPresenceEnabled) as? Bool ?? false
        self.hasCompletedInitialOnboarding = defaults.object(forKey: Keys.hasCompletedInitialOnboarding) as? Bool ?? false
        self.distractionFreeEnabled = defaults.object(forKey: Keys.distractionFreeEnabled) as? Bool ?? false
        self.youtubeAutoplayEnabled = defaults.object(forKey: Keys.youtubeAutoplayEnabled) as? Bool ?? false
        #if DEBUG
            self.useLegacyMacOS15UI = defaults.object(forKey: Keys.useLegacyMacOS15UI) as? Bool ?? false
        #endif

        if let rawValue = defaults.string(forKey: Keys.mediaControlStyle),
           let style = MediaControlStyle(rawValue: rawValue)
        {
            self.mediaControlStyle = style
        } else {
            self.mediaControlStyle = .nextPreviousTrack
        }

        if let rawValue = defaults.string(forKey: Keys.playbackAudioQuality),
           let quality = PlaybackAudioQuality(rawValue: rawValue)
        {
            self.playbackAudioQuality = quality
        } else {
            self.playbackAudioQuality = .auto
        }

        if let rawValue = defaults.string(forKey: Keys.downloadAudioFormat),
           let format = DownloadAudioFormat(rawValue: rawValue)
        {
            self.downloadAudioFormat = format
        } else {
            self.downloadAudioFormat = .bestAudio
        }

        if let rawValue = defaults.string(forKey: Keys.videoDownloadQuality),
           let quality = VideoDownloadQuality(rawValue: rawValue)
        {
            self.videoDownloadQuality = quality
        } else {
            self.videoDownloadQuality = .best
        }

        self.downloadDirectoryPath = defaults.string(forKey: Keys.downloadDirectoryPath) ?? Self.defaultDownloadDirectory.path
        self.customYtdlpPath = defaults.string(forKey: Keys.customYtdlpPath) ?? ""
        self.customFfmpegPath = defaults.string(forKey: Keys.customFfmpegPath) ?? ""
        self.maxConcurrentDownloads = defaults.object(forKey: Keys.maxConcurrentDownloads) as? Int ?? 3

        if let rawValue = defaults.string(forKey: Keys.ambientBackdropStyle),
           let style = AmbientBackdropStyle(rawValue: rawValue)
        {
            // Persist every choice, including `.off` — previously `.off` was
            // dropped on load and silently reverted to `.live` each launch.
            self.ambientBackdropStyle = style
        } else {
            self.ambientBackdropStyle = .live
        }

        if let rawValue = defaults.string(forKey: Keys.defaultLaunchPage),
           let page = LaunchPage(rawValue: rawValue)
        {
            self.defaultLaunchPage = page
        } else {
            self.defaultLaunchPage = .home
        }

        if let rawValue = defaults.string(forKey: Keys.contentLanguage),
           let language = ContentLanguage(rawValue: rawValue)
        {
            self.contentLanguage = language
        } else {
            self.contentLanguage = .system
        }

        let musicEnabled = defaults.object(forKey: Keys.youTubeMusicEnabled) as? Bool ?? true
        self.youTubeMusicEnabled = musicEnabled

        if !musicEnabled {
            // Music disabled → always land on YouTube regardless of the saved source.
            self.appSource = .video
        } else if let rawValue = defaults.string(forKey: Keys.appSource),
                  let source = AppSource(rawValue: rawValue)
        {
            self.appSource = source
        } else {
            self.appSource = .music
        }

        if let hex = defaults.string(forKey: Keys.accentColorHex),
           let color = Self.color(fromHex: hex)
        {
            self.accentColor = color
        } else {
            self.accentColor = Self.defaultAccentColor
        }

        AppLocalization.setLanguage(self.contentLanguage.languageCode)

        // Persist migration from legacy lastFMEnabled key (must run after all properties initialized)
        if defaults.object(forKey: Keys.enabledServices) == nil,
           defaults.object(forKey: Keys.lastFMEnabled) != nil
        {
            defaults.set(self.enabledServices, forKey: Keys.enabledServices)
            defaults.removeObject(forKey: Keys.lastFMEnabled)
        }
    }

    // MARK: - Computed Properties

    /// Returns the page to navigate to on launch based on settings.
    var launchPage: LaunchPage {
        switch self.defaultLaunchPage {
        case .lastUsed:
            self.lastUsedPage
        default:
            self.defaultLaunchPage
        }
    }

    /// Returns the NavigationItem to use on app launch.
    var launchNavigationItem: NavigationItem {
        self.launchPage.navigationItem
    }
}

import Foundation

// MARK: - YTDLPBinaryLocator

/// Locates and caches `yt-dlp` and `ffmpeg` executable paths without running
/// synchronous `which` subprocesses on the main thread.
@MainActor
final class YTDLPBinaryLocator {
    static let shared = YTDLPBinaryLocator()

    private var cachedYtdlpPath: String?
    private var hasAttemptedAsyncYtdlpLookup = false
    private var cachedFfmpegPath: String?
    private var lastCustomFfmpegPath: String?
    private var hasAttemptedAsyncFfmpegLookup = false

    private init() {}

    func ytdlpPath() -> String? {
        if let cached = self.cachedYtdlpPath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        if let resolved = Self.fastPathYtdlp() {
            self.cachedYtdlpPath = resolved
            return resolved
        }
        if !self.hasAttemptedAsyncYtdlpLookup {
            self.hasAttemptedAsyncYtdlpLookup = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let resolved = await Self.resolveInPath("yt-dlp") {
                    self.cachedYtdlpPath = resolved
                }
            }
        }
        return nil
    }

    func resolveYtdlpPath() async -> String? {
        if let fast = self.ytdlpPath() {
            return fast
        }
        if let resolved = await Self.resolveInPath("yt-dlp") {
            self.cachedYtdlpPath = resolved
            return resolved
        }
        return nil
    }

    func ffmpegPath(customPath: String) -> String? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
        if self.lastCustomFfmpegPath != trimmed {
            self.lastCustomFfmpegPath = trimmed
            self.cachedFfmpegPath = nil
            self.hasAttemptedAsyncFfmpegLookup = false
        }
        if let cached = self.cachedFfmpegPath, FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                self.cachedFfmpegPath = path
                return path
            }
        }
        if !self.hasAttemptedAsyncFfmpegLookup {
            self.hasAttemptedAsyncFfmpegLookup = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let resolved = await Self.resolveInPath("ffmpeg") {
                    self.cachedFfmpegPath = resolved
                }
            }
        }
        return nil
    }

    func invalidate() {
        self.cachedYtdlpPath = nil
        self.hasAttemptedAsyncYtdlpLookup = false
        self.cachedFfmpegPath = nil
        self.hasAttemptedAsyncFfmpegLookup = false
    }

    private static func fastPathYtdlp() -> String? {
        for sysPath in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: sysPath) {
                return sysPath
            }
        }
        if let resourcePath = Bundle.main.resourcePath {
            let bundledPath = (resourcePath as NSString).appendingPathComponent("yt-dlp")
            if FileManager.default.isExecutableFile(atPath: bundledPath) {
                return bundledPath
            }
        }
        if let path = Bundle.main.path(forResource: "yt-dlp", ofType: nil),
           FileManager.default.isExecutableFile(atPath: path)
        {
            return path
        }
        return nil
    }

    private static func resolveInPath(_ name: String) async -> String? {
        let output = await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", name],
            timeoutSeconds: 2.0
        )
        guard let output, output.terminationStatus == 0 else { return nil }
        let path = String(data: output.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }
}

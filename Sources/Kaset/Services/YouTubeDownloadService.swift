import Foundation

// MARK: - YouTubeDownloadService

/// Wraps `yt-dlp` for downloading YouTube videos.
/// Requires yt-dlp installed (e.g. `brew install yt-dlp`).
@MainActor
final class YouTubeDownloadService {
    static let shared = YouTubeDownloadService()

    var downloadsDir: URL {
        DownloadManager.shared.videosDirectory
    }

    private init() {}

    // MARK: - yt-dlp binary path

    /// Bundled yt-dlp binary (included in app Resources by build script).
    /// Falls back to system-installed yt-dlp and common paths.
    private var ytdlpPath: String? {
        YTDLPBinaryLocator.shared.ytdlpPath()
    }

    /// Whether yt-dlp is reachable (bundled or system).
    var isAvailable: Bool {
        guard let path = ytdlpPath else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - Formats

    struct DownloadFormat: Identifiable {
        let id: String           // yt-dlp format code
        let label: String        // "1080p (mp4)" / "MP3 (audio)"
        let isAudioOnly: Bool
        let fileSize: Int64?     // bytes, nil if unknown
        var sizeLabel: String {
            guard let size = fileSize else { return "" }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: size)
        }
    }

    private nonisolated static func configuredEnvironment(customFfmpegPath: String = "") -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.deno/bin"]
        if !customFfmpegPath.isEmpty {
            let parent = (customFfmpegPath as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                extraPaths.insert(parent, at: 0)
            }
        }
        let prefix = extraPaths.joined(separator: ":")
        if let currentPath = env["PATH"], !currentPath.isEmpty {
            env["PATH"] = "\(prefix):\(currentPath)"
        } else {
            env["PATH"] = prefix
        }
        return env
    }

    /// Fetches available download formats for a YouTube video.
    func fetchFormats(videoId: String) async -> [DownloadFormat] {
        guard let ytdlpPath = await YTDLPBinaryLocator.shared.resolveYtdlpPath(),
              let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)")
        else { return [] }
        let env = Self.configuredEnvironment(customFfmpegPath: SettingsManager.shared.customFfmpegPath)

        guard let output = await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: ytdlpPath),
            arguments: ["-J", "--no-playlist", "--socket-timeout", "20", url.absoluteString],
            environment: env,
            timeoutSeconds: 25.0,
            maxOutputBytes: 8_388_608
        ) else {
            return []
        }

        guard !output.stdout.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let formats = json["formats"] as? [[String: Any]]
        else {
            if let errStr = String(data: output.stderr, encoding: .utf8), !errStr.isEmpty {
                DiagnosticsLogger.app.error("yt-dlp stderr: \(errStr)")
            }
            return []
        }
        return Self.parseFormatsStatic(formats)
    }

    private nonisolated static func parseFormatsStatic(_ formats: [[String: Any]]) -> [DownloadFormat] {
        struct HeightCandidate {
            let filesize: Int64?
            let isPreferredCodec: Bool
        }

        var byHeight: [Int: HeightCandidate] = [:]

        for fmt in formats {
            guard let formatId = fmt["format_id"] as? String,
                  !formatId.contains("storyboard"),
                  let vcodec = fmt["vcodec"] as? String,
                  vcodec != "none",
                  let height = fmt["height"] as? Int,
                  height > 0
            else { continue }

            let ext = fmt["ext"] as? String ?? ""
            let isPreferred = vcodec.hasPrefix("avc1") || ext == "mp4"
            let filesize = fmt["filesize"] as? Int64 ?? fmt["filesize_approx"] as? Int64

            if let existing = byHeight[height] {
                if !existing.isPreferredCodec && isPreferred || (existing.isPreferredCodec == isPreferred && existing.filesize == nil && filesize != nil) {
                    byHeight[height] = HeightCandidate(filesize: filesize ?? existing.filesize, isPreferredCodec: isPreferred)
                }
            } else {
                byHeight[height] = HeightCandidate(filesize: filesize, isPreferredCodec: isPreferred)
            }
        }

        // Always add MP3 option first
        var results: [DownloadFormat] = [
            DownloadFormat(
                id: "bestaudio/best",
                label: String(localized: "MP3 (audio only)"),
                isAudioOnly: true,
                fileSize: nil
            ),
        ]

        for height in byHeight.keys.sorted(by: >) {
            let candidate = byHeight[height]
            let selector = "bestvideo[height<=\(height)][vcodec^=avc1]+bestaudio[acodec^=mp4a]/bestvideo[height<=\(height)][ext=mp4]+bestaudio[ext=m4a]/best[height<=\(height)][ext=mp4]/best[height<=\(height)]"
            results.append(DownloadFormat(
                id: selector,
                label: "\(height)p (MP4)",
                isAudioOnly: false,
                fileSize: candidate?.filesize
            ))
        }

        return results
    }

    // MARK: - Transcript (for on-device AI)

    /// Fetches the video's transcript as plain text (auto-captions included) via
    /// yt-dlp, for on-device AI features like the video summary. Returns nil when
    /// the video has no captions or yt-dlp is unavailable.
    func fetchTranscript(videoId: String) async -> String? {
        guard let ytdlpPath, let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return nil }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kaset-transcript-\(videoId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let env = Self.configuredEnvironment(customFfmpegPath: SettingsManager.shared.customFfmpegPath)

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            proc.environment = env
            proc.arguments = [
                "--skip-download",
                "--write-auto-subs", "--write-subs",
                "--sub-langs", "\(lang),\(lang).*,en,en.*",
                "--sub-format", "vtt",
                "--socket-timeout", "20",
                "-o", "\(tmpDir.path)/%(id)s.%(ext)s",
                url.absoluteString,
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            proc.terminationHandler = { _ in
                let text = Self.transcriptText(fromDir: tmpDir)
                try? FileManager.default.removeItem(at: tmpDir)
                continuation.resume(returning: text)
            }
            do {
                try proc.run()
            } catch {
                try? FileManager.default.removeItem(at: tmpDir)
                continuation.resume(returning: nil)
            }
        }
    }

    /// Parses the first `.vtt` file in `dir` into deduplicated plain text.
    /// yt-dlp auto-captions roll and repeat lines, so consecutive duplicates and
    /// inline timing tags are stripped.
    private nonisolated static func transcriptText(fromDir dir: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              let vtt = files.first(where: { $0.pathExtension.lowercased() == "vtt" }),
              let raw = try? String(contentsOf: vtt, encoding: .utf8)
        else {
            return nil
        }

        var lines: [String] = []
        var last = ""
        for rawLine in raw.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "WEBVTT" || line.contains("-->")
                || line.hasPrefix("Kind:") || line.hasPrefix("Language:") || line.hasPrefix("NOTE")
            {
                continue
            }
            let clean = line
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean == last {
                continue
            }
            lines.append(clean)
            last = clean
        }

        let text = lines.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    // MARK: - Download

    enum DownloadState: Sendable {
        case idle
        case preparing
        case downloading(progress: Double, speed: String)
        case completed(filename: String)
        case failed(String)
    }

    /// Starts a download and returns a stream of state updates.
    func download(
        videoId: String,
        videoTitle: String = "",
        format: DownloadFormat,
        downloadSubtitles: Bool = false,
        onUpdate: @escaping @Sendable (DownloadState) -> Void
    ) {
        onUpdate(.preparing)
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else {
            onUpdate(.failed(String(localized: "Invalid video URL")))
            return
        }

        guard let ytdlpPath else {
            onUpdate(.failed(String(localized: "yt-dlp not found.")))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlpPath)
        proc.environment = Self.configuredEnvironment(customFfmpegPath: SettingsManager.shared.customFfmpegPath)

        let targetDir = format.isAudioOnly
            ? DownloadManager.shared.musicDirectory
            : DownloadManager.shared.videosDirectory

        var args = [
            "--no-playlist",
            "--no-mtime",
            "-o", "\(targetDir.path)/%(title)s [%(id)s].%(ext)s",
        ]

        if let ffmpeg = DownloadManager.shared.ffmpegPath {
            args.append(contentsOf: ["--ffmpeg-location", ffmpeg])
        }

        if format.isAudioOnly {
            args.append(contentsOf: [
                "-x",
                "--audio-format", "mp3",
                "--audio-quality", "0",
                "--embed-thumbnail",
            ])
        } else {
            args.append(contentsOf: [
                "-f", format.id,
                "--merge-output-format", "mp4",
                "--remux-video", "mp4",
            ])
        }

        if downloadSubtitles {
            // Real + auto-generated captions in the user's language and English,
            // written as .srt next to the file; embedded into the container for
            // video downloads (mp3 has no subtitle track).
            let lang = Locale.current.language.languageCode?.identifier ?? "en"
            args.append(contentsOf: [
                "--write-subs", "--write-auto-subs",
                "--sub-langs", "\(lang),\(lang).*,en,en.*",
                "--convert-subs", "srt",
            ])
            if !format.isAudioOnly {
                args.append("--embed-subs")
            }
        }

        args.append(url.absoluteString)
        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Parse progress from yt-dlp output
        nonisolated(unsafe) var lastFilename = ""
        let onUpdateSendable = onUpdate
        let resolvedTitle = videoTitle
        let isAudioOnly = format.isAudioOnly

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !chunk.isEmpty else { return }

            let lines = chunk.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("[download] Destination:") {
                    lastFilename = trimmed
                        .replacingOccurrences(of: "[download] Destination: ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.contains("[ExtractAudio] Destination:") {
                    lastFilename = trimmed
                        .replacingOccurrences(of: "[ExtractAudio] Destination: ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.contains("[Merger] Merging formats into") {
                    lastFilename = trimmed
                        .replacingOccurrences(of: "[Merger] Merging formats into ", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\"", with: "")
                } else if trimmed.contains("[VideoRemuxer] Remuxing video from"),
                          let destinationPart = trimmed.components(separatedBy: " to ").last
                {
                    lastFilename = destinationPart
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
                } else if trimmed.contains("%") {
                    let percent = Self.parsePercent(trimmed)
                    let speed = Self.parseSpeed(trimmed)
                    onUpdateSendable(.downloading(progress: percent, speed: speed))
                }
            }
        }

        proc.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            var name = lastFilename.components(separatedBy: "/").last ?? lastFilename
            let expectedExt = isAudioOnly ? "mp3" : "mp4"
            if let matchingFile = (try? FileManager.default.contentsOfDirectory(atPath: targetDir.path))?
                .first(where: { $0.contains("[\(videoId)]") && $0.hasSuffix(".\(expectedExt)") })
            {
                name = matchingFile
            }
            if process.terminationStatus == 0 {
                Task { @MainActor in
                    if !name.isEmpty {
                        DownloadManager.shared.registerCompletedDownload(
                            videoId: videoId,
                            title: resolvedTitle.isEmpty ? name : resolvedTitle,
                            filename: name,
                            isAudioOnly: isAudioOnly
                        )
                    }
                    onUpdateSendable(.completed(filename: name))
                }
            } else {
                onUpdateSendable(.failed(String(localized: "Download failed. Is yt-dlp installed? Try: brew install yt-dlp")))
            }
        }

        do {
            try proc.run()
        } catch {
            onUpdate(.failed(error.localizedDescription))
        }
    }

    /// Cancels the current download by killing yt-dlp.
    func cancelDownload() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["killall", "yt-dlp"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    // MARK: - Helpers

    private nonisolated static func parsePercent(_ line: String) -> Double {
        // "[download]  45.3% of ~50MiB at ..."
        guard let range = line.range(of: #"\d+\.?\d*%"#, options: .regularExpression) else {
            return 0
        }
        let str = String(line[range]).replacingOccurrences(of: "%", with: "")
        return (Double(str) ?? 0) / 100.0
    }

    private nonisolated static func parseSpeed(_ line: String) -> String {
        // "... at 2.3MiB/s ..."
        guard let range = line.range(of: #"at\s+\S+"#, options: .regularExpression) else {
            return ""
        }
        return String(line[range])
    }
}

import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import os

// MARK: - HLSSegment

struct HLSSegment: Sendable, Equatable {
    let index: Int
    let url: URL
    let startTime: TimeInterval
    let duration: TimeInterval
}

// MARK: - HLSResolvedPlaylist

struct HLSResolvedPlaylist: Sendable {
    let audioPlaylistURL: URL
    let segments: [HLSSegment]
    let totalDuration: TimeInterval
}

// MARK: - HLSPlaylistParser

enum HLSPlaylistParser {
    /// Extracts the best audio-only media playlist URL from an HLS multivariant manifest.
    /// Prefers `itag/234` (128kbps AAC-LC) when available, falling back to the last `TYPE=AUDIO` entry.
    static func parseMultivariantAudioPlaylistURL(from multivariantText: String) -> URL? {
        let lines = multivariantText.components(separatedBy: .newlines)
        let audioLines = lines.filter { line in
            line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO")
        }
        guard !audioLines.isEmpty else { return nil }

        let preferredLine = audioLines.first(where: { $0.contains("/itag/234/") || $0.contains("itag=234") })
            ?? audioLines.last

        guard let line = preferredLine,
              let uriRange = line.range(of: "URI=\"")
        else { return nil }

        let afterQuote = line[uriRange.upperBound...]
        guard let endQuote = afterQuote.firstIndex(of: "\"") else { return nil }
        let uriString = String(afterQuote[..<endQuote])
        return URL(string: uriString)
    }

    /// Parses an HLS media playlist into timed segments.
    /// Returns `nil` if the playlist uses fMP4 (`#EXT-X-MAP`) or encryption (`#EXT-X-KEY`),
    /// allowing callers to fall back to `AVPlayer`.
    static func parseMediaPlaylistSegments(from playlistText: String) -> [HLSSegment]? {
        let lines = playlistText.components(separatedBy: .newlines)
        var segments: [HLSSegment] = []
        var pendingDuration: TimeInterval?
        var cumulativeStart: TimeInterval = 0

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") || line.hasPrefix("#EXT-X-KEY:") {
                return nil
            }

            if line.hasPrefix("#EXTINF:") {
                let valuePart = line.dropFirst("#EXTINF:".count)
                let numberString = valuePart.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                if let duration = TimeInterval(numberString.trimmingCharacters(in: .whitespaces)),
                   duration.isFinite, duration > 0
                {
                    pendingDuration = duration
                }
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            if let url = URL(string: line),
               let scheme = url.scheme?.lowercased(),
               scheme == "https" || scheme == "http"
            {
                let duration = pendingDuration ?? 0
                segments.append(HLSSegment(
                    index: segments.count,
                    url: url,
                    startTime: cumulativeStart,
                    duration: duration
                ))
                cumulativeStart += duration
                pendingDuration = nil
            }
        }

        return segments.isEmpty ? nil : segments
    }
}

// MARK: - HLSManifestCache

actor HLSManifestCache {
    static let shared = HLSManifestCache()

    private struct CachedEntry {
        let playlist: HLSResolvedPlaylist
        let cachedAt: Date
    }

    private let session: URLSession
    private var cache: [URL: CachedEntry] = [:]
    private var inFlight: [URL: Task<HLSResolvedPlaylist?, Never>] = [:]
    private let cacheTTL: TimeInterval = 2.5 * 3600

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = APISessionConfiguration.make()
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    var sharedSession: URLSession {
        self.session
    }

    func prewarmConnection() async {
        guard let url = URL(string: "https://manifest.googlevideo.com/generate_204") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 3.0
        _ = try? await self.session.data(for: request)
    }

    func prewarm(multivariantURL: URL) {
        if let existing = self.cache[multivariantURL], Date().timeIntervalSince(existing.cachedAt) < self.cacheTTL {
            return
        }
        guard self.inFlight[multivariantURL] == nil else { return }
        Task {
            _ = await self.resolvePlaylist(from: multivariantURL)
        }
    }

    func resolvePlaylist(from manifestURL: URL) async -> HLSResolvedPlaylist? {
        if let cached = self.cache[multivariantURLKey(manifestURL)],
           Date().timeIntervalSince(cached.cachedAt) < self.cacheTTL
        {
            return cached.playlist
        }
        if let task = self.inFlight[manifestURL] {
            return await task.value
        }

        let task = Task<HLSResolvedPlaylist?, Never> { [session = self.session] in
            guard let multivariantText = await Self.fetchText(from: manifestURL, session: session) else {
                return nil
            }

            let audioPlaylistURL: URL
            let mediaText: String
            if let extractedAudioURL = HLSPlaylistParser.parseMultivariantAudioPlaylistURL(from: multivariantText) {
                audioPlaylistURL = extractedAudioURL
                guard let fetchedMedia = await Self.fetchText(from: extractedAudioURL, session: session) else {
                    return nil
                }
                mediaText = fetchedMedia
            } else if multivariantText.contains("#EXTINF:") {
                audioPlaylistURL = manifestURL
                mediaText = multivariantText
            } else {
                return nil
            }

            guard let segments = HLSPlaylistParser.parseMediaPlaylistSegments(from: mediaText) else {
                return nil
            }
            let totalDuration = segments.reduce(0) { $0 + $1.duration }
            return HLSResolvedPlaylist(
                audioPlaylistURL: audioPlaylistURL,
                segments: segments,
                totalDuration: totalDuration
            )
        }

        self.inFlight[manifestURL] = task
        let resolved = await task.value
        self.inFlight.removeValue(forKey: manifestURL)
        if let resolved {
            self.cache[self.multivariantURLKey(manifestURL)] = CachedEntry(playlist: resolved, cachedAt: Date())
        }
        return resolved
    }

    func invalidate(multivariantURL: URL) {
        self.cache.removeValue(forKey: multivariantURL)
    }

    private func multivariantURLKey(_ url: URL) -> URL {
        url
    }

    private static func fetchText(from url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 5.0
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - ADTSAudioStreamParser

/// Streams raw ADTS AAC bytes (including ID3v2 headers emitted by Apple HLS packed audio)
/// through AudioToolbox's `AudioFileStream` and emits sample-accurate `CMSampleBuffer`s.
final class ADTSAudioStreamParser {
    private var streamID: AudioFileStreamID?
    private var asbd: AudioStreamBasicDescription?
    private var magicCookie: Data?
    private var formatDescription: CMAudioFormatDescription?
    private var sampleOffset: Int64
    private let onSampleBuffer: (CMSampleBuffer, Int, Double) -> Void

    private(set) var parsedPacketsCount = 0

    init(
        initialSampleOffset: Int64,
        onSampleBuffer: @escaping (CMSampleBuffer, Int, Double) -> Void
    ) {
        self.sampleOffset = initialSampleOffset
        self.onSampleBuffer = onSampleBuffer

        let contextPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(
            contextPtr,
            { context, streamID, propertyID, _ in
                let parser = Unmanaged<ADTSAudioStreamParser>.fromOpaque(context).takeUnretainedValue()
                parser.handlePropertyChange(streamID: streamID, propertyID: propertyID)
            },
            { context, numberBytes, numberPackets, inputData, packetDescriptions in
                let parser = Unmanaged<ADTSAudioStreamParser>.fromOpaque(context).takeUnretainedValue()
                parser.handlePackets(
                    numberBytes: numberBytes,
                    numberPackets: numberPackets,
                    inputData: inputData,
                    packetDescriptions: packetDescriptions
                )
            },
            kAudioFileAAC_ADTSType,
            &self.streamID
        )
    }

    deinit {
        if let streamID = self.streamID {
            AudioFileStreamClose(streamID)
        }
    }

    var currentSampleRate: Double {
        self.asbd?.mSampleRate ?? 44100
    }

    var currentSampleOffset: Int64 {
        self.sampleOffset
    }

    @discardableResult
    func parse(_ data: Data) -> OSStatus {
        guard let streamID = self.streamID, !data.isEmpty else { return noErr }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return noErr }
            return AudioFileStreamParseBytes(streamID, UInt32(data.count), baseAddress, [])
        }
    }

    private func handlePropertyChange(streamID: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
        if propertyID == kAudioFileStreamProperty_DataFormat {
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioFileStreamGetProperty(streamID, propertyID, &size, &description) == noErr {
                self.asbd = description
                self.formatDescription = nil
            }
        } else if propertyID == kAudioFileStreamProperty_MagicCookieData {
            var size: UInt32 = 0
            var writable: DarwinBoolean = false
            if AudioFileStreamGetPropertyInfo(streamID, propertyID, &size, &writable) == noErr, size > 0 {
                var buffer = [UInt8](repeating: 0, count: Int(size))
                if AudioFileStreamGetProperty(streamID, propertyID, &size, &buffer) == noErr {
                    self.magicCookie = Data(buffer)
                    self.formatDescription = nil
                }
            }
        }
    }

    private func handlePackets(
        numberBytes: UInt32,
        numberPackets: UInt32,
        inputData: UnsafeRawPointer,
        packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard numberBytes > 0, numberPackets > 0, let packetDescriptions, var asbd = self.asbd else {
            return
        }

        if self.formatDescription == nil {
            var createdFormat: CMAudioFormatDescription?
            let status: OSStatus = if let cookie = self.magicCookie, !cookie.isEmpty {
                cookie.withUnsafeBytes { rawCookie in
                    CMAudioFormatDescriptionCreate(
                        allocator: kCFAllocatorDefault,
                        asbd: &asbd,
                        layoutSize: 0,
                        layout: nil,
                        magicCookieSize: cookie.count,
                        magicCookie: rawCookie.baseAddress,
                        extensions: nil,
                        formatDescriptionOut: &createdFormat
                    )
                }
            } else {
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &createdFormat
                )
            }
            guard status == noErr else { return }
            self.formatDescription = createdFormat
        }

        guard let formatDescription = self.formatDescription else { return }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: Int(numberBytes),
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: Int(numberBytes),
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else { return }

        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: inputData,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: Int(numberBytes)
        )
        guard copyStatus == noErr else { return }

        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100
        let framesPerPacket = asbd.mFramesPerPacket > 0 ? Int64(asbd.mFramesPerPacket) : 1024
        let pts = CMTime(value: self.sampleOffset, timescale: Int32(sampleRate))

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(numberPackets),
            presentationTimeStamp: pts,
            packetDescriptions: packetDescriptions,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return }

        self.parsedPacketsCount += Int(numberPackets)
        self.sampleOffset += Int64(numberPackets) * framesPerPacket
        let endSeconds = Double(self.sampleOffset) / sampleRate
        self.onSampleBuffer(sampleBuffer, Int(numberPackets), endSeconds)
    }
}

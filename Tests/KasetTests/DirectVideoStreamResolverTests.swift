import Foundation
import Testing
@testable import KasetPlus

@Suite("DirectVideoStreamResolver Tests")
@MainActor
struct DirectVideoStreamResolverTests {
    @Test("DirectVideoStreamResolver and DirectStreamResolver clear and invalidate cache")
    func clearAndInvalidateCache() {
        let videoResolver = DirectVideoStreamResolver.shared
        videoResolver.clearCache()
        videoResolver.invalidate(videoId: "missing-id")

        let audioResolver = DirectStreamResolver.shared
        audioResolver.clearCache()
        audioResolver.invalidate(videoId: "missing-id")
        #expect(audioResolver.cachedStreamURL(for: "missing-id") == nil)
        #expect(videoResolver.cachedStreamURL(for: "missing-id") == nil)
    }

    @Test("InnerTubeStreamResolver extracts HLS manifest URL, TTL, and visitorData")
    func parsesHLSManifestResponse() throws {
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "responseContext": ["visitorData": "visitor-123"],
            "streamingData": [
                "expiresInSeconds": "7200",
                "hlsManifestUrl": "https://manifest.googlevideo.com/api/manifest/hls_variant/index.m3u8",
                "formats": [
                    ["itag": 18, "url": "https://example.com/fallback.mp4", "mimeType": "video/mp4", "bitrate": 500_000],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let result = InnerTubeStreamResolver.parsePlayerResponse(data)

        guard case let .stream(url, ttl, visitorData) = result else {
            Issue.record("Expected .stream result, got \(result)")
            return
        }
        #expect(url.absoluteString == "https://manifest.googlevideo.com/api/manifest/hls_variant/index.m3u8")
        #expect(ttl == 6900)
        #expect(visitorData == "visitor-123")
    }

    @Test("InnerTubeStreamResolver falls back to highest-bitrate muxed MP4 when HLS is absent")
    func fallsBackToHighestBitrateMuxedMP4() throws {
        let payload: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "streamingData": [
                "expiresInSeconds": 3600,
                "formats": [
                    ["itag": 18, "url": "https://example.com/360p.mp4", "mimeType": "video/mp4; codecs=\"avc1.42001E\"", "bitrate": 400_000],
                    ["itag": 22, "url": "https://example.com/720p.mp4", "mimeType": "video/mp4; codecs=\"avc1.64001F\"", "bitrate": 1_800_000],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let result = InnerTubeStreamResolver.parsePlayerResponse(data)

        guard case let .stream(url, ttl, _) = result else {
            Issue.record("Expected .stream result, got \(result)")
            return
        }
        #expect(url.absoluteString == "https://example.com/720p.mp4")
        #expect(ttl == 3300)
    }

    @Test("InnerTubeStreamResolver returns loginRequired and unplayable for non-OK statuses")
    func parsesLoginRequiredAndUnplayable() throws {
        let loginPayload: [String: Any] = [
            "playabilityStatus": ["status": "LOGIN_REQUIRED"],
            "responseContext": ["visitorData": "fresh-visitor"],
        ]
        let loginResult = try InnerTubeStreamResolver.parsePlayerResponse(JSONSerialization.data(withJSONObject: loginPayload))
        guard case let .loginRequired(visitorData) = loginResult else {
            Issue.record("Expected .loginRequired, got \(loginResult)")
            return
        }
        #expect(visitorData == "fresh-visitor")

        let unplayablePayload: [String: Any] = [
            "playabilityStatus": ["status": "UNPLAYABLE"],
        ]
        let unplayableResult = try InnerTubeStreamResolver.parsePlayerResponse(JSONSerialization.data(withJSONObject: unplayablePayload))
        guard case .unplayable = unplayableResult else {
            Issue.record("Expected .unplayable, got \(unplayableResult)")
            return
        }
    }

    @Test("NativeVideoPlayer volume and speed clamps")
    func nativeVideoPlayerClamping() {
        let player = NativeVideoPlayer.shared
        player.setVolume(1.5)
        #expect(player.volume == 1.0)

        player.setVolume(-0.5)
        #expect(player.volume == 0.0)

        player.playbackSpeed = 3.0
        #expect(player.playbackSpeed == 3.0) // clamped when setting rate on player
    }

    @Test("NativeVideoPlayer stop resets state")
    func nativeVideoPlayerStop() {
        let player = NativeVideoPlayer.shared
        player.stop()
        #expect(!player.isPlaying)
        #expect(!player.isLoading)
        #expect(player.currentVideoId == nil)
        #expect(player.currentURL == nil)
    }

    @Test("HLSPlaylistParser prefers itag 234 audio playlist from multivariant manifest")
    func parsesMultivariantAudioPlaylistPreferringItag234() {
        let multivariant = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a1",NAME="low",URI="https://manifest.googlevideo.com/api/manifest/hls_playlist/id/abc/itag/233/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a2",NAME="high",URI="https://manifest.googlevideo.com/api/manifest/hls_playlist/id/abc/itag/234/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=500000,AUDIO="a2"
        https://manifest.googlevideo.com/api/manifest/hls_playlist/id/abc/itag/134/index.m3u8
        """

        let url = HLSPlaylistParser.parseMultivariantAudioPlaylistURL(from: multivariant)
        #expect(url?.absoluteString == "https://manifest.googlevideo.com/api/manifest/hls_playlist/id/abc/itag/234/index.m3u8")
    }

    @Test("HLSPlaylistParser accumulates segment timings and rejects fMP4/encrypted playlists")
    func parsesMediaPlaylistSegmentsAndRejectsFmp4() {
        let adtsPlaylist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:7
        #EXTINF:6.0,
        https://rr1.googlevideo.com/seg/0
        #EXTINF:4.5,
        https://rr1.googlevideo.com/seg/1
        #EXT-X-ENDLIST
        """

        let segments = HLSPlaylistParser.parseMediaPlaylistSegments(from: adtsPlaylist)
        #expect(segments?.count == 2)
        #expect(segments?[0].startTime == 0)
        #expect(segments?[0].duration == 6.0)
        #expect(segments?[1].startTime == 6.0)
        #expect(segments?[1].duration == 4.5)

        let fmp4Playlist = """
        #EXTM3U
        #EXT-X-MAP:URI="https://rr1.googlevideo.com/init.mp4"
        #EXTINF:6.0,
        https://rr1.googlevideo.com/seg/0.m4s
        """
        #expect(HLSPlaylistParser.parseMediaPlaylistSegments(from: fmp4Playlist) == nil)
    }

    @Test("HLSAudioSamplePlayer identifies HLS URLs vs local file and progressive MP4 URLs")
    func identifiesHLSURLs() throws {
        #expect(try HLSAudioSamplePlayer.isHLSURL(#require(URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/index.m3u8"))))
        #expect(try HLSAudioSamplePlayer.isHLSURL(#require(URL(string: "https://example.com/hls_playlist/audio"))))
        #expect(try !HLSAudioSamplePlayer.isHLSURL(#require(URL(string: "https://rr1.googlevideo.com/videoplayback?mime=video/mp4"))))
        #expect(!HLSAudioSamplePlayer.isHLSURL(URL(fileURLWithPath: "/tmp/song.m4a")))
    }

    @Test("HLSMultivariantManifestLoader strips vp09 and orders avc1/hvc1 variants highest-bitrate first")
    func rewritesMultivariantPlaylistHighestBitrateFirst() throws {
        let multivariant = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="234",NAME="main",URI="https://manifest.googlevideo.com/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=300694,CODECS="avc1.4D4015,mp4a.40.5",RESOLUTION=426x240,AUDIO="234"
        https://manifest.googlevideo.com/240p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4688074,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="234"
        https://manifest.googlevideo.com/1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=19117677,CODECS="vp09.00.50.08,mp4a.40.2",RESOLUTION=3840x2160,AUDIO="234"
        https://manifest.googlevideo.com/2160p_vp9.m3u8
        """

        let rewritten = try #require(HLSMultivariantManifestLoader.rewriteMultivariantPlaylist(multivariant))
        #expect(!rewritten.contains("vp09"))
        let first1080 = try #require(rewritten.range(of: "1920x1080"))
        let second240 = try #require(rewritten.range(of: "426x240"))
        #expect(first1080.lowerBound < second240.lowerBound)
    }

    @Test("HLSMultivariantManifestLoader filters variants to requested quality level and extracts available levels")
    func filtersMultivariantPlaylistForRequestedQuality() throws {
        let multivariant = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="234",NAME="main",URI="https://manifest.googlevideo.com/audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=300694,CODECS="avc1.4D4015,mp4a.40.5",RESOLUTION=426x240,AUDIO="234"
        https://manifest.googlevideo.com/240p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1500000,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=1280x720,AUDIO="234"
        https://manifest.googlevideo.com/720p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6200000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="234"
        https://manifest.googlevideo.com/1080p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=19117677,CODECS="vp09.00.50.08,mp4a.40.2",RESOLUTION=3840x2160,AUDIO="234"
        https://manifest.googlevideo.com/2160p_vp9.m3u8
        """

        #expect(HLSMultivariantManifestLoader.availableQualityLevels(in: multivariant) == ["hd1080", "hd720", "small"])

        let pinned1080 = try #require(HLSMultivariantManifestLoader.rewriteMultivariantPlaylist(multivariant, preferredQualityLevel: "hd1080"))
        #expect(pinned1080.contains("1920x1080"))
        #expect(!pinned1080.contains("1280x720"))
        #expect(!pinned1080.contains("426x240"))

        let pinned240 = try #require(HLSMultivariantManifestLoader.rewriteMultivariantPlaylist(multivariant, preferredQualityLevel: "small"))
        #expect(pinned240.contains("426x240"))
        #expect(!pinned240.contains("1920x1080"))
        #expect(!pinned240.contains("1280x720"))

        // Unavailable higher tier falls back to highest available tier (1080p)
        let fallbackFrom4K = try #require(HLSMultivariantManifestLoader.rewriteMultivariantPlaylist(multivariant, preferredQualityLevel: "hd2160"))
        #expect(fallbackFrom4K.contains("1920x1080"))
        #expect(!fallbackFrom4K.contains("1280x720"))
    }

    @Test("HLSMultivariantManifestLoader maps landscape, portrait, and ultrawide resolutions to YouTube quality tiers")
    func mapsResolutionsToQualityLevels() {
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=3840x2160") == "hd2160")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=2560x1440") == "hd1440")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080") == "hd1080")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1080x1920") == "hd1080")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x800") == "hd1080")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1280x720") == "hd720")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=854x480") == "large")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=640x360") == "medium")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=426x240") == "small")
        #expect(HLSMultivariantManifestLoader.qualityLevel(forStreamInfLine: "#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=256x144") == "tiny")
    }
}

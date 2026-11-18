import Foundation
import os

// MARK: - SponsorBlock & Return YouTube Dislikes

extension YouTubePlayerService {
    // MARK: - SponsorBlock

    /// Clears SponsorBlock segments when a new video starts loading.
    func setSponsorSegments(_ segments: [SponsorSegment], videoId: String) {
        if self.currentVideo?.videoId == videoId {
            self.pendingSponsorSegments = nil
            self.sponsorSegments = segments
        } else {
            // The watch page can finish its SponsorBlock request before the
            // first STATE_UPDATE adopts a new SPA video in native state.
            self.pendingSponsorSegments = (videoId, segments)
        }
    }

    /// Surfaces an automatic SponsorBlock skip in the native player chrome.
    func handleSponsorBlockSkip(
        start: Double,
        end: Double,
        category: String,
        videoId: String
    ) {
        guard start.isFinite,
              end.isFinite,
              start >= 0,
              end > start,
              !category.isEmpty
        else { return }

        let segment = SponsorSegment(start: start, end: end, category: category)
        guard self.currentVideo?.videoId == videoId else {
            self.pendingSponsorSkip = (videoId, segment)
            return
        }
        self.presentSponsorBlockSkip(segment)
    }

    func presentSponsorBlockSkip(_ segment: SponsorSegment) {
        let notice = SponsorSkipNotice(segment: segment)
        self.setSponsorSkipNotice(notice)
        self.sponsorSkipNoticeDismissTask?.cancel()
        self.sponsorSkipNoticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard self?.sponsorSkipNotice?.id == notice.id else { return }
            self?.setSponsorSkipNotice(nil)
            self?.sponsorSkipNoticeDismissTask = nil
        }
    }

    /// Returns to the beginning of the last skipped segment. The WebView seek
    /// is tagged as explicit user intent so SponsorBlock lets it play through.
    func undoSponsorBlockSkip() {
        guard let notice = self.sponsorSkipNotice else { return }
        self.dismissSponsorBlockSkipNotice()
        self.seek(to: notice.segment.start)
    }

    func dismissSponsorBlockSkipNotice() {
        self.sponsorSkipNoticeDismissTask?.cancel()
        self.sponsorSkipNoticeDismissTask = nil
        self.setSponsorSkipNotice(nil)
    }

    func applyPendingSponsorBlockState(for videoId: String) {
        if let pendingSponsorSegments, pendingSponsorSegments.videoId == videoId {
            self.sponsorSegments = pendingSponsorSegments.segments
        }
        self.pendingSponsorSegments = nil

        if let pendingSponsorSkip, pendingSponsorSkip.videoId == videoId {
            self.presentSponsorBlockSkip(pendingSponsorSkip.segment)
        }
        self.pendingSponsorSkip = nil
    }

    // MARK: - Return YouTube Dislikes

    /// Formats an integer count to a compact string (e.g. 12345 → "12.3K").
    static func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return String(format: m >= 100 ? "%.0fM" : (m >= 10 ? "%.1fM" : "%.2fM"), m)
        }
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: k >= 100 ? "%.0fK" : (k >= 10 ? "%.1fK" : "%.2fK"), k)
        }
        return "\(count)"
    }

    func fetchReturnYouTubeDislikes(videoId: String) async {
        guard SettingsManager.shared.returnYouTubeDislikesEnabled,
              videoId != self.rydFetchVideoId
        else { return }

        self.rydFetchVideoId = videoId

        guard var components = URLComponents(string: "https://returnyoutubedislikeapi.com/votes") else {
            return
        }
        components.queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        guard let url = components.url else { return }

        // The default 60s timeout is far too patient for an optional badge, and
        // a network-level blocklist (this API is on several "tracker" lists, as
        // is SponsorBlock's) makes the request fail or hang rather than 404.
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            self.setReturnYouTubeDislikes(
                dislikes: json["dislikes"] as? Int,
                likes: json["likes"] as? Int
            )
        } catch {
            self.setReturnYouTubeDislikes(dislikes: nil, likes: nil)
            // Let the next trigger try again: the old code marked the video as
            // fetched before the request, so one failure killed the count for
            // the rest of that video. And say why — a silently missing dislike
            // count is indistinguishable from "this video has no dislikes".
            self.rydFetchVideoId = nil
            self.logger.error(
                """
                Return YouTube Dislike lookup failed for \(videoId): \(error.localizedDescription). \
                If this persists, check whether returnyoutubedislikeapi.com is blocked by a \
                network-level ad/tracker filter.
                """
            )
        }
    }
}

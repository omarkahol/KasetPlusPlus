import Foundation
import Observation
import os

// MARK: - VideoSummaryCoordinator

/// Coordinates on-device Foundation Models summarization for a YouTube video.
@MainActor
@Observable
final class VideoSummaryCoordinator {
    private(set) var tldr: String?
    private(set) var keyPoints: [String] = []
    private(set) var audience: String?
    private(set) var isLoading = false
    private(set) var error: String?

    private let logger = DiagnosticsLogger.ai
    private var summaryTask: Task<Void, Never>?

    /// Whether on-device summarization is usable right now (macOS 26 + a ready model).
    var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return FoundationModelsService.shared.isAvailable
    }

    /// Fetches the transcript and generates an on-device summary for the video.
    func summarize(videoId: String, title: String) {
        self.error = nil
        self.isLoading = true
        self.summaryTask?.cancel()
        self.summaryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            guard let transcript = await YouTubeDownloadService.shared.fetchTranscript(videoId: videoId),
                  transcript.count > 40
            else {
                self.error = String(localized: "No captions available to summarize this video.")
                return
            }
            guard #available(macOS 26.0, *) else {
                self.error = String(localized: "AI summary needs macOS 26.")
                return
            }
            do {
                let summary = try await FoundationModelsService.shared.summarizeVideo(
                    title: title,
                    transcript: transcript
                )
                self.tldr = summary.tldr
                self.keyPoints = summary.keyPoints
                self.audience = summary.audience
            } catch is CancellationError {
                // Cancelled by navigation or a newer request.
            } catch {
                self.logger.debug("Video summarization failed: \(error.localizedDescription)")
                self.error = String(localized: "Couldn't summarize this video.")
            }
        }
    }

    /// Clears any cached summary state and cancels in-flight work.
    func reset() {
        self.summaryTask?.cancel()
        self.summaryTask = nil
        self.tldr = nil
        self.keyPoints = []
        self.audience = nil
        self.error = nil
        self.isLoading = false
    }
}

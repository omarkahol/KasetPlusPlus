import Foundation
import Observation
import os

// MARK: - LyricsSearchService

/// Searches LRCLib for lyrics matching a YouTube video query and manages search state.
@MainActor
@Observable
final class LyricsSearchService {
    private(set) var results: [LRCLibModel] = []
    private(set) var isLoading = false

    private let session: URLSession
    private let logger = DiagnosticsLogger.api
    private var searchTask: Task<Void, Never>?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Clears current results and searches LRCLib for the given query.
    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !self.isLoading else { return }

        self.results = []
        self.isLoading = true

        guard var components = URLComponents(string: "https://lrclib.net/api/search") else {
            self.isLoading = false
            return
        }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components.url else {
            self.isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("KasetPlus/1.0", forHTTPHeaderField: "User-Agent")

        self.searchTask?.cancel()
        self.searchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false }
            do {
                let (data, response) = try await self.session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200
                else {
                    return
                }
                let decoded = try JSONDecoder().decode([LRCLibModel].self, from: data)
                self.results = decoded.filter {
                    ($0.syncedLyrics != nil || $0.plainLyrics != nil) &&
                        ($0.instrumental == false || $0.instrumental == nil)
                }
            } catch is CancellationError {
                // Cancelled by a newer search or view dismissal.
            } catch {
                self.logger.debug("LRCLib search failed: \(error.localizedDescription)")
            }
        }
    }

    /// Resets results and cancels any in-flight search.
    func reset() {
        self.searchTask?.cancel()
        self.searchTask = nil
        self.results = []
        self.isLoading = false
    }
}

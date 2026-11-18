import Foundation

/// Centralized DeArrow title cache. Fetches community-submitted accurate
/// titles from the DeArrow API and makes them available to any view.
///
/// Views show original titles immediately; the cache fetches in the
/// background and `@Observable` triggers live UI updates when results
/// arrive.
@MainActor
@Observable
final class DearrowCache {
    static let shared = DearrowCache()

    private static let defaultMaxEntries = 500
    private static let maxConcurrentFetches = 4

    /// DeArrow title keyed by videoId.
    private var dearrowTitles: [String: String] = [:]
    /// Original YouTube title, stored so the toggle can restore it.
    private var originalTitles: [String: String] = [:]
    /// Insertion/access order for bounded LRU eviction.
    private var accessOrder: [String] = []
    /// Video IDs currently being fetched (dedup).
    private var inFlight: Set<String> = []
    private let maxEntries: Int

    private init(maxEntries: Int = DearrowCache.defaultMaxEntries) {
        self.maxEntries = max(1, maxEntries)
    }

    static func makeTestInstance(maxEntries: Int = 500) -> DearrowCache {
        DearrowCache(maxEntries: maxEntries)
    }

    // MARK: - Public API

    /// Returns the DeArrow title if available, otherwise the original.
    func displayTitle(for videoId: String, original: String) -> String {
        // Store original for toggle support
        if self.originalTitles[videoId] == nil {
            self.originalTitles[videoId] = original
            self.recordAccess(for: videoId)
        }
        return self.dearrowTitles[videoId] ?? original
    }

    /// Whether a DeArrow replacement exists for this video.
    func hasDearrow(for videoId: String) -> Bool {
        self.dearrowTitles[videoId] != nil
    }

    /// The original YouTube title (for toggle back).
    func originalTitle(for videoId: String) -> String? {
        self.originalTitles[videoId]
    }

    var cachedEntryCount: Int {
        self.accessOrder.count
    }

    /// Batch-fetch DeArrow data for multiple videos with bounded concurrency.
    func fetchBatch(for videoIds: [String]) {
        guard SettingsManager.shared.dearrowEnabled else { return }
        let candidates = videoIds.filter {
            self.dearrowTitles[$0] == nil && !self.inFlight.contains($0)
        }
        guard !candidates.isEmpty else { return }
        for id in candidates {
            self.inFlight.insert(id)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = candidates.makeIterator()
                for _ in 0 ..< Self.maxConcurrentFetches {
                    if let nextId = iterator.next() {
                        group.addTask {
                            await self._fetch(videoId: nextId)
                            await MainActor.run {
                                _ = self.inFlight.remove(nextId)
                            }
                        }
                    }
                }
                while await group.next() != nil {
                    if let nextId = iterator.next() {
                        group.addTask {
                            await self._fetch(videoId: nextId)
                            await MainActor.run {
                                _ = self.inFlight.remove(nextId)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Fetch a single video. Safe to call from anywhere.
    func fetchOneIfNeeded(videoId: String) {
        guard SettingsManager.shared.dearrowEnabled,
              self.dearrowTitles[videoId] == nil,
              !self.inFlight.contains(videoId)
        else { return }

        self.inFlight.insert(videoId)
        Task {
            await self._fetch(videoId: videoId)
            self.inFlight.remove(videoId)
        }
    }

    // MARK: - Private

    private func recordAccess(for videoId: String) {
        if let existingIndex = self.accessOrder.firstIndex(of: videoId) {
            self.accessOrder.remove(at: existingIndex)
        }
        self.accessOrder.append(videoId)
        while self.accessOrder.count > self.maxEntries {
            let evicted = self.accessOrder.removeFirst()
            self.dearrowTitles.removeValue(forKey: evicted)
            self.originalTitles.removeValue(forKey: evicted)
        }
    }

    private func _fetch(videoId: String) async {
        guard let url = URL(string: "https://sponsor.ajay.app/api/branding?videoID=\(videoId)") else {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let titlesList = json["titles"] as? [[String: Any]],
                  let first = titlesList.first
            else { return }

            let isOriginal = first["original"] as? Bool ?? true
            guard !isOriginal,
                  let newTitle = first["title"] as? String,
                  !newTitle.isEmpty
            else { return }

            self.dearrowTitles[videoId] = newTitle
            self.recordAccess(for: videoId)
        } catch {
            // Silently ignore — no DeArrow data for this video
        }
    }
}

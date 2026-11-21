import Foundation
import os

/// Persistent queue for pending scrobbles.
/// Serializes to JSON in `~/Library/Application Support/Kaset/scrobble-queue.json`.
/// Thread safety is ensured by `@MainActor` callers (ScrobblingCoordinator).
@MainActor
final class ScrobbleQueue {
    /// Maximum age for queued scrobbles (14 days). Last.fm rejects older submissions.
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    /// Maximum number of pending scrobbles retained in the queue.
    static let maxQueueSize = 500

    /// Deduplication tolerance for identical title+artist+start-timestamp scrobbles.
    private static let deduplicationWindow: TimeInterval = 0.001

    struct PersistedState: Codable, Sendable {
        var items: [ScrobbleTrack]
        var completedServicesByTrackId: [String: [String]]

        init(items: [ScrobbleTrack] = [], completedServicesByTrackId: [String: [String]] = [:]) {
            self.items = items
            self.completedServicesByTrackId = completedServicesByTrackId
        }
    }

    private var items: [ScrobbleTrack] = []
    private var completedServicesByTrackId: [UUID: Set<String>] = [:]
    private let fileURL: URL
    private let logger = DiagnosticsLogger.scrobbling
    private let persistence: ScrobbleQueuePersistence
    private let synchronousPersistence: Bool
    private var saveGeneration: UInt64 = 0
    private var pendingLoadTask: Task<Void, Never>?

    /// Number of pending scrobbles in the queue.
    var count: Int {
        self.items.count
    }

    /// Whether the queue has pending scrobbles.
    var isEmpty: Bool {
        self.items.isEmpty
    }

    /// All pending scrobble tracks (read-only).
    var pendingTracks: [ScrobbleTrack] {
        self.items
    }

    /// Creates a ScrobbleQueue with the given storage directory.
    /// - Parameters:
    ///   - directory: Directory for queue file. Defaults to Application Support/Kaset.
    ///   - synchronousPersistence: When true (e.g. unit tests), performs disk I/O synchronously.
    ///     In production, JSON encoding/decoding and file I/O run off `@MainActor`.
    init(
        directory: URL? = nil,
        synchronousPersistence: Bool = UITestConfig.isRunningUnitTests
    ) {
        let dir = directory ?? Self.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("scrobble-queue.json")
        self.synchronousPersistence = synchronousPersistence
        self.persistence = ScrobbleQueuePersistence(fileURL: self.fileURL)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if synchronousPersistence {
            self.loadFromDiskSynchronously()
        } else {
            self.loadFromDiskAsync()
        }
    }

    // MARK: - Queue Operations

    /// Adds a track to the end of the queue and persists to disk.
    func enqueue(_ track: ScrobbleTrack) {
        if self.isDuplicate(track) {
            self.logger.debug("Skipped duplicate scrobble enqueue: \(track.title) by \(track.artist)")
            return
        }

        if self.items.count >= Self.maxQueueSize {
            let overflow = self.items.count - Self.maxQueueSize + 1
            let dropped = self.items.prefix(overflow)
            for item in dropped {
                self.completedServicesByTrackId.removeValue(forKey: item.id)
            }
            self.items.removeFirst(overflow)
            self.logger.warning("Scrobble queue reached cap (\(Self.maxQueueSize)); dropped \(overflow) oldest track(s)")
        }

        self.items.append(track)
        self.saveToDisk()
        self.logger.debug("Enqueued scrobble: \(track.title) by \(track.artist) (queue size: \(self.items.count))")
    }

    /// Returns up to `limit` tracks from the front of the queue without removing them.
    /// Use `markCompleted(_:)` to remove after successful submission.
    func dequeue(limit: Int) -> [ScrobbleTrack] {
        Array(self.items.prefix(limit))
    }

    /// Returns up to `limit` tracks that have not yet been accepted by `serviceName`.
    func pendingTracks(for serviceName: String, limit: Int) -> [ScrobbleTrack] {
        var result: [ScrobbleTrack] = []
        result.reserveCapacity(min(limit, self.items.count))
        for track in self.items {
            if self.completedServicesByTrackId[track.id]?.contains(serviceName) != true {
                result.append(track)
                if result.count >= limit {
                    break
                }
            }
        }
        return result
    }

    /// Removes successfully submitted tracks from the queue by their IDs.
    func markCompleted(_ trackIds: Set<UUID>) {
        let beforeCount = self.items.count
        self.items.removeAll { trackIds.contains($0.id) }
        for id in trackIds {
            self.completedServicesByTrackId.removeValue(forKey: id)
        }
        let removedCount = beforeCount - self.items.count
        if removedCount > 0 {
            self.saveToDisk()
            self.logger.debug("Marked \(removedCount) scrobbles as completed (queue size: \(self.items.count))")
        }
    }

    /// Marks tracks as completed for `serviceName`, removing only tracks accepted by all `requiredServices`.
    func markCompleted(_ trackIds: Set<UUID>, for serviceName: String, requiredServices: Set<String>) {
        guard !trackIds.isEmpty || !requiredServices.isEmpty else { return }

        var stateChanged = false
        for id in trackIds {
            var completed = self.completedServicesByTrackId[id] ?? []
            if completed.insert(serviceName).inserted {
                self.completedServicesByTrackId[id] = completed
                stateChanged = true
            }
        }

        let beforeCount = self.items.count
        self.items.removeAll { track in
            let completed = self.completedServicesByTrackId[track.id] ?? []
            let isFullyCompleted = !requiredServices.isEmpty && requiredServices.isSubset(of: completed)
            if isFullyCompleted {
                self.completedServicesByTrackId.removeValue(forKey: track.id)
            }
            return isFullyCompleted
        }
        let removedCount = beforeCount - self.items.count
        if removedCount > 0 {
            stateChanged = true
            self.logger.debug("Completed \(removedCount) scrobbles across all required services (queue size: \(self.items.count))")
        }

        if stateChanged {
            self.saveToDisk()
        }
    }

    /// Removes scrobbles older than `maxAge` (14 days).
    /// Returns the number of pruned items.
    @discardableResult
    func pruneExpired() -> Int {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let beforeCount = self.items.count
        self.items.removeAll { track in
            let expired = track.timestamp < cutoff
            if expired {
                self.completedServicesByTrackId.removeValue(forKey: track.id)
            }
            return expired
        }
        let prunedCount = beforeCount - self.items.count
        if prunedCount > 0 {
            self.saveToDisk()
            self.logger.info("Pruned \(prunedCount) expired scrobbles (queue size: \(self.items.count))")
        }
        return prunedCount
    }

    /// Removes all items from the queue.
    func clear() {
        self.pendingLoadTask?.cancel()
        self.pendingLoadTask = nil
        self.items.removeAll()
        self.completedServicesByTrackId.removeAll()
        self.saveToDisk()
        self.logger.info("Queue cleared")
    }

    // MARK: - Persistence

    /// Saves the current queue to disk.
    func save() {
        self.saveToDisk()
    }

    /// Loads the queue from disk.
    func load() {
        if self.synchronousPersistence {
            self.loadFromDiskSynchronously()
        } else {
            self.loadFromDiskAsync()
        }
    }

    private func isDuplicate(_ track: ScrobbleTrack) -> Bool {
        self.items.contains { existing in
            if existing.id == track.id {
                return true
            }
            return existing.title.caseInsensitiveCompare(track.title) == .orderedSame
                && existing.artist.caseInsensitiveCompare(track.artist) == .orderedSame
                && abs(existing.timestamp.timeIntervalSince(track.timestamp)) < Self.deduplicationWindow
        }
    }

    private func makePersistedStateSnapshot() -> PersistedState {
        let serializedCompleted = self.completedServicesByTrackId.reduce(into: [String: [String]]()) { result, entry in
            if !entry.value.isEmpty {
                result[entry.key.uuidString] = Array(entry.value).sorted()
            }
        }
        return PersistedState(items: self.items, completedServicesByTrackId: serializedCompleted)
    }

    private func applyLoadedState(_ state: PersistedState, mergingInMemoryTracks: Bool) {
        var mergedItems: [ScrobbleTrack] = []
        var mergedCompleted: [UUID: Set<String>] = [:]

        for (key, services) in state.completedServicesByTrackId {
            if let uuid = UUID(uuidString: key) {
                mergedCompleted[uuid] = Set(services)
            }
        }

        for track in state.items {
            mergedItems.append(track)
        }

        if mergingInMemoryTracks {
            for track in self.items {
                let duplicate = mergedItems.contains { existing in
                    existing.id == track.id
                        || (existing.title.caseInsensitiveCompare(track.title) == .orderedSame
                            && existing.artist.caseInsensitiveCompare(track.artist) == .orderedSame
                            && abs(existing.timestamp.timeIntervalSince(track.timestamp)) < Self.deduplicationWindow)
                }
                if !duplicate {
                    mergedItems.append(track)
                }
                if let inMemoryCompleted = self.completedServicesByTrackId[track.id] {
                    mergedCompleted[track.id, default: []].formUnion(inMemoryCompleted)
                }
            }
        }

        if mergedItems.count > Self.maxQueueSize {
            let overflow = mergedItems.count - Self.maxQueueSize
            let dropped = mergedItems.prefix(overflow)
            for item in dropped {
                mergedCompleted.removeValue(forKey: item.id)
            }
            mergedItems.removeFirst(overflow)
        }

        self.items = mergedItems
        self.completedServicesByTrackId = mergedCompleted
    }

    private func saveToDisk() {
        self.saveGeneration &+= 1
        let generation = self.saveGeneration
        let snapshot = self.makePersistedStateSnapshot()

        if self.synchronousPersistence {
            Self.writeStateSynchronously(snapshot, to: self.fileURL, logger: self.logger)
        } else {
            let persistence = self.persistence
            Task(priority: .utility) {
                await persistence.save(snapshot, generation: generation)
            }
        }
    }

    private func loadFromDiskSynchronously() {
        let state = Self.loadStateSynchronously(from: self.fileURL, logger: self.logger)
        self.applyLoadedState(state, mergingInMemoryTracks: false)
    }

    private func loadFromDiskAsync() {
        self.pendingLoadTask?.cancel()
        let persistence = self.persistence
        self.pendingLoadTask = Task { @MainActor [weak self] in
            let state = await persistence.load()
            guard let self, !Task.isCancelled else { return }
            let hadInMemoryItems = !self.items.isEmpty
            self.applyLoadedState(state, mergingInMemoryTracks: hadInMemoryItems)
            if hadInMemoryItems {
                self.saveToDisk()
            }
            self.pendingLoadTask = nil
        }
    }

    // MARK: - Static Persistence Helpers

    nonisolated static func loadStateSynchronously(from fileURL: URL, logger: Logger) -> PersistedState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistedState()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970

            if let state = try? decoder.decode(PersistedState.self, from: data) {
                logger.info("Loaded \(state.items.count) pending scrobbles from disk")
                return state
            }

            let legacyItems = try decoder.decode([ScrobbleTrack].self, from: data)
            logger.info("Loaded \(legacyItems.count) legacy pending scrobbles from disk")
            return PersistedState(items: legacyItems)
        } catch {
            Self.preserveCorruptBackup(at: fileURL, logger: logger, error: error)
            return PersistedState()
        }
    }

    nonisolated static func writeStateSynchronously(
        _ state: PersistedState,
        to fileURL: URL,
        logger: Logger
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save scrobble queue: \(error.localizedDescription)")
        }
    }

    nonisolated private static func preserveCorruptBackup(
        at fileURL: URL,
        logger: Logger,
        error: Error
    ) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupName = "scrobble-queue.corrupt-\(timestamp)-\(UUID().uuidString.prefix(8)).json"
        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            logger.error("Failed to load scrobble queue (\(error.localizedDescription)); preserved corrupt backup at \(backupURL.lastPathComponent)")
        } catch {
            logger.error("Failed to load scrobble queue and failed to back up corrupt file: \(error.localizedDescription)")
        }
    }

    // MARK: - Default Directory

    private static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Kaset")
    }
}

// MARK: - ScrobbleQueuePersistence

private actor ScrobbleQueuePersistence {
    private let fileURL: URL
    private let logger = DiagnosticsLogger.scrobbling
    private var latestSavedGeneration: UInt64 = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> ScrobbleQueue.PersistedState {
        ScrobbleQueue.loadStateSynchronously(from: self.fileURL, logger: self.logger)
    }

    func save(_ state: ScrobbleQueue.PersistedState, generation: UInt64) {
        guard generation >= self.latestSavedGeneration else { return }
        self.latestSavedGeneration = generation
        ScrobbleQueue.writeStateSynchronously(state, to: self.fileURL, logger: self.logger)
    }
}

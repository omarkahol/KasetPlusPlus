import Foundation
import Observation

/// Isolates high-frequency playback progress updates so views that only observe
/// metadata, queue, or transport state on `PlayerService` do not re-evaluate
/// on every periodic time tick.
@MainActor
@Observable
final class PlaybackClock {
    /// Current playback position in seconds.
    var progress: TimeInterval = 0
}

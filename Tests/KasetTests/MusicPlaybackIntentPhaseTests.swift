import Testing
@testable import KasetPlus

@Suite("MusicPlaybackIntentPhase", .tags(.service))
@MainActor
struct MusicPlaybackIntentPhaseTests {
    @Test("Preserves loading intent when isPlaying=false arrives before confirmation")
    func preservesLoadingWhenAwaitingConfirmation() {
        let phase = MusicPlaybackIntentPhase.loading(awaitingConfirmation: true)
        let next = phase.applyingObservedPlayback(isPlaying: false, currentState: .loading)

        #expect(next == .loading(awaitingConfirmation: true))
        #expect(next.isAwaitingConfirmation)
        #expect(next.shouldResumeAfterInterruption)
        #expect(!next.isExplicitPauseIntentActive)
    }

    @Test("Transitions to playing when isPlaying=true arrives during loading")
    func transitionsToPlayingWhenConfirmed() {
        let phase = MusicPlaybackIntentPhase.loading(awaitingConfirmation: true)
        let next = phase.applyingObservedPlayback(isPlaying: true, currentState: .loading)

        #expect(next == .playing)
        #expect(!next.isAwaitingConfirmation)
        #expect(next.shouldResumeAfterInterruption)
    }

    @Test("Explicit user pause rejects late isPlaying=true updates")
    func userPauseRejectsLatePlaying() {
        let phase = MusicPlaybackIntentPhase.pausedByUser
        let next = phase.applyingObservedPlayback(isPlaying: true, currentState: .paused)

        #expect(next == .pausedByUser)
        #expect(next.isExplicitPauseIntentActive)
        #expect(!next.shouldResumeAfterInterruption)
    }
}

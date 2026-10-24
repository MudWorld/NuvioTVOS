import Testing
@testable import AetherEngine

@Suite("Native remote-HLS starvation recovery")
struct NativeLiveHLSStarvationPolicyTests {
    @Test("low live cushion rejoins after six seconds without producer frontier growth")
    func lowCushionCountdown() {
        var policy = NativeLiveHLSStarvationPolicy()
        #expect(sample(&policy, at: 0, clock: 10, end: 18) == .none)
        #expect(sample(&policy, at: 5.9, clock: 16.4, end: 18) == .none)
        #expect(sample(&policy, at: 6.1, clock: 16.6, end: 18) == .rejoin)
    }

    @Test("a transient refill restarts the six-second countdown")
    func transientRefill() {
        var policy = NativeLiveHLSStarvationPolicy()
        #expect(sample(&policy, at: 0, clock: 10, end: 11) == .none)
        #expect(sample(&policy, at: 5, clock: 15, end: 17) == .none)
        #expect(sample(&policy, at: 10.9, clock: 15, end: 17, stalled: true) == .none)
        #expect(sample(&policy, at: 11.1, clock: 15, end: 17, stalled: true) == .rejoin)
    }

    @Test("a frozen rollback rejoins with stale buffer still ahead of the playhead")
    func frozenRollback() {
        var policy = NativeLiveHLSStarvationPolicy()
        #expect(sample(&policy, at: 0, clock: 23.8, end: 23.86, stalled: true) == .none)
        #expect(sample(&policy, at: 4, clock: 18.02, end: 23.86, stalled: true) == .none)
        #expect(sample(&policy, at: 6.1, clock: 18.02, end: 23.86, stalled: true) == .rejoin)
    }

    @Test("frontier growth below a genuinely rolled-back range axis resets starvation")
    func frontierGrowthAfterAxisRollback() {
        var policy = NativeLiveHLSStarvationPolicy()
        #expect(sample(&policy, at: 0, clock: 100, end: 101) == .none)
        #expect(sample(&policy, at: 1, clock: 90, end: 91) == .none)
        #expect(sample(&policy, at: 2, clock: 91, end: 92) == .none)
        #expect(sample(&policy, at: 3, clock: 92, end: 93) == .none)
        #expect(sample(&policy, at: 4, clock: 93, end: 94) == .none)
        #expect(sample(&policy, at: 5, clock: 94, end: 95) == .none)
        #expect(sample(&policy, at: 6, clock: 95, end: 96) == .none)
        #expect(sample(&policy, at: 7, clock: 96, end: 97) == .none)
    }

    @Test("VOD, paused intent, and an active seek cannot start a rejoin")
    func ineligibleSessionsDoNotRejoin() {
        var vod = NativeLiveHLSStarvationPolicy()
        #expect(sample(&vod, at: 0, clock: 10, end: 10, isLive: false) == .none)
        #expect(sample(&vod, at: 10, clock: 10, end: 10, isLive: false) == .none)

        var paused = NativeLiveHLSStarvationPolicy()
        #expect(sample(&paused, at: 0, clock: 10, end: 10, playIntent: false) == .none)
        #expect(sample(&paused, at: 10, clock: 10, end: 10, playIntent: false) == .none)

        var seeking = NativeLiveHLSStarvationPolicy()
        #expect(sample(&seeking, at: 0, clock: 10, end: 10, seekInFlight: true) == .none)
        #expect(sample(&seeking, at: 10, clock: 10, end: 10, seekInFlight: true) == .none)

        var unstarted = NativeLiveHLSStarvationPolicy()
        #expect(sample(&unstarted, at: 0, clock: 10, end: 10, hasEverPlayed: false) == .none)
        #expect(sample(&unstarted, at: 10, clock: 10, end: 10, hasEverPlayed: false) == .none)

        var nonRemote = NativeLiveHLSStarvationPolicy()
        #expect(sample(&nonRemote, at: 0, clock: 10, end: 10, surfacesEndFailures: false) == .none)
        #expect(sample(&nonRemote, at: 10, clock: 10, end: 10, surfacesEndFailures: false) == .none)

        var ended = NativeLiveHLSStarvationPolicy()
        #expect(sample(&ended, at: 0, clock: 10, end: 10, hasReachedEnd: true) == .none)
        #expect(sample(&ended, at: 10, clock: 10, end: 10, hasReachedEnd: true) == .none)
    }

    @Test("pause and resume restart the countdown")
    func pauseResumeResetsObservation() {
        var policy = NativeLiveHLSStarvationPolicy()
        #expect(sample(&policy, at: 0, clock: 10, end: 11) == .none)
        #expect(sample(&policy, at: 5, clock: 15, end: 15, playIntent: false) == .none)
        #expect(sample(&policy, at: 6, clock: 16, end: 16) == .none)
        #expect(sample(&policy, at: 11.9, clock: 16, end: 16) == .none)
        #expect(sample(&policy, at: 12.1, clock: 16, end: 16) == .rejoin)
    }

    @Test("two confirmed failures spend a session budget that survives item swaps")
    func retryBudgetPersistsAcrossSwaps() {
        var policy = NativeLiveHLSStarvationPolicy()
        #expect(policy.confirmedFailure() == .rejoin)
        policy.resetObservation()
        #expect(policy.confirmedFailure() == .rejoin)
        policy.resetObservation()
        #expect(policy.confirmedFailure() == .exhausted)
        policy.resetForNewSession()
        #expect(policy.confirmedFailure() == .rejoin)
    }

    @Test("starvation exhausts the same budget confirmed failures spend")
    func starvationExhaustsSharedBudget() {
        var policy = NativeLiveHLSStarvationPolicy()
        #expect(policy.confirmedFailure() == .rejoin)
        #expect(policy.confirmedFailure() == .rejoin)
        #expect(sample(&policy, at: 0, clock: 10, end: 11) == .none)
        #expect(sample(&policy, at: 6.1, clock: 10, end: 11) == .exhausted)
    }

    private func sample(
        _ policy: inout NativeLiveHLSStarvationPolicy,
        at uptime: Double,
        clock: Double,
        end: Double,
        isLive: Bool = true,
        surfacesEndFailures: Bool = true,
        hasEverPlayed: Bool = true,
        playIntent: Bool = true,
        seekInFlight: Bool = false,
        hasReachedEnd: Bool = false,
        stalled: Bool = false
    ) -> NativeLiveHLSStarvationPolicy.Decision {
        policy.observe(
            uptime: uptime,
            renderedTime: clock,
            bufferedEnd: end,
            isLive: isLive,
            surfacesEndFailures: surfacesEndFailures,
            hasEverPlayed: hasEverPlayed,
            playIntent: playIntent,
            seekInFlight: seekInFlight,
            mountSeekPending: false,
            hasReachedEnd: hasReachedEnd,
            hasFailure: false,
            transportIsStalled: stalled
        )
    }
}

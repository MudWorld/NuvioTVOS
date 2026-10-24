struct NativeLiveHLSStarvationPolicy {
    enum Decision: Equatable {
        case none
        case rejoin
        case exhausted
    }

    static let intervalSeconds = 1.0
    static let starvationSeconds = 6.0
    static let lowBufferSeconds = 1.5
    static let maximumRejoins = 2

    private(set) var rejoinCount = 0
    private var highestBufferFrontier: Double?
    private var lastFrontierGrowthAt: Double?
    private var previousClock: Double?
    private var previousBufferedEnd: Double?
    private var lastClockAdvanceAt: Double?

    mutating func resetForNewSession() {
        rejoinCount = 0
        resetObservation()
    }

    mutating func resetObservation() {
        highestBufferFrontier = nil
        lastFrontierGrowthAt = nil
        previousClock = nil
        previousBufferedEnd = nil
        lastClockAdvanceAt = nil
    }

    mutating func observe(
        uptime: Double,
        renderedTime: Double,
        bufferedEnd: Double,
        isLive: Bool,
        surfacesEndFailures: Bool,
        hasEverPlayed: Bool,
        playIntent: Bool,
        seekInFlight: Bool,
        mountSeekPending: Bool,
        hasReachedEnd: Bool,
        hasFailure: Bool,
        transportIsStalled: Bool
    ) -> Decision {
        guard isLive, surfacesEndFailures, hasEverPlayed, playIntent,
              !seekInFlight, !mountSeekPending, !hasReachedEnd, !hasFailure else {
            resetObservation()
            return .none
        }
        guard uptime.isFinite, renderedTime.isFinite, bufferedEnd.isFinite else {
            resetObservation()
            return .none
        }

        if let previousClock, let previousBufferedEnd,
           renderedTime < previousClock - 1.0,
           bufferedEnd < previousBufferedEnd - 1.0 {
            // A playlist/range axis moved with the clock. Rebase the high-water mark so real
            // producer growth on the new axis counts, unlike a playhead-only rollback through
            // an unchanged stale range.
            highestBufferFrontier = bufferedEnd > renderedTime + 0.01 ? bufferedEnd : nil
            lastFrontierGrowthAt = uptime
            lastClockAdvanceAt = uptime
        } else if lastFrontierGrowthAt == nil {
            lastFrontierGrowthAt = uptime
        }
        if let highestBufferFrontier {
            if bufferedEnd > renderedTime + 0.01,
               bufferedEnd > highestBufferFrontier + 0.25 {
                self.highestBufferFrontier = bufferedEnd
                lastFrontierGrowthAt = uptime
            }
        } else if bufferedEnd > renderedTime + 0.01 {
            // `contiguousBufferedEnd` returns the playhead when no loaded range covers it.
            // Treat that as the initial observation, not producer progress.
            highestBufferFrontier = bufferedEnd
            lastFrontierGrowthAt = uptime
        }

        if let previousClock {
            if renderedTime > previousClock + 0.25 {
                lastClockAdvanceAt = uptime
            }
        } else {
            lastClockAdvanceAt = uptime
        }
        previousClock = renderedTime
        previousBufferedEnd = bufferedEnd

        guard let lastFrontierGrowthAt,
              uptime - lastFrontierGrowthAt >= Self.starvationSeconds else { return .none }

        let bufferIsLow = bufferedEnd - renderedTime <= Self.lowBufferSeconds
        let clockIsFrozen = lastClockAdvanceAt.map {
            uptime - $0 >= Self.starvationSeconds
        } ?? false
        // Rejoin before a live buffer drains completely, even while the player is still moving.
        // A larger stale cushion only qualifies when transport is stalled and its clock is frozen.
        guard bufferIsLow || (transportIsStalled && clockIsFrozen) else { return .none }
        return reserveRejoin()
    }

    mutating func confirmedFailure() -> Decision {
        resetObservation()
        return reserveRejoin()
    }

    private mutating func reserveRejoin() -> Decision {
        guard rejoinCount < Self.maximumRejoins else { return .exhausted }
        rejoinCount += 1
        return .rejoin
    }
}

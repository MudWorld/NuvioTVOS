struct NativeLiveHLSStarvationPolicy {
    enum Decision: Equatable {
        case none
        case rejoin
        case exhausted
    }

    static let intervalSeconds = 1.0
    static let starvationSeconds = 6.0
    /// Cushion threshold for proactive re-buffering: re-join before buffer drains to 0.
    static let lowBufferSeconds = 3.5
    /// Minimum time without frontier growth when cushion is low before initiating re-join.
    static let lowBufferStarvationSeconds = 2.0
    /// Emergency threshold: buffer is critically close to running out (< 1.5s).
    static let criticalBufferSeconds = 1.5
    static let maximumRejoins = 2
    /// Playback duration without starvation required to replenish the retry budget.
    static let recoveryBudgetCooldownSeconds = 30.0

    private(set) var rejoinCount = 0
    private var highestBufferFrontier: Double?
    private var lastFrontierGrowthAt: Double?
    private var previousClock: Double?
    private var previousBufferedEnd: Double?
    private var lastClockAdvanceAt: Double?
    private var lastRejoinUptime: Double?

    mutating func resetForNewSession() {
        rejoinCount = 0
        lastRejoinUptime = nil
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

        // Replenish rejoin budget after sustained healthy playback
        if rejoinCount > 0, let lastRejoin = lastRejoinUptime,
           uptime - lastRejoin >= Self.recoveryBudgetCooldownSeconds {
            rejoinCount = 0
            lastRejoinUptime = nil
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

        guard let lastFrontierGrowthAt else { return .none }

        let cushion = max(0, bufferedEnd - renderedTime)
        let growthStallSeconds = uptime - lastFrontierGrowthAt

        // 1. Critical cushion: buffer is about to run out (< 1.5s). Trigger immediately if growth stalled for 1s.
        if cushion <= Self.criticalBufferSeconds && growthStallSeconds >= 1.0 {
            return reserveRejoin(uptime: uptime)
        }

        // 2. Proactive low-buffer re-join: buffer has dropped into danger zone (<= 3.5s).
        // Trigger while buffer is still playing to complete re-join BEFORE buffer hits 0.
        if cushion <= Self.lowBufferSeconds && growthStallSeconds >= Self.lowBufferStarvationSeconds {
            return reserveRejoin(uptime: uptime)
        }

        // 3. Stalled / frozen transport: player is paused/waiting and clock has frozen.
        let clockIsFrozen = lastClockAdvanceAt.map {
            uptime - $0 >= Self.starvationSeconds
        } ?? false
        if transportIsStalled && clockIsFrozen && growthStallSeconds >= Self.starvationSeconds {
            return reserveRejoin(uptime: uptime)
        }

        return .none
    }

    mutating func confirmedFailure() -> Decision {
        resetObservation()
        return reserveRejoin()
    }

    private mutating func reserveRejoin(uptime: Double? = nil) -> Decision {
        guard rejoinCount < Self.maximumRejoins else { return .exhausted }
        rejoinCount += 1
        if let uptime { lastRejoinUptime = uptime }
        return .rejoin
    }
}

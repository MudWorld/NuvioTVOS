import Foundation

/// Global feature configuration for Watch Party capabilities.
enum WatchPartyConfiguration {
    /// Enables Watch Party capabilities across tvOS tabs, details, and player.
    /// Off in WatchParty: its server (sync.mudworld.space) has no realtime channel for it.
    static let isEnabled = false
}

// Sync semantics adapted from NuvioMedia/NuvioTV (GPL-3.0),
// PartySync.kt at f7e2a78ad3b19a09080ad08315825f1f0a472934.
// Keep thresholds aligned with Android; extreme arithmetic saturates instead of trapping.
enum WatchPartyCorrection: Equatable {
    case inSync
    case seek(positionMs: Int64)
    case nudge(rate: Float)
}

enum WatchPartyOwnSeek: Equatable {
    case behind(positionMs: Int64)
    case catchUp
    case blocked
}

enum WatchPartyAction: Equatable { case paused, resumed, seeked, speed }

enum WatchPartyPolicy {
    static let nudgeStartMs: Int64 = 250
    static let nudgeStopMs: Int64 = 80
    static let seekThresholdMs: Int64 = 1_500
    static let pausedToleranceMs: Int64 = 500
    static let nudgeFactor: Float = 0.05
    static let seekNoticeMs: Int64 = 2_000
    static let rejoinGapMs: Int64 = 2_000
    static let behindStepMs: Int64 = 5_000

    static func expectedPosition(_ playback: WatchPartyPlayback, nowMs: Int64, durationMs: Int64 = 0) -> Int64 {
        var position = playback.positionMs
        if !playback.paused, playback.rate.isFinite, playback.rate > 0 {
            let elapsed = max(0, WatchPartyTimeMath.subtract(nowMs, playback.at))
            // Kotlin multiplies Long by Float using Float precision before converting back to Long.
            let advance = WatchPartyTimeMath.integer(Double(Float(elapsed) * playback.rate))
            position = WatchPartyTimeMath.add(position, advance)
        }
        position = max(0, position)
        return durationMs > 0 ? min(position, durationMs) : position
    }

    static func isNewer(_ candidate: WatchPartyPlayback, than current: WatchPartyPlayback?) -> Bool {
        guard let current else { return true }
        if candidate.seq != current.seq { return candidate.seq > current.seq }
        // Kotlin String.compareTo compares UTF-16 code units, not locale-aware/canonical ordering.
        return (current.memberID ?? "").utf16.lexicographicallyPrecedes((candidate.memberID ?? "").utf16)
    }

    static func correction(localPositionMs: Int64, expectedPositionMs: Int64,
                           playback: WatchPartyPlayback, nudging: Bool) -> WatchPartyCorrection {
        let distance = WatchPartyTimeMath.distance(localPositionMs, expectedPositionMs)
        if playback.paused {
            return distance > pausedToleranceMs ? .seek(positionMs: expectedPositionMs) : .inSync
        }
        if distance > seekThresholdMs { return .seek(positionMs: expectedPositionMs) }
        if distance > (nudging ? nudgeStopMs : nudgeStartMs), playback.rate.isFinite, playback.rate > 0 {
            let factor: Float = localPositionMs > expectedPositionMs ? 1 - nudgeFactor : 1 + nudgeFactor
            let rate = playback.rate * factor
            return rate.isFinite ? .nudge(rate: rate) : .inSync
        }
        return .inSync
    }

    static func coordinatorID(memberID: String, hostMemberID: String?, hostOnly: Bool,
                              members: [WatchPartyMember], onlineMemberIDs: Set<String>) -> String? {
        let online = onlineMemberIDs.union([memberID])
        if let hostMemberID, online.contains(hostMemberID) { return hostMemberID }
        if hostOnly { return hostMemberID }
        return members.first(where: { online.contains($0.id) })?.id ?? memberID
    }

    static func action(previous: WatchPartyPlayback?, next: WatchPartyPlayback) -> WatchPartyAction? {
        guard let previous, !previous.waiting, !next.waiting, previous.mediaKey == next.mediaKey else { return nil }
        if previous.paused != next.paused { return next.paused ? .paused : .resumed }
        if abs(previous.rate - next.rate) > 0.01 { return .speed }
        if WatchPartyTimeMath.distance(next.positionMs, expectedPosition(previous, nowMs: next.at)) > seekNoticeMs {
            return .seeked
        }
        return nil
    }

    static func ownSeek(targetMs: Int64, partyPositionMs: Int64, behind: Bool) -> WatchPartyOwnSeek {
        if targetMs < WatchPartyTimeMath.subtract(partyPositionMs, rejoinGapMs) {
            return .behind(positionMs: targetMs)
        }
        return behind ? .catchUp : .blocked
    }

    static func shouldRejoin(gapMs: Int64, playing: Bool) -> Bool { playing && gapMs <= rejoinGapMs }

    static func reportedGap(_ gapMs: Int64) -> Int64 {
        if gapMs == .max { return .max }
        let gap = max(0, gapMs)
        let steps = gap / behindStepMs + (gap % behindStepMs >= behindStepMs / 2 ? 1 : 0)
        let rounded = steps.multipliedReportingOverflow(by: behindStepMs)
        return rounded.overflow ? .max : max(behindStepMs, rounded.partialValue)
    }

    static func waitingMemberIDs(mediaKey: String, presence: [String: WatchPartyPresence],
                                 ignored: Set<String>) -> [String] {
        presence.values.filter {
            $0.mediaKey == mediaKey && ($0.status == .loading || $0.status == .buffering)
                && !ignored.contains($0.memberID)
        }.map(\.memberID)
    }
}

enum WatchPartyTimeMath {
    static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? (rhs >= 0 ? .max : .min) : result.partialValue
    }

    static func subtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        return result.overflow ? (rhs < 0 ? .max : .min) : result.partialValue
    }

    static func distance(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let delta = subtract(lhs, rhs)
        return delta == .min ? .max : abs(delta)
    }

    static func integer(_ value: Double) -> Int64 {
        guard !value.isNaN else { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }
}

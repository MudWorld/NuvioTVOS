import Foundation

struct WatchPartyBindingRoomState: Equatable {
    let roomID: String
    let memberID: String
    let mediaKey: String
    let hostMemberID: String?
    let hostOnly: Bool
    let connected: Bool
    let playback: WatchPartyPlayback?
    var canControl: Bool { connected && (!hostOnly || hostMemberID == memberID) }
    var isHost: Bool { hostMemberID == memberID }
}

@MainActor
protocol WatchPartyPlaybackRoom: AnyObject {
    var bindingState: WatchPartyBindingRoomState? { get }
    func nowMs() -> Int64
    func observeChanges(_ callback: @escaping @MainActor () -> Void) -> UUID
    func removeChangeObserver(_ id: UUID)
    func observeNotices(_ callback: @escaping @MainActor (WatchPartyNotice) -> Void) -> UUID
    func removeNoticeObserver(_ id: UUID)
    func observeChat(_ callback: @escaping @MainActor (WatchPartyChatMessage) -> Void) -> UUID
    func removeChatObserver(_ id: UUID)
    func publish(paused: Bool, positionMs: Int64, rate: Float, waiting: Bool) async throws
    func setPresence(status: WatchPartyMemberStatus, mediaKey: String?, behindMs: Int64?) async throws
}

extension WatchPartyPlaybackRoom {
    func observeNotices(_ callback: @escaping @MainActor (WatchPartyNotice) -> Void) -> UUID { UUID() }
    func removeNoticeObserver(_ id: UUID) {}
    func observeChat(_ callback: @escaping @MainActor (WatchPartyChatMessage) -> Void) -> UUID { UUID() }
    func removeChatObserver(_ id: UUID) {}
}

extension WatchPartySession: WatchPartyPlaybackRoom {
    var bindingState: WatchPartyBindingRoomState? {
        guard let party, let memberID else { return nil }
        return WatchPartyBindingRoomState(roomID: party.id, memberID: memberID, mediaKey: party.media.key,
                                          hostMemberID: party.hostMemberID, hostOnly: party.hostOnly,
                                          connected: connection == .ready, playback: playback)
    }
}

enum WatchPartyLocalIntent { case play, pause, toggle, seek(Int64), seekAndPlay(Int64), speed(Float), catchUp }
enum WatchPartyPlaybackBindingError: Error, Equatable {
    case notReady, forbidden, busy, staleOperation, mediaChanged, seekTooSlow, alreadyBound
}

/// One binding per accepted membership/runtime. It owns the bridge's sample callback and its own
/// room subscription; never replaces the service's onChange, never infers local gestures from samples.
/// Root retains and stops it before invalidating the player/context. Construction does not join a room.
@MainActor
final class WatchPartyPlaybackBinding {
    var onError: (@MainActor (Error) -> Void)?
    var onNeedsMedia: (@MainActor (String) -> Void)?
    var onNotice: (@MainActor (WatchPartyNotice) -> Void)?
    var onChatMessage: (@MainActor (WatchPartyChatMessage) -> Void)?
    private(set) var isBehind = false
    private(set) var behindMs: Int64?

    private let room: any WatchPartyPlaybackRoom
    private let bridge: WatchPartyPlayerBridge
    private let contextIsCurrent: @MainActor () -> Bool
    private let uptime: @MainActor () -> TimeInterval
    private let roomID: String
    private let memberID: String
    private let mediaKey: String
    private var state: WatchPartyBindingRoomState
    private var observerID: UUID?
    private var noticeObserverID: UUID?
    private var chatObserverID: UUID?
    private var stopped = false
    private var suspended = false
    private var revision = UUID()
    private var sample: WatchPartyPlayerSample?
    private var localBusy = false
    private var worker: Task<Void, Never>?
    private var lastApplied: (WatchPartyPlayback, WatchPartyPlayerStamp)?
    private var blocked: (UUID, WatchPartyPlayerStamp)?
    private var lastCorrectionAt: TimeInterval?
    private var lastSeekAt: TimeInterval?
    private var seekLeadMs: Int64 = 0
    private var initialPublicationAttempted = false
    private var bufferingSince: TimeInterval?
    private var desiredPresence: WatchPartyPresence?
    private var sentPresence: WatchPartyPresence?
    private var failedPresence: (UUID, WatchPartyPresence)?
    private var presenceWorker: Task<Void, Never>?

    var isSynchronizing: Bool { worker != nil || localBusy }
    var canonicalRate: Float? { state.playback?.rate }

    /// Lifecycle is not a local-user gesture. Invalidate pending continuations before raw pause.
    func setSuspended(_ value: Bool) {
        guard !stopped, suspended != value else { return }
        suspended = value
        revision = UUID()
        worker?.cancel()
        blocked = nil
        lastApplied = nil
        bridge.clearTemporaryRate()
        let previousSample = sample
        sample = nil // Neither pre-park nor inactive samples may drive the first resumed effect.
        if value, let previousSample { updatePresence(previousSample) }
    }

    init(room: any WatchPartyPlaybackRoom, bridge: WatchPartyPlayerBridge,
         isCurrent: @escaping @MainActor () -> Bool,
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        guard let state = room.bindingState, isCurrent() else { throw WatchPartyPlaybackBindingError.notReady }
        guard bridge.onSample == nil else { throw WatchPartyPlaybackBindingError.alreadyBound }
        if let sample = bridge.sample, sample.stamp.mediaKey != state.mediaKey {
            throw WatchPartyPlaybackBindingError.mediaChanged
        }
        self.room = room
        self.bridge = bridge
        self.contextIsCurrent = isCurrent
        self.uptime = uptime
        self.state = state
        roomID = state.roomID; memberID = state.memberID; mediaKey = state.mediaKey
        observerID = room.observeChanges { [weak self] in self?.roomChanged() }
        noticeObserverID = room.observeNotices { [weak self] in self?.onNotice?($0) }
        chatObserverID = room.observeChat { [weak self] in self?.onChatMessage?($0) }
        bridge.onSample = { [weak self] in self?.observed($0) }
        if let sample = bridge.sample { observed(sample) }
    }

    /// Explicit recovery action after an engine failure. Failed room mutations are never retried here.
    func retrySynchronization() {
        guard active else { return }
        blocked = nil
        lastApplied = nil
        reconcile()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        revision = UUID()
        if let observerID { room.removeChangeObserver(observerID) }
        observerID = nil
        if let noticeObserverID { room.removeNoticeObserver(noticeObserverID) }
        noticeObserverID = nil
        if let chatObserverID { room.removeChatObserver(chatObserverID) }
        chatObserverID = nil
        worker?.cancel(); worker = nil
        presenceWorker?.cancel(); presenceWorker = nil
        bridge.stop()
        sample = nil
    }

    private var active: Bool {
        !stopped && contextIsCurrent() && room.bindingState?.roomID == roomID
            && room.bindingState?.memberID == memberID && room.bindingState?.mediaKey == mediaKey
    }

    private func admitted(_ mark: UUID, stamp: WatchPartyPlayerStamp) -> Bool {
        active && !suspended && revision == mark && room.bindingState == state && state.connected
            && bridge.sample?.stamp == stamp && stamp.mediaKey == mediaKey
    }

    private func roomChanged() {
        guard !stopped else { return }
        guard contextIsCurrent(), let next = room.bindingState,
              next.roomID == roomID, next.memberID == memberID else { stop(); return }
        guard next.mediaKey == mediaKey else {
            let callback = onNeedsMedia
            stop()
            callback?(next.mediaKey)
            return
        }
        guard next != state else { return } // Presence updates must not revoke playback effects.
        let remoteTransition: Bool
        if let playback = next.playback, playback.memberID != next.memberID,
           playback.paused != state.playback?.paused {
            remoteTransition = true
            PlaybackTimelineRecorder.record(playback.paused ? .partyPauseBindingObserved : .partyPlayBindingObserved)
        } else {
            remoteTransition = false
        }
        revision = UUID()
        state = next
        blocked = nil
        worker?.cancel() // Keep its slot until the cancelled effect actually returns.
        if remoteTransition {
            if isBehind {
                PlaybackTimelineRecorder.record(.partyBindingDeferredBehind)
            } else if localBusy || worker != nil {
                PlaybackTimelineRecorder.record(.partyBindingDeferredBusy)
            } else if usableSample() == nil {
                PlaybackTimelineRecorder.record(.partyBindingDeferredSample)
            }
        }
        if next.canControl { isBehind = false; behindMs = nil }
        if !next.connected {
            lastApplied = nil
            bridge.clearTemporaryRate()
            presenceWorker?.cancel()
            sentPresence = nil
        }
        reconcile()
        flushPresence()
    }

    private func observed(_ value: WatchPartyPlayerSample) {
        guard active else { stop(); return }
        guard value.stamp.mediaKey == mediaKey else {
            let callback = onNeedsMedia
            stop()
            callback?(mediaKey)
            return
        }
        sample = value
        if isBehind, let playback = state.playback {
            let gap = WatchPartyTimeMath.subtract(expected(playback, sample: value), value.positionMs)
            if state.canControl || WatchPartyPolicy.shouldRejoin(gapMs: gap, playing: !value.paused && !value.loading) {
                isBehind = false; behindMs = nil; lastApplied = nil
            } else { behindMs = max(0, gap) }
        }
        updatePresence(value)
        reconcile()
    }

    private func expected(_ playback: WatchPartyPlayback, sample: WatchPartyPlayerSample) -> Int64 {
        WatchPartyPolicy.expectedPosition(playback, nowMs: room.nowMs(), durationMs: sample.durationMs)
    }

    private func usableSample() -> WatchPartyPlayerSample? {
        guard active, !suspended, state.connected, let sample, sample.coherent, !sample.loading,
              sample.rendered, !sample.failed, !sample.seeking, sample.durationMs > 0,
              sample.stamp.mediaKey == mediaKey else { return nil }
        return sample
    }

    /// Pause needs a current checked player/source binding, but no seek receipt or duration.
    private func pauseSample() -> WatchPartyPlayerSample? {
        guard active, !suspended, state.connected, room.bindingState == state, let sample,
              !sample.failed, sample.stamp.mediaKey == mediaKey,
              bridge.sample?.stamp == sample.stamp else { return nil }
        return sample
    }

    private func performPause(onApplied: (@MainActor () -> Void)?) async throws {
        try Task.checkCancellation()
        guard let initial = pauseSample() else { throw WatchPartyPlaybackBindingError.notReady }
        guard !localBusy else { throw WatchPartyPlaybackBindingError.busy }
        localBusy = true
        defer { localBusy = false }

        // Revoke automatic room correction before waiting for it to drain. Its permit observes
        // the new revision, so a late seek/play receipt cannot reapply the old room state.
        revision = UUID()
        lastApplied = nil
        let correction = worker
        correction?.cancel()
        if let correction { await correction.value }

        try Task.checkCancellation()
        guard active, !suspended, state.connected,
              let sample = pauseSample(), sample.stamp == initial.stamp else {
            throw WatchPartyPlaybackBindingError.staleOperation
        }

        let mark = revision
        let controlsRoom = state.canControl
        let previousBehind = isBehind
        if !controlsRoom { isBehind = true }
        let rate = controlsRoom ? (state.playback?.rate ?? sample.rate) : sample.rate
        guard rate.isFinite, (0.25...4).contains(rate) else {
            isBehind = previousBehind
            throw WatchPartyPlaybackBindingError.notReady
        }
        let permit: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.admitted(mark, stamp: initial.stamp) && self.state.canControl == controlsRoom
        }
        do {
            let receipt = try await bridge.apply(WatchPartyPlayerEffect(paused: true, rate: rate),
                                                  origin: .localUser, isPauseOnly: true, isAdmitted: permit)
            guard permit() else { throw WatchPartyPlaybackBindingError.staleOperation }
            onApplied?()
            guard permit() else { throw WatchPartyPlaybackBindingError.staleOperation }
            if controlsRoom {
                let position = bridge.sample?.positionMs ?? sample.positionMs
                try await room.publish(paused: true, positionMs: position,
                                       rate: receipt.appliedRate, waiting: false)
                // The publish updates room playback and may advance its binding revision.
                guard active else { throw WatchPartyPlaybackBindingError.staleOperation }
            }
        } catch {
            if revision == mark { isBehind = controlsRoom ? false : previousBehind }
            throw error
        }
    }

    private func reconcile() {
        guard active, state.connected, !localBusy, worker == nil, !isBehind else { return }
        let readySample = usableSample()
        guard let playback = state.playback else {
            guard let sample = readySample else { return }
            if let blocked, blocked.0 == revision, blocked.1 == sample.stamp { return }
            if state.isHost, !initialPublicationAttempted {
                guard sample.rate.isFinite, (0.25...4).contains(sample.rate) else {
                    blocked = (revision, sample.stamp)
                    onError?(WatchPartyPlayerBridgeError.invalidRate)
                    return
                }
                seedInitialPlayback(sample)
            }
            return
        }
        if playback.paused, readySample == nil, let sample = pauseSample() {
            guard playback.mediaKey == nil || playback.mediaKey == mediaKey,
                  playback.rate.isFinite, (0.25...4).contains(playback.rate) else {
                blocked = (revision, sample.stamp)
                onError?(WatchPartyPlayerBridgeError.invalidRate)
                return
            }
            if let blocked, blocked.0 == revision, blocked.1 == sample.stamp { return }
            guard lastApplied?.0 != playback || lastApplied?.1 != sample.stamp else { return }
            startRemotePause(playback, sample: sample)
            return
        }
        guard let sample = readySample else { return }
        if let blocked, blocked.0 == revision, blocked.1 == sample.stamp { return }
        guard playback.mediaKey == nil || playback.mediaKey == mediaKey,
              playback.rate.isFinite, (0.25...4).contains(playback.rate) else {
            blocked = (revision, sample.stamp)
            onError?(WatchPartyPlayerBridgeError.invalidRate)
            return
        }
        let force = lastApplied?.0 != playback || lastApplied?.1 != sample.stamp
        let now = uptime()
        guard now.isFinite else { return }
        if !force {
            if let lastSeekAt, now >= lastSeekAt, now - lastSeekAt < 2.5 { return }
            if let lastCorrectionAt, now >= lastCorrectionAt, now - lastCorrectionAt < 0.5 { return }
        }
        lastCorrectionAt = now
        let target = expected(playback, sample: sample)
        let correction = WatchPartyPolicy.correction(localPositionMs: sample.positionMs,
                                                    expectedPositionMs: target, playback: playback,
                                                    nudging: bridge.isApplyingTemporaryRate)
        let needsSeek: Bool
        if force { needsSeek = WatchPartyTimeMath.distance(sample.positionMs, target) > 500 }
        else { if case .seek = correction { needsSeek = true } else { needsSeek = false } }
        let transportMismatch = sample.paused != playback.paused
        let rateMismatch = !bridge.isApplyingTemporaryRate && abs(sample.rate - playback.rate) > 0.01
        if force || needsSeek || transportMismatch || rateMismatch {
            startRemote(playback, sample: sample, needsSeek: needsSeek)
        } else {
            do {
                switch correction {
                case .nudge(let rate):
                    let bounded = min(4, max(0.25, rate))
                    if abs(sample.rate - bounded) > 0.001 { _ = try bridge.setTemporaryRate(bounded) }
                case .inSync: bridge.clearTemporaryRate()
                case .seek: break
                }
            } catch { blocked = (revision, sample.stamp); onError?(error) }
        }
    }

    /// Pauses are transport-only room effects, so they do not wait for seek-ready samples.
    private func startRemotePause(_ playback: WatchPartyPlayback, sample initial: WatchPartyPlayerSample) {
        let mark = revision
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                self.worker = nil
                if !self.stopped, self.revision != mark { self.reconcile() }
            }
            do {
                let permit: @MainActor () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return self.admitted(mark, stamp: initial.stamp)
                        && !self.isBehind && self.state.playback == playback
                }
                try Task.checkCancellation()
                guard permit() else { throw WatchPartyPlaybackBindingError.staleOperation }
                _ = try await self.bridge.apply(WatchPartyPlayerEffect(paused: true, rate: playback.rate),
                                                origin: .remoteRoom, isPauseOnly: true, isAdmitted: permit)
                guard permit() else { throw WatchPartyPlaybackBindingError.staleOperation }
                self.lastApplied = (playback, initial.stamp)
            } catch {
                if self.active, self.revision == mark, !(error is CancellationError) {
                    self.blocked = (mark, initial.stamp)
                    self.onError?(error)
                }
            }
        }
    }

    private func startRemote(_ playback: WatchPartyPlayback, sample initial: WatchPartyPlayerSample, needsSeek: Bool) {
        let mark = revision
        let traceTransport = playback.memberID != memberID && playback.paused != initial.paused
        worker = Task { [weak self] in
            guard let self else { return }
            if traceTransport {
                PlaybackTimelineRecorder.record(playback.paused ? .partyRemotePauseStarted : .partyRemotePlayStarted)
            }
            defer {
                self.worker = nil
                if !self.stopped, self.revision != mark { self.reconcile() }
            }
            do {
                let permit: @MainActor () -> Bool = { [weak self] in self?.admitted(mark, stamp: initial.stamp) == true }
                let origin: WatchPartyEffectOrigin = playback.waiting ? .waiting : .remoteRoom
                if needsSeek {
                    // Seek paused first, then recompute room time before allowing play.
                    var converged = false
                    for _ in 0..<2 {
                        try Task.checkCancellation()
                        guard permit(), let sample = self.bridge.sample else { throw WatchPartyPlaybackBindingError.staleOperation }
                        let base = self.expected(playback, sample: sample)
                        let target = playback.paused ? base : WatchPartyTimeMath.add(base, self.seekLeadMs)
                        let started = self.uptime()
                        let receipt = try await self.bridge.apply(WatchPartyPlayerEffect(paused: true, rate: playback.rate, seekToMs: target),
                                                                 origin: origin, isAdmitted: permit)
                        guard permit(), let position = receipt.confirmedSeekPositionMs,
                              let latest = self.bridge.sample else { throw WatchPartyPlaybackBindingError.staleOperation }
                        let ended = self.uptime()
                        if ended.isFinite, started.isFinite, ended >= started {
                            self.seekLeadMs = min(3_000, WatchPartyTimeMath.integer((ended - started) * 1_000))
                            self.lastSeekAt = ended
                        }
                        let currentTarget = self.expected(playback, sample: latest)
                        if playback.paused || WatchPartyTimeMath.distance(position, currentTarget) <= WatchPartyPolicy.seekThresholdMs {
                            converged = true
                            break
                        }
                    }
                    guard converged else { throw WatchPartyPlaybackBindingError.seekTooSlow }
                }
                _ = try await self.bridge.apply(WatchPartyPlayerEffect(paused: playback.paused, rate: playback.rate),
                                                origin: origin, isAdmitted: permit)
                guard permit() else { throw WatchPartyPlaybackBindingError.staleOperation }
                self.lastApplied = (playback, initial.stamp)
                if traceTransport { PlaybackTimelineRecorder.record(.partyRemoteTransportIssued) }
            } catch {
                if self.active, self.revision == mark, !(error is CancellationError) {
                    if traceTransport { PlaybackTimelineRecorder.record(.partyRemoteEffectFailed) }
                    self.blocked = (mark, initial.stamp)
                    self.onError?(error)
                }
            }
        }
    }

    private func seedInitialPlayback(_ sample: WatchPartyPlayerSample) {
        initialPublicationAttempted = true // Ambiguous outcome must not repeat create/update implicitly.
        let mark = revision
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil; if self.revision != mark { self.reconcile() } }
            do {
                guard self.admitted(mark, stamp: sample.stamp), self.state.isHost,
                      self.state.playback == nil else { throw WatchPartyPlaybackBindingError.staleOperation }
                try await self.room.publish(paused: sample.paused, positionMs: sample.positionMs, rate: sample.rate, waiting: false)
            } catch { if self.active { self.onError?(error) } }
        }
    }

    /// Called only for an explicit control intent. Observer-driven reconciliation never calls publish.
    func perform(_ intent: WatchPartyLocalIntent, onApplied: (@MainActor () -> Void)? = nil,
                 refreshSample: (@MainActor () -> WatchPartyPlayerSample?)? = nil) async throws {
        try Task.checkCancellation()
        if case .pause = intent {
            try await performPause(onApplied: onApplied)
            return
        }
        switch intent {
        case .seek, .seekAndPlay:
            if let refreshSample { try refreshSampleForLocalSeek(refreshSample) }
        default: break
        }
        guard active, state.connected, let sample = usableSample() else { throw WatchPartyPlaybackBindingError.notReady }
        guard !localBusy, worker == nil else { throw WatchPartyPlaybackBindingError.busy }
        if case .catchUp = intent {
            guard onApplied == nil else { throw WatchPartyPlaybackBindingError.forbidden }
            isBehind = false; behindMs = nil
            // An explicit catch-up may retry a failed player correction; samples alone may not.
            retrySynchronization()
            return
        }
        let mark = revision
        let controlsRoom = state.canControl
        let previousBehind = isBehind
        var paused = sample.paused
        var rate = state.playback?.rate ?? sample.rate
        var target: Int64?
        switch intent {
        case .play: paused = false; if !controlsRoom && !isBehind { throw WatchPartyPlaybackBindingError.forbidden }
        case .pause: paused = true; if !controlsRoom { isBehind = true }
        case .toggle:
            paused = !sample.paused
            if !controlsRoom { if paused { isBehind = true } else if !isBehind { throw WatchPartyPlaybackBindingError.forbidden } }
        case .speed(let value):
            guard controlsRoom else { throw WatchPartyPlaybackBindingError.forbidden }
            rate = value
        case .seek(let value), .seekAndPlay(let value):
            let bounded = min(max(0, value), max(0, sample.durationMs - 1))
            if !controlsRoom {
                guard let playback = state.playback else { throw WatchPartyPlaybackBindingError.notReady }
                switch WatchPartyPolicy.ownSeek(targetMs: bounded, partyPositionMs: expected(playback, sample: sample), behind: isBehind) {
                case .behind(let position): isBehind = true; target = position
                case .catchUp:
                    // AVKit skip needs a concrete seek receipt, not a scheduled catch-up worker.
                    guard onApplied == nil else { throw WatchPartyPlaybackBindingError.forbidden }
                    isBehind = false; behindMs = nil; lastApplied = nil; reconcile(); return
                case .blocked: throw WatchPartyPlaybackBindingError.forbidden
                }
            } else { target = bounded }
            if case .seekAndPlay = intent { paused = false }
        case .catchUp: break
        }
        localBusy = true
        defer { localBusy = false }
        do {
            let permit: @MainActor () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.admitted(mark, stamp: sample.stamp) && self.state.canControl == controlsRoom
            }
            let receipt = try await bridge.apply(WatchPartyPlayerEffect(paused: paused, rate: rate, seekToMs: target),
                                                  origin: .localUser, isAdmitted: permit)
            guard permit() else { throw WatchPartyPlaybackBindingError.staleOperation }
            onApplied?()
            guard permit() else { throw WatchPartyPlaybackBindingError.staleOperation }
            if controlsRoom {
                let position = receipt.confirmedSeekPositionMs ?? bridge.sample?.positionMs ?? sample.positionMs
                try await room.publish(paused: paused, positionMs: position, rate: receipt.appliedRate, waiting: false)
                // Own publish changes the revision; only membership identity remains required here.
                guard active else { throw WatchPartyPlaybackBindingError.staleOperation }
            }
        } catch {
            if revision == mark { isBehind = state.canControl ? false : previousBehind }
            throw error
        }
    }

    /// The last poll may describe an active scrub even after UI commit cleared it.
    /// Refresh inside local admission so onSample cannot start automatic correction
    /// ahead of this explicit seek. Never adopt a different source or parked session.
    private func refreshSampleForLocalSeek(
        _ read: @MainActor () -> WatchPartyPlayerSample?
    ) throws {
        guard active, !suspended, state.connected, room.bindingState == state,
              let stamp = bridge.sample?.stamp else { throw WatchPartyPlaybackBindingError.notReady }
        guard !localBusy, worker == nil else { throw WatchPartyPlaybackBindingError.busy }
        let mark = revision
        localBusy = true
        defer { localBusy = false }
        guard let fresh = read(), fresh.stamp == stamp else {
            throw WatchPartyPlaybackBindingError.staleOperation
        }
        guard admitted(mark, stamp: stamp) else { throw WatchPartyPlaybackBindingError.staleOperation }
        bridge.observe(fresh)
        guard admitted(mark, stamp: stamp) else { throw WatchPartyPlaybackBindingError.staleOperation }
    }

    private func updatePresence(_ sample: WatchPartyPlayerSample) {
        let now = uptime()
        guard now.isFinite else { return }
        let status: WatchPartyMemberStatus
        if suspended || sample.failed { status = .browsing; bufferingSince = nil }
        else if isBehind { status = .behind; bufferingSince = nil }
        else if !sample.rendered { status = .loading; bufferingSince = nil }
        else if sample.loading || !sample.coherent || sample.seeking || bridge.isSeeking {
            if bufferingSince == nil || now < (bufferingSince ?? now) { bufferingSince = now }
            status = now - (bufferingSince ?? now) > 1 ? .buffering : .ready
        } else { status = .ready; bufferingSince = nil }
        desiredPresence = WatchPartyPresence(memberID: memberID, status: status, mediaKey: mediaKey,
                                            behindMs: status == .behind ? behindMs.map(WatchPartyPolicy.reportedGap) : nil)
        flushPresence()
    }

    private func flushPresence() {
        guard active, state.connected, presenceWorker == nil, let desiredPresence, desiredPresence != sentPresence else { return }
        if let failedPresence, failedPresence.0 == revision, failedPresence.1 == desiredPresence { return }
        presenceWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.presenceWorker = nil }
            while self.active, self.state.connected, !Task.isCancelled,
                  let value = self.desiredPresence, value != self.sentPresence {
                let mark = self.revision
                do {
                    try await self.room.setPresence(status: value.status, mediaKey: value.mediaKey, behindMs: value.behindMs)
                    guard self.active, self.state.connected, !Task.isCancelled else { return }
                    self.sentPresence = value
                    self.failedPresence = nil
                } catch {
                    self.failedPresence = (mark, value)
                    if self.active, !(error is CancellationError) { self.onError?(error) }
                    return
                }
            }
        }
    }
}

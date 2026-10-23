import Foundation

// Session contract adapted from PartyRepository.kt, NuvioMedia/NuvioTV (GPL-3.0), f7e2a78.
@MainActor
protocol WatchPartySessionRemote: AnyObject {
    func heartbeat(partyID: String, deviceID: String) async throws -> WatchPartySnapshot
    func clock() async throws -> Int64
    func leave(partyID: String, deviceID: String) async throws -> WatchPartySnapshot
    func end(partyID: String, deviceID: String) async throws -> WatchPartySnapshot
    func setHostOnly(partyID: String, deviceID: String, enabled: Bool) async throws -> WatchPartySnapshot
    func removeMember(partyID: String, deviceID: String, memberID: String) async throws -> WatchPartySnapshot
    func update(partyID: String, deviceID: String, media: WatchPartyMedia?,
                playback: WatchPartyPlayback?) async throws -> WatchPartySnapshot
}

extension WatchPartyAPI: WatchPartySessionRemote {}

extension WatchPartySessionRemote {
    /// Keeps lightweight test remotes source-compatible; the app's WatchPartyAPI implements this RPC.
    func setHostOnly(partyID: String, deviceID: String, enabled: Bool) async throws -> WatchPartySnapshot {
        throw WatchPartySessionError.operationUnavailable
    }

    func removeMember(partyID: String, deviceID: String, memberID: String) async throws -> WatchPartySnapshot {
        throw WatchPartySessionError.operationUnavailable
    }
}

enum WatchPartyConnectionState: Equatable { case stopped, connecting, reconciling, ready, recovering }
enum WatchPartySessionError: Error, Equatable { case invalidSnapshot, notReady, forbidden, operationUnavailable, sequenceExhausted }
enum WatchPartyMembershipExit: Equatable { case membershipLost, removed, ended, notFound, unavailable }

/// Minted only by the explicit host approval path; exact payload and current context are captured.
struct WatchPartyStreamConsent {
    fileprivate let nonce: UUID
    fileprivate let generation: UUID
    fileprivate let connectionID: UUID
    fileprivate let roomID: String
    fileprivate let memberID: String
    fileprivate let stream: WatchPartyStream
}

struct WatchPartySharedStreamSelection {
    let candidate: WatchPartyStreamCandidate
    fileprivate let generation: UUID
    fileprivate let connectionID: UUID
    fileprivate let revision: UUID
}

/// Owns one accepted create/join result. WatchPartyService replaces it on context changes.
/// No player, view, global Auth, or automatic create/join retries are owned here.
@MainActor
final class WatchPartySession {
    typealias ChannelFactory = @MainActor () -> any WatchPartyChannel
    typealias Sleep = @MainActor (UInt64) async throws -> Void

    private(set) var connection: WatchPartyConnectionState = .stopped
    private(set) var party: WatchPartyInfo?
    private(set) var memberID: String?
    private(set) var members: [WatchPartyMember] = []
    private(set) var playback: WatchPartyPlayback?
    private(set) var presence: [String: WatchPartyPresence] = [:]
    private(set) var failure: WatchPartyFailure?
    private(set) var membershipExit: WatchPartyMembershipExit?
    var onChange: (@MainActor () -> Void)?
    private(set) var sharedStream: WatchPartyStream?
    private(set) var isSharingStream = false
    private(set) var activeHostStream: WatchPartyStream?
    /// A received candidate is inert. The future UI must explicitly select it before resolution/playback.
    var onStream: (@MainActor (WatchPartyStream?) -> Void)?

    private let remote: any WatchPartySessionRemote
    private let context: WatchPartyRequestContext
    private let isCurrent: WatchPartyAPI.ContextValidator
    private let deviceID: String
    private let makeChannel: ChannelFactory
    private let sleep: Sleep
    private let connectionTasksEnabled: Bool
    private var clock: WatchPartyClock
    private var generation = UUID()
    private var connectionID = UUID()
    private var authoritativeSnapshotRevision = UUID()
    private var outboundSequence: Int64 = 0
    private var channel: (any WatchPartyChannel)?
    private var recoveryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var coordinatorTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var waitingCoordinator = WatchPartyWaitingCoordinator()
    private var persistTask: Task<Void, Never>?
    private var persistenceID = UUID()
    private var pendingPersistence: WatchPartyPlayback?
    private var persistenceDeadline: TimeInterval?
    private var localPresence: WatchPartyPresence?
    private var changeObservers: [UUID: @MainActor () -> Void] = [:]
    private var noticeObservers: [UUID: @MainActor (WatchPartyNotice) -> Void] = [:]
    private var chatObservers: [UUID: @MainActor (WatchPartyChatMessage) -> Void] = [:]
    private var streamConsentNonce: UUID?
    private var sharedStreamRevision = UUID()
    // Android-compatible manual state_request; not durable room storage.
    private var lastManualSourceRequestAt: Date?
    private var playbackMembershipID = UUID()

    /// Stable during reconnects, replaced on a true membership reset; contains no access token.
    var playbackContext: WatchPartyPlaybackContext? {
        guard let party, let memberID else { return nil }
        return WatchPartyPlaybackContext(request: context, membershipID: playbackMembershipID,
                                         roomID: party.id, memberID: memberID, mediaKey: party.media.key)
    }

    init(remote: any WatchPartySessionRemote, context: WatchPartyRequestContext, deviceID: String,
         isCurrent: @escaping WatchPartyAPI.ContextValidator, makeChannel: @escaping ChannelFactory,
         clock: WatchPartyClock = WatchPartyClock(),
         connectionTasksEnabled: Bool = true,
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }) {
        self.remote = remote
        self.context = context
        self.deviceID = deviceID
        self.isCurrent = isCurrent
        self.makeChannel = makeChannel
        self.clock = clock
        self.sleep = sleep
        self.connectionTasksEnabled = connectionTasksEnabled
    }

    /// Independent subscriptions leave WatchPartyService's legacy onChange callback intact.
    @discardableResult
    func observeChanges(_ callback: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        changeObservers[id] = callback
        return id
    }

    func removeChangeObserver(_ id: UUID) { changeObservers.removeValue(forKey: id) }

    @discardableResult
    func observeNotices(_ callback: @escaping @MainActor (WatchPartyNotice) -> Void) -> UUID {
        let id = UUID()
        noticeObservers[id] = callback
        return id
    }

    func removeNoticeObserver(_ id: UUID) { noticeObservers.removeValue(forKey: id) }

    @discardableResult
    func observeChat(_ callback: @escaping @MainActor (WatchPartyChatMessage) -> Void) -> UUID {
        let id = UUID()
        chatObservers[id] = callback
        return id
    }

    func removeChatObserver(_ id: UUID) { chatObservers.removeValue(forKey: id) }

    private func notifyChatMessage(_ message: WatchPartyChatMessage) {
        let callbacks = chatObservers
        for (id, callback) in callbacks where chatObservers[id] != nil { callback(message) }
    }

    private func notifyNotice(_ message: String, member: WatchPartyMember? = nil) {
        let initials = member.flatMap {
            let trimmed = $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(1)).uppercased()
        }
        let notice = WatchPartyNotice(
            message: message,
            avatarURL: member?.avatarURL,
            avatarColor: member?.avatarColor,
            initials: initials
        )
        let callbacks = noticeObservers
        for (id, callback) in callbacks where noticeObservers[id] != nil { callback(notice) }
    }

    static func formatNoticeTime(millis: Int64) -> String {
        let totalSeconds = max(0, millis / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private func notifyChange() {
        let callbacks = changeObservers
        onChange?()
        for (id, callback) in callbacks where changeObservers[id] != nil { callback() }
    }

    var canControl: Bool {
        guard connection == .ready, let party, let memberID, isCurrent(context) else { return false }
        return !party.hostOnly || party.hostMemberID == memberID
    }

    func nowMs() -> Int64 { clock.nowMs() }

    /// Does not repeat a create/join whose remote outcome may be ambiguous.
    func start(snapshot: WatchPartySnapshot) async throws {
        stop()
        try checkContext()
        guard snapshot.error == nil, let info = snapshot.party, !info.id.isEmpty,
              let member = snapshot.memberID, !member.isEmpty,
              snapshot.members.contains(where: { $0.id == member }) else { throw WatchPartySessionError.invalidSnapshot }
        party = info
        memberID = member
        members = snapshot.members
        playback = validPlayback(info.playback, for: info)
        localPresence = WatchPartyPresence(memberID: member)
        failure = nil
        let epoch = generation
        do {
            try await connect(epoch: epoch)
            if active(epoch) { startHeartbeat(epoch: epoch) }
        } catch {
            if generation == epoch, Task.isCancelled || !isCurrent(context) { stop() }
            else if active(epoch) {
                invalidateConnection()
                scheduleRecovery(epoch: epoch)
                startHeartbeat(epoch: epoch)
            }
            throw error
        }
    }

    /// Called explicitly on account/backend/profile loss or true membership teardown.
    func stop() {
        clearState()
        notifyChange()
    }

    /// Applies only the server-returned room snapshot; local state never assumes the mutation succeeded.
    func setHostOnly(_ enabled: Bool) async throws {
        try requireReady(generation)
        guard let party, let memberID, party.hostMemberID == memberID else {
            throw WatchPartySessionError.forbidden
        }
        guard channel?.isConnected == true else { throw WatchPartySessionError.notReady }
        let epoch = generation
        let attempt = connectionID
        let roomID = party.id
        let requestingMemberID = memberID
        let snapshotRevision = authoritativeSnapshotRevision
        do {
            let snapshot = try await remote.setHostOnly(partyID: party.id, deviceID: deviceID, enabled: enabled)
            try checkContext()
            guard generation == epoch, self.party?.id == roomID, self.memberID == requestingMemberID else {
                throw WatchPartyAPIError.staleContext
            }
            // A control broadcast may invalidate this channel before the mutation RPC returns.
            // The response is still authoritative for the same live membership, so apply it
            // without reviving or reopening that connection. If recovery has already reconciled
            // a newer server snapshot, preserve that newer state instead of rolling it back.
            if authoritativeSnapshotRevision == snapshotRevision { try apply(snapshot) }
        } catch {
            if shouldRecover(after: error) { lost(epoch: epoch, attempt: attempt) }
            throw error
        }
    }

    /// Removes one other room member; only the current host may request this mutation.
    func removeMember(_ targetMemberID: String) async throws {
        try requireReady(generation)
        guard let party, let memberID, party.hostMemberID == memberID,
              targetMemberID != memberID,
              members.contains(where: { $0.id == targetMemberID }) else {
            throw WatchPartySessionError.forbidden
        }
        guard channel?.isConnected == true else { throw WatchPartySessionError.notReady }
        let epoch = generation
        let attempt = connectionID
        let roomID = party.id
        let requestingMemberID = memberID
        let snapshotRevision = authoritativeSnapshotRevision
        do {
            let snapshot = try await remote.removeMember(
                partyID: party.id, deviceID: deviceID, memberID: targetMemberID
            )
            try checkContext()
            guard generation == epoch, self.party?.id == roomID, self.memberID == requestingMemberID else {
                throw WatchPartyAPIError.staleContext
            }
            // The RPC broadcast can invalidate the realtime channel. Apply its snapshot only
            // while no newer recovery snapshot has already reconciled the membership.
            if authoritativeSnapshotRevision == snapshotRevision { try apply(snapshot) }
        } catch {
            if shouldRecover(after: error) { lost(epoch: epoch, attempt: attempt) }
            throw error
        }
    }

    /// Changes the room's exact episode after an explicit host selection. Playback state is
    /// omitted so an old episode position can never be applied to the new media key.
    func updateMedia(_ media: WatchPartyMedia) async throws {
        try requireReady(generation)
        guard let party, let memberID, party.hostMemberID == memberID else {
            throw WatchPartySessionError.forbidden
        }
        guard media.metaID == party.media.metaID,
              media.metaType.caseInsensitiveCompare("series") == .orderedSame,
              party.media.metaType.caseInsensitiveCompare("series") == .orderedSame,
              media.key != party.media.key else {
            throw WatchPartyLaunchError.differentMedia
        }
        try WatchPartyLaunchPolicy.validate(media)
        guard channel?.isConnected == true else { throw WatchPartySessionError.notReady }

        let epoch = generation
        let attempt = connectionID
        let roomID = party.id
        let requestingMemberID = memberID
        let snapshotRevision = authoritativeSnapshotRevision
        cancelPersistence()
        do {
            let snapshot = try await remote.update(
                partyID: party.id, deviceID: deviceID, media: media, playback: nil
            )
            try checkContext()
            guard generation == epoch, self.party?.id == roomID, self.memberID == requestingMemberID else {
                throw WatchPartyAPIError.staleContext
            }
            // A room event may apply the same media update before the RPC returns.
            // Keep that newer snapshot instead of overwriting it with a late response.
            if authoritativeSnapshotRevision == snapshotRevision { try apply(snapshot) }
            // The backend may broadcast media invalidation just before or just after the
            // update response, and a concurrent heartbeat can carry an older snapshot. Reconnect
            // unconditionally before checking the media key so the accepted server state wins.
            try await reconnect()
            guard connection == .ready, self.party?.id == roomID,
                  self.memberID == requestingMemberID, self.party?.media.key == media.key else {
                throw WatchPartySessionError.notReady
            }
        } catch {
            if shouldRecover(after: error) { lost(epoch: epoch, attempt: attempt) }
            throw error
        }
    }

    private func shouldRecover(after error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? WatchPartyAPIError else { return true }
        switch error {
        case .transport, .invalidResponse: return true
        case .httpStatus(let status): return status >= 500
        case .invalidConfiguration, .staleContext, .signInRequired, .invalidCode: return false
        }
    }

    private func clearState() {
        playbackMembershipID = UUID()
        generation = UUID()
        recoveryTask?.cancel(); recoveryTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        cancelConnectionTasks()
        cancelPersistence()
        channel?.close(); channel = nil
        connection = .stopped
        party = nil; memberID = nil; members = []; playback = nil; presence = [:]
        localPresence = nil
        outboundSequence = 0
        failure = nil
        membershipExit = nil
        waitingCoordinator.reset()
        clearSharedStream()
        lastManualSourceRequestAt = nil
        clock.reset()
    }

    /// Call from the future service's foreground/auth-refresh transition, preserving PiP ownership.
    func reconnect() async throws {
        try checkContext()
        guard party != nil else { throw WatchPartySessionError.notReady }
        recoveryTask?.cancel(); recoveryTask = nil
        // Invalidate the old attempt before any await; old listeners cannot publish into this one.
        generation = UUID()
        heartbeatTask?.cancel(); heartbeatTask = nil
        invalidateConnection()
        let epoch = generation
        do { try await connect(epoch: epoch) }
        catch {
            if generation == epoch, Task.isCancelled || !isCurrent(context) { stop() }
            else if active(epoch) { invalidateConnection(); scheduleRecovery(epoch: epoch) }
            if active(epoch) { startHeartbeat(epoch: epoch) }
            throw error
        }
        if active(epoch) { startHeartbeat(epoch: epoch) }
    }

    func setPresence(status: WatchPartyMemberStatus, mediaKey: String?, behindMs: Int64? = nil) async throws {
        try checkContext()
        guard let memberID else { throw WatchPartySessionError.notReady }
        let value = WatchPartyPresence(memberID: memberID, status: status, mediaKey: mediaKey, behindMs: behindMs)
        // Presence is current local state, not an offline gesture queue.
        localPresence = value
        presence[memberID] = value
        if status == .ready { waitingCoordinator.memberReady(memberID) }
        notifyChange()
        guard connection == .ready, let channel else { return }
        let epoch = generation
        let attempt = connectionID
        do {
            try await channel.track(value)
            try checkAttempt(epoch, channel: channel)
            try requireReady(epoch)
            try await send("status", value, epoch: epoch)
        } catch {
            lost(epoch: epoch, attempt: attempt)
            throw error
        }
    }

    /// Called only by an explicit user approval after reviewing the link and all included headers.
    /// No caller in the app invokes this yet; the future UI/runtime supplies the actual source origin.
    func approveStreamSharing(_ stream: WatchPartyStream, origin: WatchPartyStreamOrigin) throws -> WatchPartyStreamConsent {
        streamConsentNonce = nil
        try requireReady(generation)
        guard let party, let memberID, party.hostMemberID == memberID else { throw WatchPartyStreamError.notHost }
        guard origin == .directHTTP else { throw WatchPartyStreamError.unsupportedSource }
        guard stream.mediaKey == party.media.key else { throw WatchPartyStreamError.wrongMedia }
        try WatchPartyStreamPolicy.validate(stream)
        guard try JSONEncoder().encode(WatchPartyStreamMessage(memberID: memberID, stream: stream)).count
                <= WatchPartyStreamPolicy.maximumPayloadBytes else { throw WatchPartyStreamError.oversizedPayload }
        let nonce = UUID()
        streamConsentNonce = nonce
        return WatchPartyStreamConsent(nonce: nonce, generation: generation, connectionID: connectionID,
                                       roomID: party.id, memberID: memberID, stream: stream)
    }

    func revokeStreamConsent() { streamConsentNonce = nil }

    /// One approval authorizes one exact send. No source URL is automatically resent on reconnect/state_request.
    func shareStream(_ stream: WatchPartyStream, consent: WatchPartyStreamConsent) async throws {
        try requireReady(generation)
        guard let party, let memberID, party.hostMemberID == memberID else { throw WatchPartyStreamError.notHost }
        guard stream.mediaKey == party.media.key else { throw WatchPartyStreamError.wrongMedia }
        guard consent.nonce == streamConsentNonce, consent.generation == generation,
              consent.connectionID == connectionID, consent.roomID == party.id,
              consent.memberID == memberID, consent.stream == stream else { throw WatchPartyStreamError.consentRequired }
        try WatchPartyStreamPolicy.validate(stream)
        streamConsentNonce = nil // Consume before the first await, including an ambiguous failed send.
        let epoch = generation, attempt = connectionID
        do { try await send("stream", WatchPartyStreamMessage(memberID: memberID, stream: stream), epoch: epoch) }
        catch { lost(epoch: epoch, attempt: attempt); throw error }
        isSharingStream = true
        activeHostStream = stream
        notifyChange()
    }

    /// Revocation can clear an already shared candidate but cannot retract a URL a peer has received.
    func stopSharingStream() async throws {
        revokeStreamConsent()
        try requireReady(generation)
        guard let memberID, party?.hostMemberID == memberID else { throw WatchPartyStreamError.notHost }
        isSharingStream = false
        activeHostStream = nil
        notifyChange()
        let epoch = generation, attempt = connectionID
        do { try await send("stream", WatchPartyStreamMessage(memberID: memberID, stream: nil), epoch: epoch) }
        catch { lost(epoch: epoch, attempt: attempt); throw error }
    }

    /// Requests an Android-compatible host resend only when a guest explicitly asks.
    /// No server persistence, automatic retry, or implied playback authorization.
    func requestHostStreamRefresh() async throws -> Bool {
        let epoch = generation
        try requireReady(epoch)
        guard let party, let memberID, let hostID = party.hostMemberID,
              memberID != hostID, sharedStream == nil else {
            throw WatchPartyStreamError.unavailable
        }
        let now = Date()
        if let last = lastManualSourceRequestAt, now.timeIntervalSince(last) < 10 {
            return false
        }
        lastManualSourceRequestAt = now
        let attempt = connectionID
        do {
            try await send("state_request", MemberPayload(memberID: memberID), epoch: epoch)
            return true
        } catch {
            // Ambiguous delivery: never replay automatically; reconcile first.
            lost(epoch: epoch, attempt: attempt)
            throw error
        }
    }

    /// Explicit guest selection returns all metadata, including response headers missing in NuvioStream.
    func selectSharedStream(_ expected: WatchPartyStream) throws -> WatchPartySharedStreamSelection {
        try requireReady(generation)
        guard let party, memberID != party.hostMemberID, sharedStream == expected,
              expected.mediaKey == party.media.key else { throw WatchPartyStreamError.unavailable }
        return WatchPartySharedStreamSelection(candidate: try expected.playbackCandidate(), generation: generation,
                                               connectionID: connectionID, revision: sharedStreamRevision)
    }

    /// The future async resolver/player binding must recheck this after each suspension.
    func isCurrentSharedStreamSelection(_ selection: WatchPartySharedStreamSelection) -> Bool {
        !Task.isCancelled && isCurrent(context) && connection == .ready && channel?.isConnected == true
            && selection.generation == generation && selection.connectionID == connectionID
            && selection.revision == sharedStreamRevision && sharedStream == selection.candidate.metadata
            && selection.candidate.metadata.mediaKey == party?.media.key
    }

    private func clearSharedStream() {
        streamConsentNonce = nil
        sharedStreamRevision = UUID()
        isSharingStream = false
        activeHostStream = nil
        if sharedStream != nil { sharedStream = nil; onStream?(nil) }
    }

    /// The future intent dispatcher calls this only after admitting a local user/coordinator action.
    /// Remote playback acceptance never calls publish, preventing echo loops.
    func publish(paused: Bool, positionMs: Int64, rate: Float, waiting: Bool = false) async throws {
        try checkContext()
        guard connection == .ready, let party, let memberID else { throw WatchPartySessionError.notReady }
        guard canControl else { throw WatchPartySessionError.forbidden }
        guard rate.isFinite, rate > 0 else { throw WatchPartyChannelError.invalidPayload }
        let seq = max(playback?.seq ?? 0, outboundSequence)
        guard seq < Int64.max else { throw WatchPartySessionError.sequenceExhausted }
        outboundSequence = seq + 1
        let next = WatchPartyPlayback(seq: seq + 1, memberID: memberID, paused: paused,
                                     positionMs: max(0, positionMs), rate: min(4, max(0.25, rate)),
                                     at: clock.nowMs(), mediaKey: party.media.key, waiting: waiting)
        let epoch = generation
        let attempt = connectionID
        do {
            try await send("state", next, epoch: epoch)
            // A newer remote state can arrive while send awaits. Never overwrite it on completion.
            try requireReady(epoch)
            accept(next)
        } catch { lost(epoch: epoch, attempt: attempt); throw error }
        if playback == next, active(epoch), connectionID == attempt {
            schedulePersistence(next, epoch: epoch, attempt: attempt)
        }
    }

    func leave(endForEveryone: Bool = false) async throws {
        try checkContext()
        guard let party else { return }
        if endForEveryone, party.hostMemberID != memberID { throw WatchPartySessionError.forbidden }
        // Close locally first. One mutation attempt only; transport failure is an ambiguous outcome.
        stop()
        let stoppedEpoch = generation
        let result = try await (endForEveryone
            ? remote.end(partyID: party.id, deviceID: deviceID)
            : remote.leave(partyID: party.id, deviceID: deviceID))
        try checkContext()
        guard generation == stoppedEpoch else { throw WatchPartyAPIError.staleContext }
        if let error = WatchPartyFailure(serverCode: result.error) { failure = error; notifyChange() }
    }

    private func connect(epoch: UUID) async throws {
        try checkContext()
        guard active(epoch), let party, let memberID else { throw WatchPartySessionError.notReady }
        connection = .connecting; notifyChange()
        let created = makeChannel()
        let attempt = connectionID
        channel = created
        try await created.open(partyID: party.id, memberID: memberID) { [weak self, weak created] event in
            guard let self, let created, self.active(epoch), self.channel === created else { return }
            self.receive(event, epoch: epoch, attempt: attempt)
        }
        try checkAttempt(epoch, channel: created)
        connection = .reconciling; notifyChange()
        let sent = clock.mark()
        let snapshot = try await remote.heartbeat(partyID: party.id, deviceID: deviceID)
        try checkAttempt(epoch, channel: created)
        try apply(snapshot)
        if let server = snapshot.serverTimeMs { clock.addSample(serverMs: server, sentAt: sent) }
        // Refine before admitting gestures; use the same existing auth/RPC path.
        let clockSent = clock.mark()
        let server = try await remote.clock()
        try checkAttempt(epoch, channel: created)
        clock.addSample(serverMs: server, sentAt: clockSent)
        var own: WatchPartyPresence
        repeat {
            own = localPresence ?? WatchPartyPresence(memberID: memberID)
            try await created.track(own)
            try checkAttempt(epoch, channel: created)
            // A loading/ready transition during the await supersedes the initial presence.
        } while localPresence != nil && localPresence != own
        presence[memberID] = own
        connection = .ready; failure = nil; notifyChange()
        try await send("status", own, epoch: epoch)
        try await send("state_request", MemberPayload(memberID: memberID), epoch: epoch)
        if isSharingStream, let stream = activeHostStream, party.hostMemberID == memberID, stream.mediaKey == party.media.key {
            try await send("stream", WatchPartyStreamMessage(memberID: memberID, stream: stream), epoch: epoch)
        }
        startConnectionTasks(epoch: epoch, attempt: attempt)
    }

    private func checkContext() throws {
        try Task.checkCancellation()
        guard isCurrent(context) else { throw WatchPartyAPIError.staleContext }
    }

    private func active(_ epoch: UUID) -> Bool { generation == epoch && party != nil && isCurrent(context) }

    private func checkAttempt(_ epoch: UUID, channel: any WatchPartyChannel) throws {
        try checkContext()
        guard active(epoch), self.channel === channel, channel.isConnected else { throw WatchPartyChannelError.disconnected }
    }

    private func requireReady(_ epoch: UUID) throws {
        try checkContext()
        guard active(epoch), connection == .ready, channel?.isConnected == true else { throw WatchPartySessionError.notReady }
    }

    private func send<T: Encodable>(_ event: String, _ value: T, epoch: UUID) async throws {
        try requireReady(epoch)
        guard let channel else { throw WatchPartySessionError.notReady }
        let payload = try JSONEncoder().encode(value)
        try await channel.send(event: event, payload: payload)
        guard self.channel === channel else { throw WatchPartyAPIError.staleContext }
        try requireReady(epoch)
    }

    private func invalidateConnection() {
        connectionID = UUID()
        cancelConnectionTasks()
        waitingCoordinator.disconnected()
        cancelPersistence()
        channel?.close(); channel = nil
        connection = .recovering
        if party?.hostMemberID != memberID {
            clearSharedStream()
        } else {
            sharedStream = nil
            sharedStreamRevision = UUID()
        }
        presence = presence.filter { $0.key == memberID }
        notifyChange()
    }

    private func cancelConnectionTasks() {
        coordinatorTask?.cancel(); coordinatorTask = nil
        clockTask?.cancel(); clockTask = nil
    }

    private func startConnectionTasks(epoch: UUID, attempt: UUID) {
        cancelConnectionTasks()
        guard connectionTasksEnabled else { return }
        let sleep = self.sleep
        coordinatorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(WatchPartyWaitingCoordinator.tickNanoseconds) } catch { return }
                guard let self, self.active(epoch), self.connectionID == attempt, !Task.isCancelled else { return }
                guard self.connection == .ready, let party = self.party,
                      let memberID = self.memberID, let playback = self.playback else {
                    await Task.yield()
                    continue
                }
                let decision = self.waitingCoordinator.decision(party: party, memberID: memberID,
                                                              members: self.members, presence: self.presence,
                                                              playback: playback, connected: self.channel?.isConnected == true,
                                                              uptime: self.clock.mark(), serverNowMs: self.clock.nowMs())
                guard let decision else { continue }
                do {
                    switch decision {
                    case .pause(let position):
                        try await self.publish(paused: true, positionMs: position, rate: playback.rate, waiting: true)
                    case .resume(let position):
                        try await self.publish(paused: false, positionMs: position, rate: playback.rate)
                    }
                } catch {
                    guard self.active(epoch), self.connectionID == attempt, !Task.isCancelled else { return }
                    // Never queue or replay a coordinator decision after a failed admission/send.
                }
            }
        }
        // One initial sample was taken before admission. Three more complete four RPC samples.
        clockTask = Task { [weak self] in
            for _ in 0..<3 {
                do { try await sleep(400_000_000) } catch { return }
                guard let self, self.active(epoch), self.connectionID == attempt, !Task.isCancelled else { return }
                let sent = self.clock.mark()
                do {
                    let server = try await self.remote.clock()
                    guard self.active(epoch), self.connectionID == attempt, !Task.isCancelled else { return }
                    self.clock.addSample(serverMs: server, sentAt: sent)
                } catch {
                    guard self.active(epoch), self.connectionID == attempt, !Task.isCancelled else { return }
                    // Keep the existing anchor when a refinement sample fails.
                }
            }
        }
    }

    private func cancelPersistence() {
        persistenceID = UUID()
        persistTask?.cancel(); persistTask = nil
        pendingPersistence = nil
        persistenceDeadline = nil
    }

    /// One serial worker: debounce pending state, finish one RPC, then consider the latest state.
    /// A newer gesture never cancels an in-flight HTTP mutation just to start a competing one.
    private func schedulePersistence(_ value: WatchPartyPlayback, epoch: UUID, attempt: UUID) {
        pendingPersistence = value
        persistenceDeadline = clock.mark() + 1.5
        guard persistTask == nil else { return }
        let worker = UUID()
        persistenceID = worker
        let sleep = self.sleep
        persistTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = self?.persistenceDeadline else { return }
                let remaining = max(0, deadline - (self?.clock.mark() ?? deadline))
                let delay = UInt64(max(0, WatchPartyTimeMath.integer(remaining * 1_000_000_000)))
                do { try await sleep(delay) } catch { return }
                guard let self, self.active(epoch), self.connectionID == attempt,
                      self.persistenceID == worker, !Task.isCancelled else { return }
                // A new gesture during sleep moves the deadline; wait only its remaining interval.
                if let deadline = self.persistenceDeadline, self.clock.mark() < deadline { continue }
                guard self.canControl, let party = self.party, let value = self.pendingPersistence,
                      value == self.playback, value.mediaKey == party.media.key else {
                    self.pendingPersistence = nil
                    self.persistenceDeadline = nil
                    self.persistTask = nil
                    return
                }
                self.pendingPersistence = nil
                self.persistenceDeadline = nil
                do {
                    let snapshot = try await self.remote.update(partyID: party.id, deviceID: self.deviceID,
                                                               media: nil, playback: value)
                    guard self.active(epoch), self.connectionID == attempt, self.persistenceID == worker,
                          self.party?.media.key == value.mediaKey, !Task.isCancelled else { return }
                    try self.apply(snapshot)
                } catch {
                    guard self.active(epoch), self.connectionID == attempt,
                          self.persistenceID == worker, !Task.isCancelled else { return }
                    // The request may already have reached the server. Never retry it automatically.
                    self.failure = .network
                    self.notifyChange()
                }
                guard self.persistenceID == worker else { return }
                if self.pendingPersistence == nil { self.persistTask = nil; return }
            }
        }
    }

    private func lost(epoch: UUID, attempt: UUID) {
        guard active(epoch), connectionID == attempt else { return }
        let opening = connection == .connecting || connection == .reconciling
        invalidateConnection()
        // The in-flight connect catches its failure and owns scheduling in this case.
        if !opening { scheduleRecovery(epoch: epoch) }
    }

    private func scheduleRecovery(epoch: UUID) {
        guard active(epoch), recoveryTask == nil else { return }
        let sleep = self.sleep
        recoveryTask = Task { [weak self] in
            var delay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                do { try await sleep(delay) } catch { break }
                guard let self, self.active(epoch) else { break }
                do {
                    try await self.connect(epoch: epoch)
                    if self.active(epoch) { self.recoveryTask = nil }
                    return
                } catch {
                    guard self.active(epoch), !Task.isCancelled else { break }
                    self.invalidateConnection()
                    delay = min(delay * 2, 30_000_000_000)
                }
            }
        }
    }

    private func startHeartbeat(epoch: UUID) {
        guard connectionTasksEnabled else { return }
        let sleep = self.sleep
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(120_000_000_000) } catch { return }
                guard let self, self.active(epoch) else { return }
                guard self.connection == .ready, let party = self.party else { continue }
                let attempt = self.connectionID
                do {
                    let snapshot = try await self.remote.heartbeat(partyID: party.id, deviceID: self.deviceID)
                    guard self.active(epoch), !Task.isCancelled else { return }
                    guard self.connectionID == attempt else { continue }
                    try self.apply(snapshot)
                    try await self.channel?.refreshAuth()
                    guard self.active(epoch), self.connectionID == attempt, !Task.isCancelled else { continue }
                } catch {
                    if self.active(epoch), !Task.isCancelled { self.lost(epoch: epoch, attempt: attempt) }
                }
            }
        }
    }

    private func validPlayback(_ value: WatchPartyPlayback?, for party: WatchPartyInfo) -> WatchPartyPlayback? {
        guard let value, value.mediaKey == nil || value.mediaKey == party.media.key,
              !party.hostOnly || value.memberID == party.hostMemberID else { return nil }
        return value
    }

    private func accept(_ value: WatchPartyPlayback) {
        let remoteTransition = value.memberID != memberID && playback?.paused != value.paused
        guard let party, validPlayback(value, for: party) != nil,
              WatchPartyPolicy.isNewer(value, than: playback) else {
            if remoteTransition { PlaybackTimelineRecorder.record(.partyStateRejected) }
            return
        }
        waitingCoordinator.accepted(previous: playback, next: value, mediaKey: party.media.key,
                                    presence: presence, uptime: clock.mark())
        let previous = playback
        playback = value
        if remoteTransition {
            PlaybackTimelineRecorder.record(value.paused ? .partyPauseAccepted : .partyPlayAccepted)
        }
        if let action = WatchPartyPolicy.action(previous: previous, next: value),
           let senderID = value.memberID ?? (party.hostOnly ? party.hostMemberID : nil),
           senderID != memberID {
            let member = members.first(where: { $0.id == senderID })
            let name = member?.displayName ?? "Someone"
            switch action {
            case .paused:
                notifyNotice("\(name) paused", member: member)
            case .resumed:
                notifyNotice("\(name) resumed", member: member)
            case .seeked:
                notifyNotice("\(name) skipped to \(Self.formatNoticeTime(millis: value.positionMs))", member: member)
            case .speed:
                break
            }
        }
        notifyChange()
    }

    private func apply(_ snapshot: WatchPartySnapshot) throws {
        if snapshot.error == "not_member" {
            finishMembership(.membershipLost, failure: .removed)
            throw WatchPartySessionError.invalidSnapshot
        }
        if let error = WatchPartyFailure(serverCode: snapshot.error) {
            switch error {
            case .removed: finishMembership(.removed, failure: error)
            case .ended: finishMembership(.ended, failure: error)
            case .notFound: finishMembership(.notFound, failure: error)
            case .unavailable: finishMembership(.unavailable, failure: error)
            default: failure = error; notifyChange()
            }
            throw WatchPartySessionError.invalidSnapshot
        }
        guard let info = snapshot.party, info.id == party?.id,
              snapshot.memberID == nil || snapshot.memberID == memberID,
              snapshot.members.contains(where: { $0.id == memberID }) else { throw WatchPartySessionError.invalidSnapshot }
        let mediaChanged = info.media.key != party?.media.key
        if mediaChanged || info.hostMemberID != party?.hostMemberID { clearSharedStream() }
        if !members.isEmpty {
            let newMembers = snapshot.members.filter { sm in !self.members.contains { $0.id == sm.id } }
            for newMember in newMembers where newMember.id != memberID {
                notifyNotice("\(newMember.displayName) joined the watch party", member: newMember)
            }
        }
        party = info; members = snapshot.members
        presence = presence.filter { key, _ in members.contains { $0.id == key } }
        waitingCoordinator.retainMembers(Set(members.map(\.id)))
        if mediaChanged || validPlayback(playback, for: info) == nil {
            if mediaChanged { waitingCoordinator.reset() }
            playback = validPlayback(info.playback, for: info)
        } else if let value = info.playback { accept(value) }
        authoritativeSnapshotRevision = UUID()
        notifyChange()
    }

    private func finishMembership(_ reason: WatchPartyMembershipExit, failure: WatchPartyFailure) {
        clearState()
        membershipExit = reason
        self.failure = failure
        notifyChange()
    }

    private func receive(_ event: WatchPartyChannelEvent, epoch: UUID, attempt: UUID) {
        guard connectionID == attempt else { return }
        if case .disconnected = event { lost(epoch: epoch, attempt: attempt); return }
        // Snapshot first, then state_request. Do not replay messages collected during reconciliation.
        guard connection == .ready, let party, let memberID else { return }
        switch event {
        case .disconnected: break
        case let .presence(joins, leaves):
            for key in leaves where key != memberID && joins[key] == nil { presence[key] = nil }
            for (key, var value) in joins where key != memberID && members.contains(where: { $0.id == key }) {
                value.memberID = key
                // Preserve more recent status broadcasts, as Android does.
                if presence[key] == nil {
                    if value.status == .ready { waitingCoordinator.memberReady(key) }
                    presence[key] = value
                }
            }
            notifyChange()
        case let .message(name, data):
            switch name {
            case "state":
                if let value = try? JSONDecoder().decode(WatchPartyPlayback.self, from: data) {
                    let remoteTransition = value.memberID != memberID && playback?.paused != value.paused
                    if remoteTransition {
                        PlaybackTimelineRecorder.record(value.paused ? .partyPauseReceived : .partyPlayReceived)
                    }
                    if value.memberID == nil || members.contains(where: { $0.id == value.memberID }) {
                        accept(value)
                    } else if remoteTransition {
                        PlaybackTimelineRecorder.record(.partyStateRejected)
                    }
                }
            case "status":
                if let value = try? JSONDecoder().decode(WatchPartyPresence.self, from: data),
                   value.memberID != memberID, members.contains(where: { $0.id == value.memberID }) {
                    if value.status == .ready { waitingCoordinator.memberReady(value.memberID) }
                    presence[value.memberID] = value; notifyChange()
                }
            case "state_request":
                guard let request = try? JSONDecoder().decode(MemberPayload.self, from: data), request.memberID != memberID else { return }
                Task { [weak self] in
                    guard let self, self.active(epoch), self.connectionID == attempt, self.connection == .ready else { return }
                    do {
                        if let own = self.localPresence { try await self.send("status", own, epoch: epoch) }
                        if let playback = self.playback { try await self.send("state", playback, epoch: epoch) }
                        if self.isSharingStream, let stream = self.activeHostStream,
                           self.party?.hostMemberID == self.memberID, stream.mediaKey == self.party?.media.key {
                            try await self.send("stream", WatchPartyStreamMessage(memberID: self.memberID ?? "", stream: stream), epoch: epoch)
                        }
                    } catch { self.lost(epoch: epoch, attempt: attempt) }
                }
            case "ended":
                let reason = try? JSONDecoder().decode(DeparturePayload.self, from: data)
                notifyNotice("The watch party has ended", member: nil)
                if reason?.reason == "disabled" { finishMembership(.unavailable, failure: .unavailable) }
                else { finishMembership(.ended, failure: .ended) }
            case "member_left":
                guard let departure = try? JSONDecoder().decode(DeparturePayload.self, from: data),
                      let departed = departure.memberID else { return }
                if departed == memberID {
                    notifyNotice("You were removed from the watch party", member: nil)
                    finishMembership(departure.reason == "removed" ? .removed : .membershipLost, failure: .removed)
                } else {
                    let member = members.first(where: { $0.id == departed })
                    let name = member?.displayName ?? "Someone"
                    notifyNotice("\(name) left the watch party", member: member)
                    lost(epoch: epoch, attempt: attempt)
                }
            case "control", "member_joined", "media":
                // Treat server notifications as invalidations, not authoritative permission/media payloads.
                // Reconcile once through RPC before reopening the send gate.
                lost(epoch: epoch, attempt: attempt)
            case "stream":
                guard data.count <= WatchPartyStreamPolicy.maximumPayloadBytes,
                      let message = try? JSONDecoder().decode(WatchPartyStreamMessage.self, from: data),
                      message.memberID == party.hostMemberID, memberID != party.hostMemberID else { return }
                if let stream = message.stream {
                    guard stream.mediaKey == party.media.key else { return }
                    do { try WatchPartyStreamPolicy.validate(stream) } catch { return }
                }
                if sharedStream != message.stream {
                    sharedStream = message.stream
                    sharedStreamRevision = UUID()
                    onStream?(sharedStream); notifyChange()
                }
            case "chat":
                guard let message = try? JSONDecoder().decode(WatchPartyChatMessage.self, from: data) else { return }
                if let mine = message.mine, mine { return }
                if !message.memberID.isEmpty, message.memberID.caseInsensitiveCompare(memberID) == .orderedSame { return }
                let cleanBody = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanBody.isEmpty else { return }

                var enriched = message
                if enriched.name == nil || enriched.name?.isEmpty == true {
                    if let member = members.first(where: { $0.id.caseInsensitiveCompare(message.memberID) == .orderedSame }) {
                        enriched.name = member.displayName
                        if enriched.avatarURL == nil { enriched.avatarURL = member.avatarURL }
                        if enriched.avatarColor == nil { enriched.avatarColor = member.avatarColor }
                    }
                }
                notifyChatMessage(enriched)
            default: break
            }
        }
    }

    private struct MemberPayload: Codable {
        let memberID: String
        enum CodingKeys: String, CodingKey { case memberID = "member_id" }
    }

    private struct DeparturePayload: Decodable {
        let memberID: String?
        let reason: String?
        enum CodingKeys: String, CodingKey { case memberID = "member_id", reason }
    }
}

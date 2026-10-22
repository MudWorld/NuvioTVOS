import XCTest
@testable import NuvioTV

final class WatchPartyFoundationTests: XCTestCase {
    private func playback(seq: Int64 = 1, memberID: String? = "a", paused: Bool = false,
                          positionMs: Int64 = 10_000, rate: Float = 1, at: Int64 = 1_000_000,
                          mediaKey: String? = "movie|tt1||", waiting: Bool = false) -> WatchPartyPlayback {
        WatchPartyPlayback(seq: seq, memberID: memberID, paused: paused, positionMs: positionMs,
                           rate: rate, at: at, mediaKey: mediaKey, waiting: waiting)
    }

    func testExactMediaReviewAndSourceIdentity() throws {
        let movie = WatchPartyMedia(type: "movie", metaID: "tt1", metaType: "movie", title: "Movie")
        let other = WatchPartyMedia(type: "movie", metaID: "tt2", metaType: "movie", title: "Movie")
        let episode1 = WatchPartyMedia(type: "series", metaID: "ttS", metaType: "series",
                                       season: 1, episode: 1, title: "Series")
        let episode2 = WatchPartyMedia(type: "series", metaID: "ttS", metaType: "series",
                                       season: 1, episode: 2, title: "Series")
        XCTAssertNoThrow(try WatchPartyLaunchPolicy.validateSelection(movie, room: movie))
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(other, room: movie))
        XCTAssertThrowsError(try WatchPartyLaunchPolicy.validateSelection(episode2, room: episode1))
        XCTAssertTrue(WatchPartyMediaReviewPolicy.changed(from: episode1.key, to: episode2.key))
        XCTAssertFalse(WatchPartyMediaReviewPolicy.changed(from: nil, to: episode2.key))
        XCTAssertTrue(WatchPartyMediaReviewPolicy.needsConfirmation(
            previewKey: movie.key, joinedKey: other.key
        ))
    }

    func testRoomFocusPrioritizesConnectionAndContentReview() {
        func target(_ hasRoom: Bool, _ ended: Bool, _ ready: Bool,
                    _ attached: Bool, _ busy: Bool = false, _ review: Bool = false) -> String? {
            WatchPartyRoomFocusPolicy.initialAction(
                hasRoom: hasRoom, membershipEnded: ended,
                connectionReady: ready, playerAttached: attached,
                busy: busy, needsMediaReview: review
            )
        }
        XCTAssertEqual(target(false, false, false, false), "room-code")
        XCTAssertEqual(target(true, false, true, false), "choose-source")
        XCTAssertEqual(target(true, false, true, true), "return-to-player")
        XCTAssertEqual(target(true, false, true, false, false, true), "review-room")
        XCTAssertEqual(target(true, false, false, false, false, true), "reconnect")
        XCTAssertEqual(target(true, true, true, false, false, true), "leave")
        XCTAssertNil(target(true, false, true, false, true))
    }

    func testSharedSourceNoticeDoesNotExposePrivateLinkOrHeaders() {
        let stream = WatchPartyStream(
            mediaKey: "movie|tt1||",
            url: "https://stream.example.test/play?token=SECRET_URL_TOKEN",
            headers: ["Authorization": "Bearer SECRET_HEADER_TOKEN"],
            name: "SECRET_SOURCE_NAME"
        )
        let notice = WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: stream, mediaKey: "movie|tt1||",
            isGuest: true, connected: true
        )
        XCTAssertTrue(notice?.contains("Alex") == true)
        for secret in ["SECRET_URL_TOKEN", "SECRET_HEADER_TOKEN", "SECRET_SOURCE_NAME"] {
            XCTAssertFalse(notice?.contains(secret) == true)
        }
        // A different episode must never be presented as a usable shared source.
        let mismatch = WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: stream, mediaKey: "movie|different||",
            isGuest: true, connected: true
        )
        XCTAssertTrue(mismatch?.contains("No shared source available") == true)
        let lateJoin = WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: nil, mediaKey: "movie|tt1||",
            isGuest: true, connected: true
        )
        XCTAssertTrue(lateJoin?.contains("ask them to share it again") == true)
        XCTAssertTrue(lateJoin?.contains("choose your own source") == true)
        XCTAssertNil(WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: nil, mediaKey: "movie|tt1||",
            isGuest: true, connected: false
        ))
        XCTAssertNil(WatchPartySharedSourceNotice.text(
            hostName: "Alex", stream: stream, mediaKey: "movie|tt1||",
            isGuest: false, connected: true
        ))
    }

    func testWatchPartySharedSourceWireRoundTripPreservesSeparateHeaders() throws {
        let source = WatchPartyStream(
            mediaKey: "movie|tt1||",
            url: "https://stream.example.test/play?token=EXAMPLE",
            headers: ["User-Agent": "NuvioTV"],
            responseHeaders: ["Content-Type": "video/mp4"],
            name: "Host's source"
        )
        let message = WatchPartyStreamMessage(memberID: "host-id", stream: source)
        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(WatchPartyStreamMessage.self, from: encoded)
        XCTAssertEqual(decoded.memberID, "host-id")
        XCTAssertEqual(decoded.stream, source)
        XCTAssertEqual(decoded.stream?.headers["User-Agent"], "NuvioTV")
        XCTAssertEqual(decoded.stream?.responseHeaders["Content-Type"], "video/mp4")
        XCTAssertNoThrow(try WatchPartyStreamPolicy.validate(source))

        // Android uses an explicit null stream as the revocation signal.
        let revoke = WatchPartyStreamMessage(memberID: "host-id", stream: nil)
        let revokeData = try JSONEncoder().encode(revoke)
        XCTAssertEqual(try JSONDecoder().decode(WatchPartyStreamMessage.self, from: revokeData).stream, nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: revokeData) as? [String: Any])
        XCTAssertTrue(json["stream"] is NSNull)
    }

    func testWatchPartySharedSourceRejectsMissingRevocationField() {
        let malformed = Data(#"{"member_id":"host-id"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WatchPartyStreamMessage.self, from: malformed))
    }

    func testTimelineRatePauseDurationAndClockSkewMatchAndroid() {
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(rate: 1.5), nowMs: 1_002_000), 13_000)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(paused: true), nowMs: 1_500_000), 10_000)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(positionMs: 99_000), nowMs: 1_010_000, durationMs: 100_000), 100_000)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(), nowMs: 999_000), 10_000)
    }

    func testSequenceTieUsesKotlinUTF16OrderingAndIgnoresDuplicates() {
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(seq: 3), than: playback(seq: 2)))
        XCTAssertFalse(WatchPartyPolicy.isNewer(playback(seq: 2), than: playback(seq: 3)))
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(memberID: "bbb"), than: playback(memberID: "aaa")))
        XCTAssertFalse(WatchPartyPolicy.isNewer(playback(), than: playback()))
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(memberID: "a"), than: playback(memberID: nil)))
        // Kotlin compares the surrogate 0xD800 before 0xE000, unlike scalar-value order.
        XCTAssertTrue(WatchPartyPolicy.isNewer(playback(memberID: "\u{E000}"), than: playback(memberID: "\u{10000}")))
    }

    func testNudgeDirectionHysteresisAndThresholdEdges() {
        func correction(_ local: Int64, nudging: Bool = false) -> WatchPartyCorrection {
            WatchPartyPolicy.correction(localPositionMs: local, expectedPositionMs: 10_000, playback: playback(), nudging: nudging)
        }
        XCTAssertEqual(correction(10_250), .inSync)
        XCTAssertEqual(correction(10_251), .nudge(rate: 0.95))
        XCTAssertEqual(correction(9_749), .nudge(rate: 1.05))
        XCTAssertEqual(correction(10_080, nudging: true), .inSync)
        XCTAssertEqual(correction(10_081, nudging: true), .nudge(rate: 0.95))
        XCTAssertEqual(correction(11_500), .nudge(rate: 0.95))
        XCTAssertEqual(correction(11_501), .seek(positionMs: 10_000))
    }

    func testPausedRoomDoesNotNudge() {
        let state = playback(paused: true)
        XCTAssertEqual(WatchPartyPolicy.correction(localPositionMs: 10_500, expectedPositionMs: 10_000, playback: state, nudging: false), .inSync)
        XCTAssertEqual(WatchPartyPolicy.correction(localPositionMs: 10_501, expectedPositionMs: 10_000, playback: state, nudging: true), .seek(positionMs: 10_000))
    }

    func testHostAbsenceRespectsHostOnlyAndServerMemberOrder() {
        let members = [WatchPartyMember(id: "older", displayName: "Older"), WatchPartyMember(id: "me", displayName: "Me")]
        XCTAssertEqual(WatchPartyPolicy.coordinatorID(memberID: "me", hostMemberID: "host", hostOnly: false,
                                                     members: members, onlineMemberIDs: ["host", "older"]), "host")
        XCTAssertEqual(WatchPartyPolicy.coordinatorID(memberID: "me", hostMemberID: "host", hostOnly: false,
                                                     members: members, onlineMemberIDs: ["older"]), "older")
        XCTAssertEqual(WatchPartyPolicy.coordinatorID(memberID: "me", hostMemberID: "host", hostOnly: true,
                                                     members: members, onlineMemberIDs: ["older"]), "host")
    }

    func testBehindModeDoesNotBlockTheRoom() {
        XCTAssertEqual(WatchPartyPolicy.ownSeek(targetMs: 7_999, partyPositionMs: 10_000, behind: false), .behind(positionMs: 7_999))
        XCTAssertEqual(WatchPartyPolicy.ownSeek(targetMs: 8_000, partyPositionMs: 10_000, behind: false), .blocked)
        XCTAssertEqual(WatchPartyPolicy.ownSeek(targetMs: 10_000, partyPositionMs: 10_000, behind: true), .catchUp)
        XCTAssertFalse(WatchPartyPolicy.shouldRejoin(gapMs: 1_000, playing: false))
        XCTAssertTrue(WatchPartyPolicy.shouldRejoin(gapMs: 2_000, playing: true))
        XCTAssertEqual(WatchPartyPolicy.reportedGap(7_499), 5_000)
        XCTAssertEqual(WatchPartyPolicy.reportedGap(7_500), 10_000)
        let presence = [
            "loading": WatchPartyPresence(memberID: "loading", status: .loading, mediaKey: "m"),
            "behind": WatchPartyPresence(memberID: "behind", status: .behind, mediaKey: "m"),
            "other": WatchPartyPresence(memberID: "other", status: .buffering, mediaKey: "other"),
            "ignored": WatchPartyPresence(memberID: "ignored", status: .buffering, mediaKey: "m")
        ]
        XCTAssertEqual(WatchPartyPolicy.waitingMemberIDs(mediaKey: "m", presence: presence, ignored: ["ignored"]), ["loading"])
    }

    func testNoticesIgnoreWaitingMediaChangesAndNormalAdvancement() {
        XCTAssertNil(WatchPartyPolicy.action(previous: nil, next: playback()))
        XCTAssertNil(WatchPartyPolicy.action(previous: playback(), next: playback(waiting: true)))
        XCTAssertNil(WatchPartyPolicy.action(previous: playback(), next: playback(mediaKey: "other")))
        XCTAssertNil(WatchPartyPolicy.action(previous: playback(), next: playback(positionMs: 12_000, at: 1_002_000)))
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(), next: playback(paused: true)), .paused)
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(paused: true), next: playback()), .resumed)
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(), next: playback(rate: 1.5)), .speed)
        XCTAssertEqual(WatchPartyPolicy.action(previous: playback(), next: playback(positionMs: 20_000)), .seeked)
    }

    func testExtremeWireTimesDoNotOverflow() {
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(positionMs: .max, at: .min), nowMs: .max), .max)
        XCTAssertEqual(WatchPartyPolicy.correction(localPositionMs: .min, expectedPositionMs: .max,
                                                  playback: playback(), nudging: false), .seek(positionMs: .max))
        XCTAssertEqual(WatchPartyPolicy.reportedGap(.max), .max)
        XCTAssertEqual(WatchPartyPolicy.expectedPosition(playback(paused: true, positionMs: -1), nowMs: 0), 0)
    }

    func testClockChoosesFastestRTTAndUsesMonotonicTimeAfterAnchoring() {
        var uptime: TimeInterval = 10
        var wallMs: Int64 = 500
        var clock = WatchPartyClock(uptime: { uptime }, wallTimeMs: { wallMs })
        XCTAssertEqual(clock.nowMs(), 500)
        let sent = clock.mark()
        uptime = 11
        XCTAssertTrue(clock.addSample(serverMs: 20_000, sentAt: sent))
        XCTAssertEqual(clock.nowMs(), 20_500)
        let fast = clock.mark()
        uptime = 11.25
        XCTAssertTrue(clock.addSample(serverMs: 21_000, sentAt: fast))
        XCTAssertEqual(clock.nowMs(), 21_125)
        wallMs = -99_999
        uptime = 12.25
        XCTAssertEqual(clock.nowMs(), 22_125)
        XCTAssertFalse(clock.addSample(serverMs: 999_999, sentAt: 11))
        XCTAssertFalse(clock.addSample(serverMs: 0, sentAt: .nan))
        clock.reset()
        XCTAssertFalse(clock.isSynced)
        XCTAssertEqual(clock.nowMs(), wallMs)
    }

    func testClockIsResettableAcrossContextsAndSaturates() {
        var uptime: TimeInterval = 0
        var clock = WatchPartyClock(uptime: { uptime }, wallTimeMs: { 0 })
        uptime = 1
        XCTAssertTrue(clock.addSample(serverMs: .max, sentAt: 0))
        XCTAssertEqual(clock.nowMs(), .max)
        clock.reset()
        XCTAssertTrue(clock.addSample(serverMs: 100, sentAt: 0))
        XCTAssertEqual(clock.nowMs(), 600)
    }
}

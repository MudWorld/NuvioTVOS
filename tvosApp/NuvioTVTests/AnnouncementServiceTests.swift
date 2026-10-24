import Foundation
import Combine
import XCTest
@testable import NuvioTV

@MainActor
final class AnnouncementServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AnnouncementServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        AnnouncementURLProtocolStub.reset()
    }

    override func tearDown() {
        AnnouncementURLProtocolStub.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFailureConsumesOneHourWindowAndValidFeedCachesAcrossInstances() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        AnnouncementURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url, AnnouncementService.feedEndpoint)
            return Self.response(for: request, status: 503, data: Data(#"{"message":"unavailable"}"#.utf8))
        }

        let first = makeService(now: { now })
        XCTAssertTrue(first.isEnabled)
        await first.checkIfNeeded()
        XCTAssertEqual(defaults.object(forKey: AnnouncementService.lastAttemptKey) as? Date, now)

        let sameWindow = makeService(now: { now })
        await sameWindow.checkIfNeeded()
        XCTAssertEqual(AnnouncementURLProtocolStub.requestCount, 1)

        now.addTimeInterval(60 * 60 + 1)
        let payload = Self.feedData([Self.item(
            id: "launch-note",
            title: "  Maintenance notice \n",
            message: "  This is a plain-text announcement.  ",
            linkURL: "https://example.org/launch?from=tv#details"
        )])
        AnnouncementURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, data: payload)
        }
        let nextWindow = makeService(now: { now })
        await nextWindow.checkIfNeeded()

        XCTAssertEqual(AnnouncementURLProtocolStub.requestCount, 2)
        XCTAssertEqual(nextWindow.activeAnnouncements.map(\.id), ["launch-note"])
        XCTAssertEqual(nextWindow.activeAnnouncements.first?.title, "Maintenance notice")
        XCTAssertEqual(nextWindow.activeAnnouncements.first?.message, "This is a plain-text announcement.")
        XCTAssertEqual(nextWindow.activeAnnouncements.first?.linkURL?.absoluteString, "https://example.org/launch?from=tv#details")
        XCTAssertNotNil(defaults.data(forKey: AnnouncementService.cachedFeedKey))

        let restored = makeService(now: { now })
        XCTAssertEqual(restored.activeAnnouncements, nextWindow.activeAnnouncements)
        XCTAssertTrue(restored.status.contains("1 active message"))
    }

    func testConcurrentChecksCoalesceAndDisablingIgnoresLateFeed() async {
        let started = expectation(description: "announcement request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        AnnouncementURLProtocolStub.handler = { request in
            started.fulfill()
            releaseResponse.wait()
            return Self.response(
                for: request,
                status: 200,
                data: Self.feedData([Self.item(id: "late-note")])
            )
        }

        let service = makeService()
        let first = Task { await service.checkIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { await service.checkIfNeeded() }
        await Task.yield()
        XCTAssertEqual(AnnouncementURLProtocolStub.requestCount, 1)

        service.setEnabled(false)
        releaseResponse.signal()
        await first.value
        await second.value

        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(service.activeAnnouncements.isEmpty)
        XCTAssertNil(defaults.data(forKey: AnnouncementService.cachedFeedKey))
        await service.checkIfNeeded()
        XCTAssertEqual(AnnouncementURLProtocolStub.requestCount, 1)
    }

    func testValidEmptyFeedClearsCacheAndIsAuthoritative() async {
        let service = makeService()
        AnnouncementURLProtocolStub.handler = { request in
            Self.response(
                for: request,
                status: 200,
                data: Self.feedData([Self.item(id: "old-note")])
            )
        }
        await service.checkIfNeeded()
        XCTAssertEqual(service.activeAnnouncements.map(\.id), ["old-note"])
        XCTAssertNotNil(defaults.data(forKey: AnnouncementService.cachedFeedKey))

        AnnouncementURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, data: Self.feedData([]))
        }
        let emptyFeedService = makeService(now: { Date().addingTimeInterval(60 * 60 + 1) })
        await emptyFeedService.checkIfNeeded()
        XCTAssertTrue(emptyFeedService.activeAnnouncements.isEmpty)
        XCTAssertNil(defaults.data(forKey: AnnouncementService.cachedFeedKey))
        XCTAssertEqual(emptyFeedService.status, "No active messages")
    }

    func testMalformedFeedRetainsPreviousCache() async {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = makeService(now: { now })
        let validData = Self.feedData([Self.item(id: "cached-note")])
        AnnouncementURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, data: validData)
        }
        await service.checkIfNeeded()
        let cached = try! XCTUnwrap(defaults.data(forKey: AnnouncementService.cachedFeedKey))

        let invalidFeeds = [
            Self.feedData([Self.item(id: "new-note")], schemaVersion: 2),
            Self.feedData([Self.item(id: "same"), Self.item(id: "same")]),
            Self.feedData([Self.item(id: "bad id")]),
            Self.feedData([Self.item(id: "bad-url", linkURL: "http://example.org")]),
            Self.feedData([Self.item(id: "credentials", linkURL: "https://user:secret@example.org")]),
            Self.feedData([Self.item(id: "bad-date", startsAt: "tomorrow")]),
            Self.feedData([Self.item(id: "bad-date-separators", startsAt: "2026x10y24T12:00:00Z")]),
            Self.feedData([Self.item(id: "normalized-date", startsAt: "2026-02-30T00:00:00Z")]),
            Self.feedData([Self.item(id: "trailing-date", startsAt: "2026-10-24T12:00:00ZjunkZ")]),
            Self.feedData([Self.item(id: "bad-window", startsAt: "2026-10-25T00:00:00Z", endsAt: "2026-10-24T00:00:00Z")]),
            Self.feedData([Self.item(id: "blank-title", title: " \n ")]),
            Self.feedData([Self.item(id: "long-title", title: String(repeating: "t", count: 81))]),
            Self.feedData([Self.item(id: "long-message", message: String(repeating: "m", count: 241))]),
            Self.feedData((0..<11).map { Self.item(id: "item-\($0)") })
        ]

        for invalid in invalidFeeds {
            now.addTimeInterval(60 * 60 + 1)
            AnnouncementURLProtocolStub.handler = { request in
                Self.response(for: request, status: 200, data: invalid)
            }
            await service.checkIfNeeded()
            XCTAssertEqual(defaults.data(forKey: AnnouncementService.cachedFeedKey), cached)
            XCTAssertEqual(service.activeAnnouncements.map(\.id), ["cached-note"])
        }

        now.addTimeInterval(60 * 60 + 1)
        let oversized = Self.feedData([Self.item(id: "large")]) + Data(repeating: 0x20, count: 64 * 1024)
        AnnouncementURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, data: oversized)
        }
        await service.checkIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AnnouncementService.cachedFeedKey), cached)
        XCTAssertEqual(service.activeAnnouncements.map(\.id), ["cached-note"])
    }

    func testInvalidCachedFeedIsRejectedAndRemoved() {
        defaults.set(
            Self.feedData([Self.item(id: "bad-cache", startsAt: "2026-02-30T00:00:00Z")]),
            forKey: AnnouncementService.cachedFeedKey
        )

        let service = makeService()
        XCTAssertTrue(service.activeAnnouncements.isEmpty)
        XCTAssertNil(defaults.data(forKey: AnnouncementService.cachedFeedKey))
    }

    func testTrimmedBoundsApplyToStoredTitleAndMessage() async {
        let service = makeService()
        let title = "  \(String(repeating: "t", count: 80))  "
        let message = " \(String(repeating: "m", count: 240)) \n"
        AnnouncementURLProtocolStub.handler = { request in
            Self.response(
                for: request,
                status: 200,
                data: Self.feedData([Self.item(id: "trimmed", title: title, message: message)])
            )
        }
        await service.checkIfNeeded()

        XCTAssertEqual(service.activeAnnouncements.first?.title, String(repeating: "t", count: 80))
        XCTAssertEqual(service.activeAnnouncements.first?.message, String(repeating: "m", count: 240))
    }

    func testTimeWindowsAreInclusiveExclusiveAndReevaluatedOnForeground() async {
        let startsAt = Self.date("2026-10-24T12:00:00.250Z")
        let endsAt = Self.date("2026-10-24T12:00:00.750Z")
        var now = startsAt.addingTimeInterval(-0.001)
        let service = makeService(now: { now })
        let data = Self.feedData([Self.item(
            id: "timed-note",
            startsAt: "2026-10-24T12:00:00.250Z",
            endsAt: "2026-10-24T12:00:00.750Z"
        )])
        AnnouncementURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, data: data)
        }
        await service.checkIfNeeded()
        XCTAssertTrue(service.activeAnnouncements.isEmpty)

        now = startsAt
        service.beginForegroundSession()
        XCTAssertEqual(service.activeAnnouncements.map(\.id), ["timed-note"], "startsAt is inclusive")

        now = endsAt
        service.beginForegroundSession()
        XCTAssertTrue(service.activeAnnouncements.isEmpty, "endsAt is exclusive")
    }

    func testScheduledStartAndEndBoundariesUpdateWithoutAnotherRequest() async {
        let injectedBase = Date(timeIntervalSince1970: 1_800_000_000)
        let wallClockBase = Date()
        let now = { injectedBase.addingTimeInterval(Date().timeIntervalSince(wallClockBase)) }
        let startsAt = injectedBase.addingTimeInterval(0.3)
        let endsAt = injectedBase.addingTimeInterval(0.7)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = Self.feedData([Self.item(
            id: "scheduled-note",
            startsAt: formatter.string(from: startsAt),
            endsAt: formatter.string(from: endsAt)
        )])
        let service = makeService(now: now)
        let becameActive = expectation(description: "start boundary activated the message")
        let expired = expectation(description: "end boundary expired the message")
        var didBecomeActive = false
        var didExpire = false
        let observation = service.$activeAnnouncements.sink { messages in
            if messages.contains(where: { $0.id == "scheduled-note" }) {
                if !didBecomeActive {
                    didBecomeActive = true
                    becameActive.fulfill()
                }
            } else if didBecomeActive, !didExpire {
                didExpire = true
                expired.fulfill()
            }
        }
        defer { observation.cancel() }

        AnnouncementURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, data: data)
        }
        await service.checkIfNeeded()
        XCTAssertTrue(service.activeAnnouncements.isEmpty)
        await fulfillment(of: [becameActive, expired], timeout: 3)
        XCTAssertEqual(AnnouncementURLProtocolStub.requestCount, 1, "Time-window changes should not refetch the feed.")
    }

    func testDismissalResetsPerSessionWhileSkipAndEnabledStatePersistIndependently() async {
        AnnouncementURLProtocolStub.handler = { request in
            Self.response(for: request, status: 200, data: Self.feedData([
                Self.item(id: "first-note"),
                Self.item(id: "second-note")
            ]))
        }
        let service = makeService()
        await service.checkIfNeeded()
        XCTAssertEqual(service.firstAvailableAnnouncement?.id, "first-note")

        service.dismiss(id: "first-note")
        XCTAssertEqual(service.firstAvailableAnnouncement?.id, "second-note")
        service.beginForegroundSession()
        XCTAssertEqual(service.firstAvailableAnnouncement?.id, "first-note")

        service.skip(id: "first-note")
        XCTAssertTrue(service.skippedAnnouncementIDs.contains("first-note"))
        service.beginForegroundSession()
        XCTAssertEqual(service.firstAvailableAnnouncement?.id, "second-note")

        service.setEnabled(false)
        XCTAssertNil(service.firstAvailableAnnouncement)
        service.beginForegroundSession()
        XCTAssertNil(service.firstAvailableAnnouncement)
        XCTAssertTrue(service.skippedAnnouncementIDs.contains("first-note"))
        XCTAssertEqual(AnnouncementURLProtocolStub.requestCount, 1)
    }

    private func makeService(now: @escaping () -> Date = Date.init) -> AnnouncementService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnnouncementURLProtocolStub.self]
        return AnnouncementService(
            defaults: defaults,
            session: URLSession(configuration: configuration),
            now: now
        )
    }

    private static func response(for request: URLRequest, status: Int, data: Data) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    private static func item(
        id: String,
        title: String = "Maintenance notice",
        message: String = "This is a plain-text announcement.",
        linkURL: String? = nil,
        startsAt: String? = nil,
        endsAt: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = ["id": id, "title": title, "message": message]
        if let linkURL { result["linkURL"] = linkURL }
        if let startsAt { result["startsAt"] = startsAt }
        if let endsAt { result["endsAt"] = endsAt }
        return result
    }

    private static func feedData(_ items: [[String: Any]], schemaVersion: Int = 1) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schemaVersion": schemaVersion, "announcements": items])
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }
}

private final class AnnouncementURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var storedRequestCount = 0

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    static func reset() {
        lock.lock()
        storedHandler = nil
        storedRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "raw.githubusercontent.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequestCount += 1
        let handler = Self.storedHandler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

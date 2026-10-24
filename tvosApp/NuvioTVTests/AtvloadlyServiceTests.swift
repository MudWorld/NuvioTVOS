import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class AtvloadlyServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AtvloadlyServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        AtvloadlyURLProtocolStub.reset()
    }

    override func tearDown() {
        AtvloadlyURLProtocolStub.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A trimmed copy of a real atvloadly `GET /api/apps` answer (personal
    /// values replaced), plus one unreadable entry.
    private static let appsJSON = """
    {"code":200,"msg":"success","data":[
      {"ID":39,"ipa_name":"Nuvio Usenet","device":"","device_class":"AppleTV","udid":"00008110-0000000000000001",
       "account":"someone@example.com","bundle_identifier":"com.pyksel.nuviotvos.nntp","version":"3.4.7",
       "source":{"kind":"","url":"","prerelease":false,"auto_update":false,"build_id":"","version":"",
                 "latest_build_id":"","latest_version":"","failed_build_id":""},
       "password":"","signing_mode":"apple_id"},
      {"ID":35,"ipa_name":"Nuvio TV","device":"","device_class":"AppleTV","udid":"00008110-0000000000000001",
       "account":"someone@example.com","bundle_identifier":"com.pyksel.nuviotvos","version":"3.4.5",
       "source":{"kind":"github","url":"bobsupra/NuvioTVOS","prerelease":true,"auto_update":true,"build_id":"111",
                 "version":"tvos-beta-3.4.5","latest_build_id":"222","latest_version":"tvos-beta-3.4.7","failed_build_id":""},
       "password":"","signing_mode":"apple_id"},
      {"broken":true}
    ]}
    """

    private static let release = ReleaseUpdateMetadata(
        tagName: "tvos-beta-3.4.7",
        releaseURLString: "https://github.com/bobsupra/NuvioTVOS/releases/tag/tvos-beta-3.4.7"
    )!

    private static let nextRelease = ReleaseUpdateMetadata(
        tagName: "tvos-beta-3.4.8",
        releaseURLString: "https://github.com/bobsupra/NuvioTVOS/releases/tag/tvos-beta-3.4.8"
    )!

    // MARK: - Client

    func testServerAddressIsNormalized() {
        XCTAssertEqual(AtvloadlyClient.serverURL(from: "192.168.1.10:9000")?.absoluteString, "http://192.168.1.10:9000")
        XCTAssertEqual(AtvloadlyClient.serverURL(from: " http://nas.local:9000/ ")?.absoluteString, "http://nas.local:9000")
        XCTAssertEqual(AtvloadlyClient.serverURL(from: "https://example.com/atvloadly/")?.absoluteString, "https://example.com/atvloadly")
        XCTAssertNil(AtvloadlyClient.serverURL(from: ""))
        XCTAssertNil(AtvloadlyClient.serverURL(from: "ftp://example.com"))
        XCTAssertNil(AtvloadlyClient.serverURL(from: "http://"))
        XCTAssertNil(AtvloadlyClient.serverURL(from: "http://example.com/?a=1"))
    }

    func testDecodesAppsAndFindsItsOwnEntry() throws {
        let apps = try AtvloadlyClient.decodeApps(Data(Self.appsJSON.utf8))
        XCTAssertEqual(apps.map(\.id), [39, 35], "An unreadable entry doesn't hide the others.")

        let upstream = AtvloadlyClient.entries(in: apps, bundleIdentifier: "com.pyksel.nuviotvos")
        XCTAssertEqual(upstream.map(\.id), [35])
        let entry = try XCTUnwrap(upstream.first)
        XCTAssertEqual(entry.name, "Nuvio TV")
        XCTAssertTrue(entry.isTracked)
        XCTAssertEqual(entry.sourceLabel, "GitHub bobsupra/NuvioTVOS")
        XCTAssertEqual(entry.source.latestVersion, "tvos-beta-3.4.7")
        XCTAssertEqual(entry.deviceLabel, "Apple TV · …000001")

        // An exact match wins over one the running identifier was derived from.
        XCTAssertEqual(AtvloadlyClient.entries(in: apps, bundleIdentifier: "com.pyksel.nuviotvos.nntp").map(\.id), [39])
        XCTAssertFalse(apps[0].isTracked)
        // A signer that appends to the identifier still finds the entry.
        XCTAssertEqual(AtvloadlyClient.entries(in: apps, bundleIdentifier: "com.pyksel.nuviotvos.TEAM123").map(\.id), [35])
        XCTAssertTrue(AtvloadlyClient.entries(in: apps, bundleIdentifier: "com.other.app").isEmpty)
        // The closest identifier wins when several are prefixes.
        let nested = [
            AtvloadlyAppEntry(id: 1, name: "A", bundleIdentifier: "a.b"),
            AtvloadlyAppEntry(id: 2, name: "B", bundleIdentifier: "a.b.c"),
        ]
        XCTAssertEqual(AtvloadlyClient.entries(in: nested, bundleIdentifier: "a.b.c.x").map(\.id), [2])

        XCTAssertThrowsError(try AtvloadlyClient.decodeApps(Data(#"{"code":-1,"msg":"boom"}"#.utf8))) { error in
            XCTAssertEqual(error as? AtvloadlyClient.Failure, .server("boom"))
        }
        XCTAssertThrowsError(try AtvloadlyClient.decodeApps(Data("<html>".utf8))) { error in
            XCTAssertEqual(error as? AtvloadlyClient.Failure, .badResponse)
        }
    }

    // MARK: - Installing

    func testInstallAsksAtvloadlyForTheTrackedEntry() async {
        AtvloadlyURLProtocolStub.handler = { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/api/apps"):
                return Self.response(for: request, json: Self.appsJSON)
            case ("POST", "/api/apps/35/source/update"):
                return Self.response(for: request, json: #"{"code":200,"msg":"success","data":{"status":"installing","version":"tvos-beta-3.4.7","build_name":"NuvioTV.ipa"}}"#)
            default:
                return Self.response(for: request, status: 404, json: "{}")
            }
        }
        let service = makeService()
        await service.install(release: Self.release)

        XCTAssertEqual(service.phase, .installing(version: "3.4.7"))
        XCTAssertEqual(AtvloadlyURLProtocolStub.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
                       ["GET /api/apps", "POST /api/apps/35/source/update"])
        XCTAssertEqual(service.noticeMessage(for: Self.release),
                       "atvloadly is installing NuvioTV 3.4.7. NuvioTV will close; reopen it in about a minute.")
    }

    func testInstallStopsWhenNotLinkedToASource() async {
        AtvloadlyURLProtocolStub.handler = { request in Self.response(for: request, json: Self.appsJSON) }
        let service = makeService(bundleIdentifier: "com.pyksel.nuviotvos.nntp")
        await service.install(release: Self.release)

        XCTAssertEqual(service.phase, .failed(AtvloadlyService.notTrackedMessage))
        XCTAssertEqual(AtvloadlyURLProtocolStub.requests.count, 1, "Nothing is installed for an untracked app.")
    }

    func testInstallReportsAtvloadlyErrorsAndUnreachableServers() async {
        AtvloadlyURLProtocolStub.handler = { request in
            request.httpMethod == "POST"
                ? Self.response(for: request, json: #"{"code":-1,"msg":"app is installing"}"#)
                : Self.response(for: request, json: Self.appsJSON)
        }
        let busy = makeService()
        await busy.install(release: Self.release)
        XCTAssertEqual(busy.phase, .failed("atvloadly: app is installing"))

        AtvloadlyURLProtocolStub.reset()
        AtvloadlyURLProtocolStub.handler = { _ in throw URLError(.cannotConnectToHost) }
        let offline = makeService()
        await offline.install(release: Self.release)
        XCTAssertEqual(offline.phase, .failed(AtvloadlyService.message(for: .unreachable)))
        XCTAssertEqual(offline.statusText, AtvloadlyService.message(for: .unreachable))

        let noAddress = makeService(server: "")
        await noAddress.install(release: Self.release)
        XCTAssertEqual(noAddress.phase, .failed(AtvloadlyService.message(for: .invalidAddress)))
    }

    func testStatusDescribesTheEntry() async {
        AtvloadlyURLProtocolStub.handler = { request in Self.response(for: request, json: Self.appsJSON) }
        let service = makeService()
        await service.refresh()
        XCTAssertEqual(service.statusText, "Nuvio TV 3.4.5 · GitHub bobsupra/NuvioTVOS · 3.4.7 available")

        AtvloadlyURLProtocolStub.handler = { request in
            Self.response(for: request, json: Self.appsJSON.replacingOccurrences(of: #""latest_build_id":"222""#, with: #""latest_build_id":"""#))
        }
        let upToDate = makeService()
        await upToDate.refresh()
        XCTAssertEqual(upToDate.statusText, "Nuvio TV 3.4.5 · GitHub bobsupra/NuvioTVOS")

        let unknownApp = makeService(bundleIdentifier: "com.other.app")
        await unknownApp.refresh()
        XCTAssertEqual(unknownApp.statusText, "NuvioTV isn't installed through this atvloadly.")
    }

    // MARK: - Automatic install

    func testCountdownPolicy() {
        func start(_ enabled: Bool = true, auto: Bool = true, tag: String = "t2", installed: String? = "t1",
                   held: Set<String> = [], phase: AtvloadlyService.Phase = .idle) -> Bool {
            AtvloadlyService.shouldStartCountdown(
                isEnabled: enabled, installsAutomatically: auto, tag: tag,
                autoInstalledTag: installed, heldTags: held, phase: phase
            )
        }
        XCTAssertTrue(start())
        XCTAssertTrue(start(phase: .failed("x")))
        XCTAssertFalse(start(false))
        XCTAssertFalse(start(auto: false))
        XCTAssertFalse(start(installed: "t2"), "Each version installs automatically at most once.")
        XCTAssertFalse(start(held: ["t2"]))
        XCTAssertFalse(start(phase: .installing(version: "1")))
        XCTAssertFalse(start(phase: .countdown(tag: "t2", secondsLeft: 3)))
    }

    func testCountdownInstallsOncePerVersion() async {
        AtvloadlyURLProtocolStub.handler = { request in
            request.httpMethod == "POST"
                ? Self.response(for: request, json: #"{"code":200,"msg":"success","data":{"status":"installing"}}"#)
                : Self.response(for: request, json: Self.appsJSON)
        }
        let service = makeService(autoInstall: true, sleep: { _ in await Task.yield() })
        service.releaseNoticeChanged(Self.release)
        XCTAssertEqual(service.phase, .countdown(tag: Self.release.tagName, secondsLeft: AtvloadlyService.countdownSeconds))
        XCTAssertTrue(service.isCountingDown)

        await waitUntil { service.isInstalling }
        XCTAssertEqual(service.phase, .installing(version: "3.4.7"))
        XCTAssertEqual(AtvloadlyURLProtocolStub.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(defaults.string(forKey: AtvloadlyService.autoInstalledTagKey), Self.release.tagName)

        // The next launch doesn't install the same version again.
        let relaunched = makeService(autoInstall: true, sleep: { _ in await Task.yield() })
        relaunched.releaseNoticeChanged(Self.release)
        XCTAssertEqual(relaunched.phase, .idle)
    }

    func testCountdownStopsWhenTheNoticeGoesAndCancelHolds() async {
        let service = makeService(autoInstall: true, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        service.releaseNoticeChanged(Self.release)
        XCTAssertTrue(service.isCountingDown)

        // Leaving Home (Details or the player) stops it; coming back restarts it.
        service.releaseNoticeChanged(nil)
        XCTAssertEqual(service.phase, .idle)
        service.releaseNoticeChanged(Self.release)
        XCTAssertTrue(service.isCountingDown)

        // Cancel stops it for this launch; the notice stays with Install.
        service.cancelCountdown()
        XCTAssertEqual(service.phase, .idle)
        service.releaseNoticeChanged(nil)
        service.releaseNoticeChanged(Self.release)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.noticeMessage(for: Self.release), "Install it with atvloadly, or view the release.")
        XCTAssertTrue(AtvloadlyURLProtocolStub.requests.isEmpty)
    }

    func testANewReleaseDuringACountdownRestartsIt() {
        let service = makeService(autoInstall: true, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        service.releaseNoticeChanged(Self.release)
        service.releaseNoticeChanged(Self.nextRelease)
        XCTAssertEqual(service.phase, .countdown(tag: Self.nextRelease.tagName, secondsLeft: AtvloadlyService.countdownSeconds))
        // Dismissing a notice holds its version for this launch.
        service.noticeDismissed(tag: Self.nextRelease.tagName)
        XCTAssertEqual(service.phase, .idle)
    }

    func testNoCountdownDuringPictureInPicture() {
        let service = makeService(autoInstall: true, sleep: { _ in try await Task.sleep(for: .seconds(60)) },
                                  isPlaybackActive: { true })
        service.releaseNoticeChanged(Self.release)
        XCTAssertEqual(service.phase, .idle)
    }

    func testFailedAutomaticInstallIsTriedAgainNextLaunch() async {
        AtvloadlyURLProtocolStub.handler = { _ in throw URLError(.cannotConnectToHost) }
        let service = makeService(autoInstall: true, sleep: { _ in await Task.yield() })
        service.releaseNoticeChanged(Self.release)
        await waitUntil { if case .failed = service.phase { return true }; return false }
        XCTAssertEqual(service.phase, .failed(AtvloadlyService.message(for: .unreachable)))
        XCTAssertNil(defaults.string(forKey: AtvloadlyService.autoInstalledTagKey),
                     "A setup problem doesn't use up the version's automatic install.")
        // Not again in this launch…
        service.releaseNoticeChanged(nil)
        service.releaseNoticeChanged(Self.release)
        XCTAssertFalse(service.isCountingDown)
        // …but after the next launch.
        let relaunched = makeService(autoInstall: true, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        relaunched.releaseNoticeChanged(Self.release)
        XCTAssertTrue(relaunched.isCountingDown)
    }

    func testConcurrentInstallsShareOneRequest() async {
        AtvloadlyURLProtocolStub.handler = { request in
            request.httpMethod == "POST"
                ? Self.response(for: request, json: #"{"code":200,"msg":"success","data":{"status":"installing"}}"#)
                : Self.response(for: request, json: Self.appsJSON)
        }
        let service = makeService()
        async let first: Void = service.install(release: Self.release)
        async let second: Void = service.install(release: Self.release)
        _ = await (first, second)
        XCTAssertEqual(service.phase, .installing(version: "3.4.7"))
        XCTAssertEqual(AtvloadlyURLProtocolStub.requests.filter { $0.httpMethod == "POST" }.count, 1)
        // While installing, another request does nothing.
        await service.install(release: Self.release)
        XCTAssertEqual(AtvloadlyURLProtocolStub.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testFixingTheSetupClearsAnOldFailure() async {
        let service = makeService(server: "")
        await service.install(release: Self.release)
        XCTAssertEqual(service.phase, .failed(AtvloadlyService.message(for: .invalidAddress)))
        service.setServerAddress("atvloadly.test:9000")
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.statusText, "Not checked yet")
    }

    func testDisplayVersion() {
        XCTAssertEqual(AtvloadlyService.displayVersion("tvos-beta-3.4.8", fallback: "x"), "3.4.8")
        XCTAssertEqual(AtvloadlyService.displayVersion("", fallback: "3.4.5"), "3.4.5")
        XCTAssertEqual(AtvloadlyService.displayVersion("nightly", fallback: "x"), "nightly")
    }

    func testTurningOffStopsTheCountdown() {
        let service = makeService(autoInstall: true, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        service.releaseNoticeChanged(Self.release)
        XCTAssertTrue(service.isCountingDown)
        service.setInstallsAutomatically(false)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertFalse(defaults.bool(forKey: AtvloadlyService.autoInstallKey))
    }

    // MARK: - Check Now

    func testCheckNowSkipsTheDailyLimit() async {
        AtvloadlyURLProtocolStub.handler = { request in
            Self.response(for: request, json: """
            {"tag_name":"tvos-beta-3.4.7","html_url":"https://github.com/bobsupra/NuvioTVOS/releases/tag/tvos-beta-3.4.7","prerelease":false,"draft":false}
            """)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AtvloadlyURLProtocolStub.self]
        let updates = ReleaseUpdateService(
            defaults: defaults,
            session: URLSession(configuration: configuration),
            runningVersion: "3.4.6"
        )
        await updates.checkIfNeeded()
        await updates.checkIfNeeded()
        XCTAssertEqual(AtvloadlyURLProtocolStub.requests.count, 1)
        await updates.checkIfNeeded(force: true)
        XCTAssertEqual(AtvloadlyURLProtocolStub.requests.count, 2)
        XCTAssertTrue(updates.isUpdateAvailable)
    }

    // MARK: - Helpers

    private func makeService(
        server: String = "atvloadly.test:9000",
        bundleIdentifier: String = "com.pyksel.nuviotvos",
        autoInstall: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
        isPlaybackActive: @escaping @MainActor () -> Bool = { false }
    ) -> AtvloadlyService {
        defaults.set(true, forKey: AtvloadlyService.enabledKey)
        defaults.set(server, forKey: AtvloadlyService.serverKey)
        defaults.set(autoInstall, forKey: AtvloadlyService.autoInstallKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AtvloadlyURLProtocolStub.self]
        return AtvloadlyService(
            defaults: defaults,
            session: URLSession(configuration: configuration),
            bundleIdentifier: bundleIdentifier,
            sleep: sleep,
            isPlaybackActive: isPlaybackActive
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func response(for request: URLRequest, status: Int = 200, json: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private final class AtvloadlyURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var storedRequests: [URLRequest] = []

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

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    static func reset() {
        lock.lock()
        storedHandler = nil
        storedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["atvloadly.test", "api.github.com"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequests.append(request)
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

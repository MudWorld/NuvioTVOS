import Foundation
import Combine

/// NuvioTV's entry in an atvloadly server, from `GET /api/apps`.
///
/// atvloadly (github.com/bitxeno/atvloadly) is a self-hosted signer many Apple
/// TV users sideload with. It can track this repo's releases and install a new
/// build on request through its local API.
struct AtvloadlyAppEntry: Decodable, Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    let device: String
    let udid: String
    let bundleIdentifier: String
    let version: String
    let source: Source

    /// Where atvloadly gets new builds from (empty `kind`: not tracked).
    struct Source: Decodable, Equatable, Sendable {
        let kind: String
        let url: String
        let latestVersion: String
        let latestBuildID: String
        let failedBuildID: String

        init(kind: String = "", url: String = "", latestVersion: String = "",
             latestBuildID: String = "", failedBuildID: String = "") {
            self.kind = kind
            self.url = url
            self.latestVersion = latestVersion
            self.latestBuildID = latestBuildID
            self.failedBuildID = failedBuildID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? ""
            url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
            latestVersion = (try? container.decodeIfPresent(String.self, forKey: .latestVersion)) ?? ""
            latestBuildID = (try? container.decodeIfPresent(String.self, forKey: .latestBuildID)) ?? ""
            failedBuildID = (try? container.decodeIfPresent(String.self, forKey: .failedBuildID)) ?? ""
        }

        private enum CodingKeys: String, CodingKey {
            case kind, url
            case latestVersion = "latest_version"
            case latestBuildID = "latest_build_id"
            case failedBuildID = "failed_build_id"
        }
    }

    init(id: Int, name: String, device: String = "", udid: String = "",
         bundleIdentifier: String, version: String = "", source: Source = Source()) {
        self.id = id
        self.name = name
        self.device = device
        self.udid = udid
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        let customName = (try? container.decodeIfPresent(String.self, forKey: .customName)) ?? ""
        let ipaName = (try? container.decodeIfPresent(String.self, forKey: .ipaName)) ?? ""
        name = customName.isEmpty ? ipaName : customName
        device = (try? container.decodeIfPresent(String.self, forKey: .device)) ?? ""
        udid = (try? container.decodeIfPresent(String.self, forKey: .udid)) ?? ""
        bundleIdentifier = (try? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? ""
        source = (try? container.decodeIfPresent(Source.self, forKey: .source)) ?? Source()
    }

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case ipaName = "ipa_name"
        case customName = "custom_name"
        case bundleIdentifier = "bundle_identifier"
        case device, udid, version, source
    }

    var isTracked: Bool { !source.kind.isEmpty }

    /// atvloadly often leaves the device name empty; the end of the UDID still
    /// tells two Apple TVs apart.
    var deviceLabel: String {
        if !device.isEmpty { return device }
        return udid.isEmpty ? "Apple TV" : "Apple TV · …\(udid.suffix(6))"
    }

    var sourceLabel: String {
        switch source.kind {
        case "github": return "GitHub \(source.url)"
        case "altstore": return "AltStore source"
        default: return source.kind
        }
    }
}

/// The three calls NuvioTV makes to atvloadly. Its API has no login and runs
/// on the local network; NuvioTV sends no credentials.
enum AtvloadlyClient {
    enum Failure: Error, Equatable {
        case invalidAddress
        case unreachable
        case badResponse
        case server(String)
    }

    /// The server as typed: `192.168.1.10:9000` gets `http://`, a trailing
    /// slash is dropped, and only http(s) addresses with a host are accepted.
    static func serverURL(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil else { return nil }
        return components.url
    }

    /// NuvioTV's entries: the same bundle identifier, or failing that one the
    /// running identifier was derived from (a signer that appends to it).
    static func entries(in apps: [AtvloadlyAppEntry], bundleIdentifier: String) -> [AtvloadlyAppEntry] {
        let exact = apps.filter { $0.bundleIdentifier == bundleIdentifier }
        if !exact.isEmpty { return exact }
        let derived = apps.filter {
            !$0.bundleIdentifier.isEmpty && bundleIdentifier.hasPrefix($0.bundleIdentifier + ".")
        }
        // The longest prefix is the closest: `a.b.c.x` belongs to `a.b.c`, not `a.b`.
        let longest = derived.map(\.bundleIdentifier.count).max()
        return derived.filter { $0.bundleIdentifier.count == longest }
    }

    static func apps(server: URL, session: URLSession) async throws -> [AtvloadlyAppEntry] {
        var request = URLRequest(url: server.appendingPathComponent("api/apps"))
        // A server that's off answers nothing: don't keep Settings or the
        // notice waiting long.
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try decodeApps(try await send(request, session: session))
    }

    static func decodeApps(_ data: Data) throws -> [AtvloadlyAppEntry] {
        guard let envelope = try? JSONDecoder().decode(Envelope<[Lossy<AtvloadlyAppEntry>]>.self, from: data) else {
            throw Failure.badResponse
        }
        guard envelope.code == 200 else { throw Failure.server(envelope.msg ?? "") }
        return (envelope.data ?? []).compactMap(\.value)
    }

    /// Asks atvloadly to install the newest build from the app's source. It
    /// answers once the install is queued (after reading the source), and the
    /// install itself closes NuvioTV. Returns the version atvloadly named.
    @discardableResult
    static func installUpdate(appID: Int, server: URL, session: URLSession) async throws -> String? {
        var request = URLRequest(url: server.appendingPathComponent("api/apps/\(appID)/source/update"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request, session: session)
        guard let envelope = try? JSONDecoder().decode(Envelope<InstallReply>.self, from: data) else {
            throw Failure.badResponse
        }
        guard envelope.code == 200 else { throw Failure.server(envelope.msg ?? "") }
        return envelope.data?.version
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw Failure.unreachable
        }
        guard let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.badResponse
        }
        return result.0
    }

    /// atvloadly wraps every answer: `{"code":200,"msg":"success","data":…}`,
    /// errors as `code: -1` with a message.
    private struct Envelope<Payload: Decodable>: Decodable {
        let code: Int?
        let msg: String?
        let data: Payload?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            msg = try? container.decodeIfPresent(String.self, forKey: .msg)
            data = try? container.decodeIfPresent(Payload.self, forKey: .data)
        }

        private enum CodingKeys: String, CodingKey { case code, msg, data }
    }

    /// One unreadable app doesn't hide the others.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct InstallReply: Decodable {
        let version: String?
    }
}


/// Installs NuvioTV updates through the user's atvloadly server: from Settings
/// → About → Check Now, from the update notice's button, or automatically
/// after a countdown while the notice is on screen (Home, nothing playing).
@MainActor
final class AtvloadlyService: ObservableObject {
    static let enabledKey = "atvloadlyEnabled"
    static let serverKey = "atvloadlyServer"
    static let autoInstallKey = "atvloadlyAutoInstall"
    static let appIDKey = "atvloadlyAppID"
    static let autoInstalledTagKey = "atvloadlyAutoInstalledTag"
    static let countdownSeconds = 10

    enum Connection: Equatable {
        case unknown
        case checking
        case connected([AtvloadlyAppEntry])
        case failed(AtvloadlyClient.Failure)
    }

    enum Phase: Equatable {
        case idle
        case countdown(tag: String, secondsLeft: Int)
        case installing(version: String)
        case failed(String)
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var installsAutomatically: Bool
    @Published private(set) var serverAddress: String
    @Published private(set) var selectedAppID: Int?
    @Published private(set) var connection: Connection = .unknown
    @Published private(set) var phase: Phase = .idle

    private let defaults: UserDefaults
    private let session: URLSession
    private let bundleIdentifier: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let installTimeout: Duration
    /// Picture in Picture keeps playing over Home; an automatic install
    /// would end it.
    private let isPlaybackActive: @MainActor () -> Bool
    /// The release notice on screen with nothing over it, if any.
    private var visibleNoticeTag: String?
    /// Versions not to count down again in this launch: cancelled by the
    /// user, or already tried automatically.
    private var heldTags: Set<String> = []
    private var countdownTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var installExpiryTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "",
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        installTimeout: Duration = .seconds(180),
        isPlaybackActive: @escaping @MainActor () -> Bool = { PictureInPictureManager.shared.isPictureInPictureActive }
    ) {
        self.defaults = defaults
        self.session = session
        self.bundleIdentifier = bundleIdentifier
        self.sleep = sleep
        self.installTimeout = installTimeout
        self.isPlaybackActive = isPlaybackActive
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        installsAutomatically = defaults.bool(forKey: Self.autoInstallKey)
        serverAddress = defaults.string(forKey: Self.serverKey) ?? ""
        selectedAppID = defaults.object(forKey: Self.appIDKey) as? Int
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            Task { await refresh() }
        } else {
            stopCountdown()
            connection = .unknown
            phase = .idle
        }
    }

    func setInstallsAutomatically(_ enabled: Bool) {
        guard enabled != installsAutomatically else { return }
        installsAutomatically = enabled
        defaults.set(enabled, forKey: Self.autoInstallKey)
        if !enabled { stopCountdown() }
    }

    /// Saved as typed; Settings refreshes when editing ends.
    func setServerAddress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != serverAddress else { return }
        serverAddress = trimmed
        defaults.set(trimmed, forKey: Self.serverKey)
        connection = .unknown
        clearFailure()
    }

    /// Picks this Apple TV when atvloadly has NuvioTV for several.
    func selectApp(id: Int) {
        selectedAppID = id
        defaults.set(id, forKey: Self.appIDKey)
        clearFailure()
    }

    var entries: [AtvloadlyAppEntry] {
        if case .connected(let entries) = connection { return entries }
        return []
    }

    var selectedEntry: AtvloadlyAppEntry? {
        let candidates = entries
        if candidates.count == 1 { return candidates[0] }
        return candidates.first { $0.id == selectedAppID }
    }

    // MARK: - atvloadly

    /// Reads NuvioTV's entry from atvloadly (Settings, and before installing).
    @discardableResult
    func refresh() async -> AtvloadlyAppEntry? {
        guard isEnabled else { return nil }
        clearFailure()
        guard let server = AtvloadlyClient.serverURL(from: serverAddress) else {
            connection = .failed(.invalidAddress)
            return nil
        }
        connection = .checking
        do {
            let apps = try await AtvloadlyClient.apps(server: server, session: session)
            connection = .connected(AtvloadlyClient.entries(in: apps, bundleIdentifier: bundleIdentifier))
        } catch let failure as AtvloadlyClient.Failure {
            connection = .failed(failure)
        } catch {
            connection = .failed(.unreachable)
        }
        return selectedEntry
    }

    /// Asks atvloadly to install the newest build now. Requests made while
    /// one is on its way share it, so nothing is installed twice.
    func install(release: ReleaseUpdateMetadata?) async {
        await runInstall(release: release, automatic: false)
    }

    private func runInstall(release: ReleaseUpdateMetadata?, automatic: Bool) async {
        guard isEnabled else { return }
        if let installTask {
            await installTask.value
            return
        }
        if case .installing = phase { return }
        let task = Task { await self.performInstall(release: release, automatic: automatic) }
        installTask = task
        await task.value
        installTask = nil
    }

    private func performInstall(release: ReleaseUpdateMetadata?, automatic: Bool) async {
        stopCountdown()
        guard let server = AtvloadlyClient.serverURL(from: serverAddress) else {
            phase = .failed(Self.message(for: .invalidAddress))
            return
        }
        guard let entry = await refresh() else {
            // The status explains it: unreachable, not found, or which Apple TV.
            phase = .failed(statusText)
            return
        }
        guard entry.isTracked else {
            phase = .failed(Self.notTrackedMessage)
            return
        }
        if automatic {
            // Still allowed? The user may have left Home or started playback
            // while atvloadly answered.
            guard let tag = release?.tagName else { return }
            guard visibleNoticeTag == tag, !isPlaybackActive() else {
                // Counts down again when the notice is back on screen.
                heldTags.remove(tag)
                return
            }
            if !entry.source.failedBuildID.isEmpty, entry.source.failedBuildID == entry.source.latestBuildID {
                phase = .failed(Self.failedBuildMessage)
                return
            }
        }
        phase = .installing(version: release?.displayVersion ?? Self.displayVersion(entry.source.latestVersion, fallback: entry.version))
        do {
            let version = try await AtvloadlyClient.installUpdate(appID: entry.id, server: server, session: session)
            if let version, !version.isEmpty {
                // atvloadly installs the newest build of its own source.
                phase = .installing(version: Self.displayVersion(version, fallback: version))
            }
            if automatic, let tag = release?.tagName {
                // At most one automatic install per version.
                defaults.set(tag, forKey: Self.autoInstalledTagKey)
            }
            expireInstall()
        } catch let failure as AtvloadlyClient.Failure {
            phase = .failed(Self.message(for: failure))
        } catch {
            phase = .failed(Self.message(for: .unreachable))
        }
    }

    /// The install closes NuvioTV. If it's still running long after, the
    /// install didn't happen: say so and allow another try.
    private func expireInstall() {
        installExpiryTask?.cancel()
        let timeout = installTimeout
        installExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, case .installing = self.phase else { return }
            self.phase = .failed(Self.installStalledMessage)
        }
    }

    private func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Automatic install

    /// Whether the notice for `tag` should start counting down.
    static func shouldStartCountdown(
        isEnabled: Bool,
        installsAutomatically: Bool,
        tag: String,
        autoInstalledTag: String?,
        heldTags: Set<String>,
        phase: Phase
    ) -> Bool {
        guard isEnabled, installsAutomatically, tag != autoInstalledTag, !heldTags.contains(tag) else {
            return false
        }
        switch phase {
        case .idle, .failed: return true
        case .countdown, .installing: return false
        }
    }

    /// The release notice is on screen with nothing over it (Home, nothing
    /// playing, app active), or gone (nil). Only then may an automatic install
    /// count down; leaving Home stops the countdown and returning starts it
    /// again.
    func releaseNoticeChanged(_ release: ReleaseUpdateMetadata?) {
        visibleNoticeTag = release?.tagName
        if case .countdown(let counting, _) = phase, counting != release?.tagName {
            stopCountdown()
        }
        guard let release, !isPlaybackActive() else {
            stopCountdown()
            return
        }
        guard Self.shouldStartCountdown(
            isEnabled: isEnabled,
            installsAutomatically: installsAutomatically,
            tag: release.tagName,
            autoInstalledTag: defaults.string(forKey: Self.autoInstalledTagKey),
            heldTags: heldTags,
            phase: phase
        ) else { return }
        startCountdown(for: release)
    }

    /// Cancel in the notice: no automatic install of that version in this
    /// launch. The notice stays, with Install for later.
    func cancelCountdown() {
        guard case .countdown(let tag, _) = phase else { return }
        heldTags.insert(tag)
        stopCountdown()
    }

    /// The notice was dismissed or skipped: no automatic install of that
    /// version in this launch.
    func noticeDismissed(tag: String) {
        heldTags.insert(tag)
        if case .countdown(let counting, _) = phase, counting == tag { stopCountdown() }
    }

    private func startCountdown(for release: ReleaseUpdateMetadata) {
        countdownTask?.cancel()
        let tag = release.tagName
        phase = .countdown(tag: tag, secondsLeft: Self.countdownSeconds)
        countdownTask = Task { [weak self] in
            var remaining = Self.countdownSeconds
            while remaining > 0 {
                guard let sleep = self?.sleep else { return }
                do { try await sleep(.seconds(1)) } catch { return }
                guard let self, !Task.isCancelled,
                      case .countdown(let counting, _) = self.phase, counting == tag else { return }
                remaining -= 1
                if remaining > 0 { self.phase = .countdown(tag: tag, secondsLeft: remaining) }
            }
            guard let self, !Task.isCancelled else { return }
            // Tried once per launch; saved for good only when atvloadly accepts it.
            self.heldTags.insert(tag)
            self.countdownTask = nil
            self.phase = .idle
            await self.runInstall(release: release, automatic: true)
        }
    }

    private func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        if case .countdown = phase { phase = .idle }
    }

    // MARK: - Text

    var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }

    var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    /// The update notice's message while atvloadly is on.
    func noticeMessage(for release: ReleaseUpdateMetadata) -> String {
        switch phase {
        case .countdown(let tag, let seconds) where tag == release.tagName:
            return L10n.format(
                "atvloadly_notice_countdown",
                fallback: "Installing with atvloadly in %d s. NuvioTV will close; reopen it in about a minute.",
                seconds
            )
        case .installing(let version):
            return Self.installingMessage(version)
        case .failed(let message):
            return message
        default:
            return L10n.string(
                "atvloadly_notice_ready",
                fallback: "Install it with atvloadly, or view the release."
            )
        }
    }

    /// The Status row in Settings → About → atvloadly.
    var statusText: String {
        switch phase {
        case .installing(let version): return Self.installingMessage(version)
        case .failed(let message): return message
        case .idle, .countdown: break
        }
        switch connection {
        case .unknown:
            return AtvloadlyClient.serverURL(from: serverAddress) == nil
                ? Self.message(for: .invalidAddress)
                : L10n.string("atvloadly_status_unknown", fallback: "Not checked yet")
        case .checking:
            return L10n.string("atvloadly_status_checking", fallback: "Checking…")
        case .failed(let failure):
            return Self.message(for: failure)
        case .connected:
            if let entryProblem { return entryProblem }
            guard let entry = selectedEntry else { return Self.message(for: .unreachable) }
            var text = "\(entry.name) \(entry.version) · \(entry.sourceLabel)"
            // atvloadly fills the latest build only when it is newer than the installed one.
            if !entry.source.latestBuildID.isEmpty, !entry.source.latestVersion.isEmpty {
                text += " · " + L10n.format(
                    "atvloadly_status_available",
                    fallback: "%@ available",
                    Self.displayVersion(entry.source.latestVersion, fallback: entry.source.latestVersion)
                )
            }
            return text
        }
    }

    /// Why there's no usable entry, when atvloadly answered.
    private var entryProblem: String? {
        guard case .connected(let entries) = connection else { return nil }
        if entries.isEmpty {
            return L10n.string("atvloadly_status_not_found", fallback: "NuvioTV isn't installed through this atvloadly.")
        }
        guard let entry = selectedEntry else {
            return L10n.string("atvloadly_status_choose_device", fallback: "atvloadly has NuvioTV for several Apple TVs. Choose this one below.")
        }
        return entry.isTracked ? nil : Self.notTrackedMessage
    }

    /// `tvos-beta-3.4.7` → `3.4.7`; anything else as it is.
    static func displayVersion(_ tag: String, fallback: String) -> String {
        guard !tag.isEmpty else { return fallback }
        return NumericReleaseVersion(tag: tag)?.displayValue ?? tag
    }

    private static func installingMessage(_ version: String) -> String {
        L10n.format(
            "atvloadly_notice_installing",
            fallback: "atvloadly is installing NuvioTV %@. NuvioTV will close; reopen it in about a minute.",
            version
        )
    }

    static var notTrackedMessage: String {
        L10n.string(
            "atvloadly_status_not_tracked",
            fallback: "NuvioTV isn't linked to a source in atvloadly. Open More → Track updates there."
        )
    }

    static var failedBuildMessage: String {
        L10n.string(
            "atvloadly_status_failed_build",
            fallback: "atvloadly couldn't install this version before, so it isn't tried automatically. Use Install or Check Now to try again."
        )
    }

    static var installStalledMessage: String {
        L10n.string(
            "atvloadly_status_install_stalled",
            fallback: "atvloadly didn't finish the install. Check atvloadly, then try again."
        )
    }

    static func message(for failure: AtvloadlyClient.Failure) -> String {
        switch failure {
        case .invalidAddress:
            return L10n.string("atvloadly_error_address", fallback: "Enter your atvloadly address, e.g. http://192.168.1.10:9000.")
        case .unreachable:
            // Also what tvOS's local network prompt looks like until it is
            // answered, or after it was declined.
            return L10n.string(
                "atvloadly_error_unreachable",
                fallback: "Can't reach atvloadly. Check the address, that atvloadly is running, and that NuvioTV is allowed to use the local network in the Apple TV's privacy settings, then refresh."
            )
        case .badResponse:
            return L10n.string("atvloadly_error_response", fallback: "That address didn't answer like atvloadly.")
        case .server(let message):
            return message.isEmpty
                ? L10n.string("atvloadly_error_server", fallback: "atvloadly reported an error.")
                : "atvloadly: \(message)"
        }
    }
}

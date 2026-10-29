import CryptoKit
import Foundation
import Security

/// WatchParty account on the private sync server.
///
/// Snapshot sync between Apple TVs: every preferences domain of this app and every
/// file in Application Support is uploaded as its own section (`tv.d.*`, `tv.f.*`).
/// Newer sections are applied in `prepareOnLaunch()` before any store is read; data
/// that arrives while the app runs is applied on the next launch.
@MainActor
final class WatchPartyAccount: ObservableObject {
    static let shared = WatchPartyAccount()

    struct Session: Equatable {
        let username: String
        let isAdmin: Bool
    }

    enum Outcome {
        case uploadedLocalData
        case relaunchRequired
    }

    struct AccountError: LocalizedError {
        let code: String
        var errorDescription: String? {
            switch code {
            case "invalid_credentials": return "Benutzername oder Passwort falsch."
            case "invalid_invite": return "Einladungscode ungültig oder schon benutzt."
            case "username_taken": return "Dieser Benutzername ist vergeben."
            case "invalid_username": return "Benutzername: 3–32 Zeichen, nur Buchstaben, Ziffern, . _ -"
            case "weak_password": return "Das Passwort braucht mindestens 8 Zeichen."
            case "too_many_attempts": return "Zu viele Versuche. Bitte 15 Minuten warten."
            case "unauthorized": return "Sitzung abgelaufen. Bitte neu anmelden."
            case "network": return "Server nicht erreichbar. Prüfe die Internetverbindung."
            default: return "Etwas ist schiefgelaufen. Bitte versuch es noch einmal."
            }
        }
    }

    @Published private(set) var session: Session?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var pendingRelaunch = false

    nonisolated private static let server = URL(string: "https://sync.mudworld.space")!
    nonisolated private static let keychainService = "space.mudworld.watchparty.account"
    nonisolated private static let stateKey = "watchparty.account.state.v1"
    nonisolated private static let maxFileBytes = 1_800_000
    nonisolated private static let excludedDefaultKeys: Set<String> = [
        stateKey,
        "nuvio.auth.installMarker",
        "nuvio.auth.skippedLogin",
        "nuvio.auth.serverConfiguration",
    ]

    private var timer: Timer?
    private var pendingRequest: DispatchWorkItem?
    private let queue = DispatchQueue(label: "watchparty.account.sync")

    private init() {
        let state = Self.loadState()
        if Self.readToken() != nil, let username = state.username {
            session = Session(username: username, isAdmin: state.isAdmin)
        }
    }

    // MARK: - Launch

    /// Call first in `App.init()`: pulls newer sections (≤ 6 s) and writes them before stores load.
    nonisolated static func prepareOnLaunch() {
        guard let token = readToken() else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            try? await pullNewer(token: token, apply: true)
        }
        _ = semaphore.wait(timeout: .now() + 6)
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in await WatchPartyAccount.shared.periodic() }
        }
    }

    // MARK: - Sign-in

    func signIn(username: String, password: String) async throws -> Outcome {
        try await authenticate(path: "/v1/login", body: ["username": username, "password": password])
    }

    func register(username: String, password: String, invite: String) async throws -> Outcome {
        try await authenticate(path: "/v1/register",
                               body: ["username": username, "password": password, "invite": invite.uppercased()])
    }

    private func authenticate(path: String, body: [String: String]) async throws -> Outcome {
        var payload = body
        payload["device"] = "Apple TV"
        let data = try await Self.request("POST", path, json: payload, token: nil)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String,
              let username = object["username"] as? String else { throw AccountError(code: "invalid_response") }
        Self.writeToken(token)
        var state = AccountState()
        state.username = username
        state.isAdmin = (object["isAdmin"] as? Bool) == true
        Self.saveState(state)
        session = Session(username: username, isAdmin: state.isAdmin)

        let remote = try await Self.listSections(token: token).keys.filter { $0.hasPrefix("tv.") }
        if remote.isEmpty {
            try await pushChanges(force: true)
            start()
            return .uploadedLocalData
        }
        try await Self.pullNewer(token: token, apply: false, forceAll: true)
        pendingRelaunch = true
        return .relaunchRequired
    }

    func signOut() async {
        if let token = Self.readToken() {
            try? await pushChanges(force: false)
            _ = try? await Self.request("POST", "/v1/logout", json: [:], token: token)
        }
        Self.deleteToken()
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        session = nil
    }

    func createInvite() async throws -> String {
        guard let token = Self.readToken() else { throw AccountError(code: "unauthorized") }
        let data = try await Self.request("POST", "/v1/invites", json: [:], token: token)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["code"] as? String ?? ""
    }

    // MARK: - Sync

    /// Upload changes a few seconds from now (playback paused, closed or switched; app backgrounded).
    func requestSync() {
        guard session != nil else { return }
        pendingRequest?.cancel()
        let work = DispatchWorkItem {
            Task { @MainActor in try? await WatchPartyAccount.shared.pushChanges(force: false) }
        }
        pendingRequest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func syncNow() async {
        do {
            try await pushChanges(force: false)
            if let token = Self.readToken() {
                try await Self.pullNewer(token: token, apply: false)
                pendingRelaunch = Self.hasStaged()
            }
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
        }
    }

    private func periodic() async {
        await syncNow()
    }

    func pushChanges(force: Bool) async throws {
        guard let token = Self.readToken() else { return }
        isSyncing = true
        defer { isSyncing = false }
        let sections = Self.collectSections()
        var state = Self.loadState()
        for (name, content) in sections {
            if state.stagedSections.contains(name) { continue }
            let hash = Self.sha256(content)
            if !force && state.hashes[name] == hash { continue }
            let data = try await Self.request("PUT", "/v1/data/\(name)", json: ["data": content], token: token)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            state.hashes[name] = hash
            state.versions[name] = (object?["updatedAt"] as? NSNumber)?.int64Value ?? 0
        }
        Self.saveState(state)
        lastSync = Date()
    }

    // MARK: - Snapshot collection / application

    nonisolated private static func collectSections() -> [String: String] {
        var sections: [String: String] = [:]
        for domain in preferenceDomains() {
            guard var values = UserDefaults.standard.persistentDomain(forName: domain) else { continue }
            excludedDefaultKeys.forEach { values.removeValue(forKey: $0) }
            guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            else { continue }
            let envelope = ["domain": domain, "plist": data.base64EncodedString()]
            if let json = try? JSONSerialization.data(withJSONObject: envelope),
               let text = String(data: json, encoding: .utf8) {
                sections["tv.d." + shortHash(domain)] = text
            }
        }
        for (relative, url) in supportFiles() {
            guard let data = try? Data(contentsOf: url), data.count <= maxFileBytes else { continue }
            let envelope = ["path": relative, "file": data.base64EncodedString()]
            if let json = try? JSONSerialization.data(withJSONObject: envelope),
               let text = String(data: json, encoding: .utf8) {
                sections["tv.f." + shortHash(relative)] = text
            }
        }
        return sections
    }

    nonisolated private static func apply(sectionContent: String) {
        guard let data = sectionContent.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        if let domain = envelope["domain"], let plist = envelope["plist"].flatMap({ Data(base64Encoded: $0) }),
           var values = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] {
            let current = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            for key in excludedDefaultKeys { values[key] = current[key] }
            UserDefaults.standard.setPersistentDomain(values, forName: domain)
        } else if let path = envelope["path"], let file = envelope["file"].flatMap({ Data(base64Encoded: $0) }),
                  let base = supportDirectory(), !path.contains("..") {
            let target = base.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? file.write(to: target, options: .atomic)
        }
    }

    nonisolated private static func preferenceDomains() -> [String] {
        var domains: [String] = []
        if let bundle = Bundle.main.bundleIdentifier { domains.append(bundle) }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        if let preferences = library?.appendingPathComponent("Preferences"),
           let files = try? FileManager.default.contentsOfDirectory(atPath: preferences.path) {
            for file in files where file.hasSuffix(".plist") {
                let name = String(file.dropLast(6))
                if name.lowercased().contains("nuvio"), !domains.contains(name) { domains.append(name) }
            }
        }
        return domains
    }

    nonisolated private static func supportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    nonisolated private static func supportFiles() -> [(String, URL)] {
        guard let base = supportDirectory(),
              let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var result: [(String, URL)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.hasPrefix("WatchPartyStaging") { continue }
            result.append((relative, url))
        }
        return result
    }

    // MARK: - Pull

    nonisolated private static func pullNewer(token: String, apply: Bool, forceAll: Bool = false) async throws {
        let remote = try await listSections(token: token)
        var state = loadState()
        // Staged sections from a previous run are applied first (we are at launch now).
        if apply {
            for name in state.stagedSections {
                if let content = readStaged(name) { self.apply(sectionContent: content) }
            }
            state.stagedSections = []
            clearStaged()
        }
        for (name, updatedAt) in remote where name.hasPrefix("tv.") {
            let known = state.versions[name] ?? 0
            if !forceAll && updatedAt <= known { continue }
            let data = try await request("GET", "/v1/data/\(name)", json: nil, token: token)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = object["data"] as? String else { continue }
            if apply {
                self.apply(sectionContent: content)
            } else {
                writeStaged(name, content)
                state.stagedSections.insert(name)
            }
            state.versions[name] = updatedAt
            state.hashes[name] = sha256(content)
        }
        saveState(state)
    }

    nonisolated private static func listSections(token: String) async throws -> [String: Int64] {
        let data = try await request("GET", "/v1/data", json: nil, token: token)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sections = object?["sections"] as? [String: Any] ?? [:]
        return sections.mapValues { ($0 as? NSNumber)?.int64Value ?? 0 }
    }

    // MARK: - Staging

    nonisolated private static var stagingDirectory: URL? {
        supportDirectory()?.appendingPathComponent("WatchPartyStaging", isDirectory: true)
    }

    nonisolated private static func writeStaged(_ name: String, _ content: String) {
        guard let dir = stagingDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content.data(using: .utf8)?.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    nonisolated private static func readStaged(_ name: String) -> String? {
        guard let url = stagingDirectory?.appendingPathComponent(name),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func clearStaged() {
        if let dir = stagingDirectory { try? FileManager.default.removeItem(at: dir) }
    }

    nonisolated private static func hasStaged() -> Bool {
        !loadState().stagedSections.isEmpty
    }

    // MARK: - HTTP

    nonisolated private static func request(_ method: String, _ path: String, json: Any?, token: String?) async throws -> Data {
        var request = URLRequest(url: server.appendingPathComponent(path), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WatchParty-AppleTV", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountError(code: "network")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if status == 401, token != nil { deleteToken() }
            throw AccountError(code: object?["error"] as? String ?? "http_\(status)")
        }
        return data
    }

    // MARK: - State + keychain

    private struct AccountState: Codable {
        var username: String?
        var isAdmin = false
        var versions: [String: Int64] = [:]
        var hashes: [String: String] = [:]
        var stagedSections: Set<String> = []
    }

    nonisolated private static func loadState() -> AccountState {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(AccountState.self, from: data) else { return AccountState() }
        return state
    }

    nonisolated private static func saveState(_ state: AccountState) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey) }
    }

    nonisolated private static func readToken() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func writeToken(_ token: String) {
        deleteToken()
        var query = keychainQuery()
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    nonisolated private static func deleteToken() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    nonisolated private static func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "token"]
    }

    nonisolated private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func shortHash(_ text: String) -> String {
        String(sha256(text).prefix(20))
    }
}

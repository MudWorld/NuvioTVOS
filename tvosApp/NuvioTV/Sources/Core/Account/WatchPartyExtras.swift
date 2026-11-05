import Foundation

/// WatchParty server extras on Apple TV (nuvio-account/server.py, /v1/...):
/// provider status from the nightly check, "link does not work" reports and opt-in error reports.
enum WatchPartyExtras {
    private static let server = "https://sync.mudworld.space"
    private static let providerDownKey = "watchparty.extras.providerDown"
    private static let providerCheckedKey = "watchparty.extras.providerChecked"
    static let diagnosticsEnabledKey = "watchparty.extras.diagnosticsEnabled"
    private static let runningKey = "watchparty.extras.running"
    private static let germanProvidersMarker = "nuvio-german-providers"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var downCache: Set<String>?

    /// Call once at launch. Sends an error report when the last run ended while in the foreground.
    static func start() {
        let crashedLastRun = UserDefaults.standard.bool(forKey: runningKey)
        markRunning(true)
        Task.detached(priority: .utility) {
            if crashedLastRun, diagnosticsEnabled {
                _ = try? await sendReport(kind: "crash", headline: "Apple TV app ended unexpectedly during the last run")
            }
            await refreshProviderStatus()
        }
    }

    /// Foreground = running; going to the background is a clean stop.
    static func markRunning(_ running: Bool) {
        UserDefaults.standard.set(running, forKey: runningKey)
    }

    // MARK: - Provider status

    static func refreshProviderStatus(force: Bool = false) async {
        let last = UserDefaults.standard.double(forKey: providerCheckedKey)
        if !force, Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        guard let object = try? await request("GET", "/v1/plugin-status", json: nil, bearer: nil),
              let providers = object["providers"] as? [String: Any] else { return }
        let down = providers.compactMap { key, value -> String? in
            ((value as? [String: Any])?["status"] as? String) == "down" ? key : nil
        }
        UserDefaults.standard.set(down, forKey: providerDownKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: providerCheckedKey)
        lock.lock()
        downCache = Set(down)
        lock.unlock()
    }

    /// German Providers that failed two nightly checks in a row; the stream search skips them.
    static func isProviderDown(scraperId: String, repositoryURL: String) -> Bool {
        guard repositoryURL.localizedCaseInsensitiveContains(germanProvidersMarker) else { return false }
        lock.lock()
        defer { lock.unlock() }
        if downCache == nil {
            downCache = Set(UserDefaults.standard.stringArray(forKey: providerDownKey) ?? [])
        }
        return downCache?.contains(scraperId) == true
    }

    // MARK: - "Link does not work"

    static func reportBrokenStream(_ stream: NuvioStream, meta: NuvioMeta, episode: NuvioVideo?) async -> Bool {
        var title = meta.name
        if let episode { title += " · S\(episode.season)E\(episode.episode) \(episode.title)" }
        var body: [String: Any] = [
            "platform": "appletv",
            "appVersion": appVersion,
            "provider": stream.addonName ?? "",
            "title": title,
            "contentId": meta.id,
            "contentType": meta.type,
            "streamName": [stream.name, stream.description].compactMap { $0 }.joined(separator: " · "),
            "error": recentProblems(limit: 6),
        ]
        if let episode {
            body["season"] = episode.season
            body["episode"] = episode.episode
        }
        return (try? await request("POST", "/v1/reports", json: body, bearer: WatchPartyAccount.deviceToken())) != nil
    }

    // MARK: - Error reports

    static var diagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: diagnosticsEnabledKey)
    }

    @discardableResult
    static func sendReport(kind: String = "log", headline: String = "Report sent from the settings") async throws -> Bool {
        let lines = PlaybackDiagnosticLogStore.shared.snapshot().suffix(300).map { entry in
            "\(ISO8601DateFormatter().string(from: entry.timestamp)) [\(entry.source)] \(entry.message)"
        }
        var text = "\(headline)\nApple TV, WatchParty \(appVersion)\n\n--- recent playback log ---\n"
        text += lines.joined(separator: "\n")
        if let timeline = await timelineJSON() {
            text += "\n\n--- playback timeline ---\n" + timeline
        }
        _ = try await request("POST", "/v1/diagnostics", json: [
            "platform": "appletv", "appVersion": appVersion, "device": "Apple TV", "kind": kind,
            "text": String(text.prefix(250_000)),
        ], bearer: WatchPartyAccount.deviceToken())
        return true
    }

    private static func timelineJSON() async -> String? {
        await withCheckedContinuation { continuation in
            PlaybackDiagnosticTimelineStore.shared.snapshot { snapshot in
                let text = snapshot.timeline.encoded().flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: text.map { String($0.suffix(120_000)) })
            }
        }
    }

    private static func recentProblems(limit: Int) -> String {
        PlaybackDiagnosticLogStore.shared.snapshot().suffix(limit)
            .map { "[\($0.source)] \($0.message)" }
            .joined(separator: "\n")
            .prefix(1800)
            .description
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - HTTP

    private static func request(_ method: String, _ path: String, json: [String: Any]?, bearer: String?) async throws -> [String: Any] {
        guard let url = URL(string: server + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WatchParty-AppleTV", forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else { throw URLError(.badServerResponse) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

//
//  PluginStore.swift
//  NuvioTV
//
//  Settings → Integrations → Plugins: the repositories the user added and
//  their scrapers. Repository and scraper metadata persist in UserDefaults;
//  scraper code goes to the caches directory (tvOS may purge it, so it is
//  re-downloaded on demand) because UserDefaults is size-limited on tvOS.
//

import CryptoKit
import Foundation

@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    @Published private(set) var repositories: [PluginRepositoryItem] = []
    @Published private(set) var scrapers: [PluginScraper] = []
    @Published private(set) var refreshingURLs: Set<String> = []
    @Published var pluginsEnabled: Bool = true {
        didSet { if oldValue != pluginsEnabled { persist() } }
    }

    private static let stateKey = "nuvio.plugins.state.v1"

    private struct StoredState: Codable {
        var pluginsEnabled: Bool
        var repositories: [PluginRepositoryItem]
        var scrapers: [PluginScraper]
    }

    enum AddError: LocalizedError {
        case invalidURL
        case alreadyAdded
        case noScrapers
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid repository URL"
            case .alreadyAdded: return "This repository is already added"
            case .noScrapers: return "The manifest lists no scrapers for tvOS"
            case .failed(let message): return message
            }
        }
    }

    private init() {
        load()
    }

    // MARK: - Queries

    var hasEnabledScrapers: Bool {
        pluginsEnabled && scrapers.contains { $0.enabled && $0.manifestEnabled }
    }

    func enabledScrapers(forType type: String) -> [PluginScraper] {
        guard pluginsEnabled else { return [] }
        return scrapers.filter { $0.enabled && $0.manifestEnabled && $0.supportsType(type) }
    }

    func scrapers(in repository: PluginRepositoryItem) -> [PluginScraper] {
        scrapers.filter { $0.repositoryURL == repository.manifestURL }
    }

    // MARK: - Mutations

    @discardableResult
    func addRepository(rawURL: String) async throws -> PluginRepositoryItem {
        guard let manifestURL = Self.normalizedManifestURL(rawURL) else { throw AddError.invalidURL }
        if repositories.contains(where: { $0.manifestURL.caseInsensitiveCompare(manifestURL) == .orderedSame }) {
            throw AddError.alreadyAdded
        }
        refreshingURLs.insert(manifestURL)
        defer { refreshingURLs.remove(manifestURL) }

        let fetched: (PluginRepositoryItem, [PluginScraper])
        do {
            fetched = try await Self.fetchRepository(manifestURL: manifestURL, previous: [:])
        } catch let error as AddError {
            throw error
        } catch {
            throw AddError.failed(error.localizedDescription)
        }
        guard !fetched.1.isEmpty else { throw AddError.noScrapers }
        repositories.append(fetched.0)
        scrapers.append(contentsOf: fetched.1)
        persist()
        return fetched.0
    }

    func removeRepository(_ repository: PluginRepositoryItem) {
        let removed = scrapers.filter { $0.repositoryURL == repository.manifestURL }
        removed.forEach { PluginCodeCache.remove(scraperId: $0.id) }
        scrapers.removeAll { $0.repositoryURL == repository.manifestURL }
        repositories.removeAll { $0.manifestURL == repository.manifestURL }
        persist()
    }

    func refreshAll() async {
        for repository in repositories {
            await refresh(repository)
        }
    }

    func refresh(_ repository: PluginRepositoryItem) async {
        let url = repository.manifestURL
        guard !refreshingURLs.contains(url) else { return }
        refreshingURLs.insert(url)
        defer { refreshingURLs.remove(url) }

        let previous = Dictionary(
            scrapers.filter { $0.repositoryURL == url }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        do {
            let (item, fresh) = try await Self.fetchRepository(manifestURL: url, previous: previous)
            if let index = repositories.firstIndex(where: { $0.manifestURL == url }) {
                repositories[index] = item
            }
            let freshIDs = Set(fresh.map(\.id))
            previous.keys.filter { !freshIDs.contains($0) }.forEach { PluginCodeCache.remove(scraperId: $0) }
            scrapers.removeAll { $0.repositoryURL == url }
            scrapers.append(contentsOf: fresh)
        } catch {
            if let index = repositories.firstIndex(where: { $0.manifestURL == url }) {
                repositories[index].errorMessage = error.localizedDescription
            }
        }
        persist()
    }

    func setScraper(_ scraper: PluginScraper, enabled: Bool) {
        guard let index = scrapers.firstIndex(where: { $0.id == scraper.id }) else { return }
        scrapers[index].enabled = enabled && scrapers[index].manifestEnabled
        persist()
    }

    /// The scraper's JS, from the cache or downloaded again if tvOS purged it.
    nonisolated static func code(for scraper: PluginScraper) async throws -> String {
        if let cached = PluginCodeCache.read(scraperId: scraper.id) { return cached }
        guard let url = URL(string: scraper.codeURL) else { throw AddError.invalidURL }
        let code = try await fetchText(url)
        PluginCodeCache.write(code, scraperId: scraper.id)
        return code
    }

    // MARK: - Fetching

    nonisolated private static func fetchRepository(
        manifestURL: String,
        previous: [String: PluginScraper]
    ) async throws -> (PluginRepositoryItem, [PluginScraper]) {
        guard let url = URL(string: manifestURL) else { throw AddError.invalidURL }
        let payload = try await fetchText(url)
        guard let data = payload.data(using: .utf8) else { throw AddError.failed("Manifest is not UTF-8") }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw AddError.failed("Not a plugin repository manifest")
        }
        guard !manifest.name.isEmpty else { throw AddError.failed("Manifest has no name") }

        let baseURL = manifestURL
            .components(separatedBy: "?").first!
            .replacingOccurrences(of: "/manifest.json", with: "", options: [.anchored, .backwards])

        let infos = manifest.scrapers.filter(\.isSupportedOnTVOS)
        let built: [PluginScraper] = await withTaskGroup(of: PluginScraper?.self) { group in
            for info in infos {
                group.addTask {
                    let codeURL = info.filename.hasPrefix("http://") || info.filename.hasPrefix("https://")
                        ? info.filename
                        : baseURL + "/" + info.filename.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard let url = URL(string: codeURL),
                          let code = try? await fetchText(url) else { return nil }
                    let id = "\(manifestURL.lowercased()):\(info.id)"
                    PluginCodeCache.write(code, scraperId: id)
                    let wasEnabled = previous[id]?.enabled
                    return PluginScraper(
                        id: id,
                        repositoryURL: manifestURL,
                        scraperId: info.id,
                        name: info.name,
                        description: info.description ?? "",
                        version: info.version,
                        codeURL: codeURL,
                        supportedTypes: info.supportedTypes,
                        enabled: info.enabled && (wasEnabled ?? true),
                        manifestEnabled: info.enabled,
                        logo: info.logo,
                        contentLanguage: info.contentLanguage ?? []
                    )
                }
            }
            var result: [PluginScraper] = []
            for await scraper in group {
                if let scraper { result.append(scraper) }
            }
            return result
        }
        // Keep manifest order rather than download-completion order.
        let order = Dictionary(infos.enumerated().map { ("\(manifestURL.lowercased()):\($0.element.id)", $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        let sorted = built.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }

        let item = PluginRepositoryItem(
            manifestURL: manifestURL,
            name: manifest.name,
            description: manifest.description,
            version: manifest.version,
            scraperCount: sorted.count,
            lastUpdated: Date(),
            errorMessage: nil
        )
        return (item, sorted)
    }

    nonisolated private static func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (AppleTV; tvOS 18.0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AddError.failed("HTTP \(status) for \(url.lastPathComponent)")
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Accepts a bare host/path, adds https:// and /manifest.json like Android.
    nonisolated static func normalizedManifestURL(_ raw: String) -> String? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        if let hash = trimmed.firstIndex(of: "#") { trimmed = String(trimmed[..<hash]) }
        var path = trimmed
        var query = ""
        if let questionMark = trimmed.firstIndex(of: "?") {
            path = String(trimmed[..<questionMark])
            query = String(trimmed[trimmed.index(after: questionMark)...])
        }
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/manifest.json") { path += "/manifest.json" }
        let result = query.isEmpty ? path : "\(path)?\(query)"
        guard let url = URL(string: result), url.host != nil else { return nil }
        return result
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else { return }
        // Lists first: the pluginsEnabled observer persists the whole state.
        repositories = state.repositories
        scrapers = state.scrapers
        pluginsEnabled = state.pluginsEnabled
    }

    private func persist() {
        let state = StoredState(pluginsEnabled: pluginsEnabled, repositories: repositories, scrapers: scrapers)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }
}

/// Scraper JS on disk, keyed by a hash of the scraper id.
enum PluginCodeCache {
    private static var directory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for scraperId: String) -> URL? {
        let digest = SHA256.hash(data: Data(scraperId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent("\(digest).js")
    }

    static func read(scraperId: String) -> String? {
        guard let url = fileURL(for: scraperId) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func write(_ code: String, scraperId: String) {
        guard let url = fileURL(for: scraperId) else { return }
        try? code.write(to: url, atomically: true, encoding: .utf8)
    }

    static func remove(scraperId: String) {
        guard let url = fileURL(for: scraperId) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

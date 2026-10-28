//
//  LiveTVStore.swift
//  NuvioTV
//
//  IPTV via M3U playlists: Settings → Integrations → Live TV keeps a list of
//  playlist URLs, this store downloads and parses them, and the Live TV tab
//  shows the channels grouped by `group-title`.
//

import CryptoKit
import Foundation

struct LiveTVPlaylist: Codable, Identifiable, Equatable {
    var id: String { url }
    let url: String
    var name: String
    var channelCount: Int
    var lastUpdated: Date?
    var errorMessage: String?
}

struct LiveTVChannel: Codable, Identifiable, Hashable {
    /// Stable per playlist and stream URL, also used as the player meta id.
    let id: String
    let name: String
    let group: String
    let logoURL: String?
    let streamURL: String
    let playlistURL: String
}

@MainActor
final class LiveTVStore: ObservableObject {
    static let shared = LiveTVStore()

    @Published private(set) var playlists: [LiveTVPlaylist] = []
    @Published private(set) var channels: [LiveTVChannel] = []
    @Published private(set) var refreshingURLs: Set<String> = []

    nonisolated private static let playlistsKey = "nuvio.livetv.playlists.v1"

    enum AddError: LocalizedError {
        case invalidURL, alreadyAdded, noChannels, failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid playlist URL"
            case .alreadyAdded: return "This playlist is already added"
            case .noChannels: return "No playable channels found in this playlist"
            case .failed(let message): return message
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.playlistsKey),
           let stored = try? JSONDecoder().decode([LiveTVPlaylist].self, from: data) {
            playlists = stored
        }
        channels = playlists.flatMap { LiveTVChannelCache.read(playlistURL: $0.url) ?? [] }
        // tvOS may purge caches; fetch again whatever is missing.
        let missing = playlists.filter { LiveTVChannelCache.read(playlistURL: $0.url) == nil }
        if !missing.isEmpty {
            Task { for playlist in missing { await refresh(playlist) } }
        }
    }

    /// Whether the Live TV tab exists, readable outside the main actor.
    nonisolated static var hasPlaylists: Bool {
        guard let data = UserDefaults.standard.data(forKey: playlistsKey),
              let stored = try? JSONDecoder().decode([LiveTVPlaylist].self, from: data) else { return false }
        return !stored.isEmpty
    }

    /// Channel groups in playlist order, each with its channels.
    var groups: [(name: String, channels: [LiveTVChannel])] {
        var order: [String] = []
        var byGroup: [String: [LiveTVChannel]] = [:]
        for channel in channels {
            if byGroup[channel.group] == nil { order.append(channel.group) }
            byGroup[channel.group, default: []].append(channel)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    @discardableResult
    func addPlaylist(rawURL: String) async throws -> LiveTVPlaylist {
        var trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.host != nil else { throw AddError.invalidURL }
        guard !playlists.contains(where: { $0.url == trimmed }) else { throw AddError.alreadyAdded }

        refreshingURLs.insert(trimmed)
        defer { refreshingURLs.remove(trimmed) }
        let parsed: [LiveTVChannel]
        do {
            parsed = try await Self.download(url: url, playlistURL: trimmed)
        } catch {
            throw AddError.failed(error.localizedDescription)
        }
        guard !parsed.isEmpty else { throw AddError.noChannels }

        let playlist = LiveTVPlaylist(
            url: trimmed,
            name: url.host.map { "\($0)\(url.path.isEmpty ? "" : " · " + url.lastPathComponent)" } ?? trimmed,
            channelCount: parsed.count,
            lastUpdated: Date(),
            errorMessage: nil
        )
        LiveTVChannelCache.write(parsed, playlistURL: trimmed)
        playlists.append(playlist)
        channels += parsed
        persist()
        return playlist
    }

    func removePlaylist(_ playlist: LiveTVPlaylist) {
        LiveTVChannelCache.remove(playlistURL: playlist.url)
        playlists.removeAll { $0.url == playlist.url }
        channels.removeAll { $0.playlistURL == playlist.url }
        persist()
    }

    func refreshAll() async {
        for playlist in playlists { await refresh(playlist) }
    }

    func refresh(_ playlist: LiveTVPlaylist) async {
        guard !refreshingURLs.contains(playlist.url), let url = URL(string: playlist.url) else { return }
        refreshingURLs.insert(playlist.url)
        defer { refreshingURLs.remove(playlist.url) }
        let index = playlists.firstIndex { $0.url == playlist.url }
        do {
            let parsed = try await Self.download(url: url, playlistURL: playlist.url)
            LiveTVChannelCache.write(parsed, playlistURL: playlist.url)
            // Replace this playlist's channels in place to keep playlist order.
            channels = playlists.flatMap { item in
                item.url == playlist.url ? parsed : channels.filter { $0.playlistURL == item.url }
            }
            if let index {
                playlists[index].channelCount = parsed.count
                playlists[index].lastUpdated = Date()
                playlists[index].errorMessage = nil
            }
        } catch {
            if let index { playlists[index].errorMessage = error.localizedDescription }
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: Self.playlistsKey)
    }

    nonisolated private static func download(url: URL, playlistURL: String) async throws -> [LiveTVChannel] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (AppleTV; tvOS 18.0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw AddError.failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return M3UParser.parse(text, playlistURL: playlistURL)
    }
}

// MARK: - M3U

enum M3UParser {
    /// Parses `#EXTINF` entries (attributes `tvg-logo`, `group-title`,
    /// `tvg-name`) and `#EXTGRP`. Entries that tvOS cannot play directly
    /// (YouTube pages, rtmp/udp) are skipped.
    static func parse(_ text: String, playlistURL: String) -> [LiveTVChannel] {
        var result: [LiveTVChannel] = []
        var seen = Set<String>()
        var pendingInfo: String?
        var pendingGroup: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                pendingInfo = line
                pendingGroup = nil
                continue
            }
            if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("#") { continue }

            guard let info = pendingInfo else { continue }
            pendingInfo = nil
            let lower = line.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
                  !lower.contains("youtube.com/"), !lower.contains("youtu.be/") else { continue }
            guard seen.insert(line).inserted else { continue }

            let attributes = attributes(in: info)
            let displayName: String = {
                if let comma = info.lastIndex(of: ",") {
                    let name = info[info.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return name }
                }
                return attributes["tvg-name"] ?? "Channel"
            }()
            let group = attributes["group-title"].flatMap { $0.isEmpty ? nil : $0 }
                ?? pendingGroup.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Channels"
            let logo = attributes["tvg-logo"].flatMap { $0.hasPrefix("http") ? $0 : nil }

            result.append(LiveTVChannel(
                id: "iptv:" + shortHash(playlistURL + "|" + line),
                name: displayName,
                group: group,
                logoURL: logo,
                streamURL: line,
                playlistURL: playlistURL
            ))
        }
        return result
    }

    private static let attributeRegex = try? NSRegularExpression(pattern: #"([A-Za-z0-9_-]+)="([^"]*)""#)

    private static func attributes(in line: String) -> [String: String] {
        guard let attributeRegex else { return [:] }
        var output: [String: String] = [:]
        let range = NSRange(line.startIndex..., in: line)
        for match in attributeRegex.matches(in: line, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            output[line[keyRange].lowercased()] = String(line[valueRange])
        }
        return output
    }

    static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

/// Parsed channels per playlist in the caches directory.
enum LiveTVChannelCache {
    private static func fileURL(for playlistURL: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(M3UParser.shortHash(playlistURL) + ".json")
    }

    static func read(playlistURL: String) -> [LiveTVChannel]? {
        guard let url = fileURL(for: playlistURL), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LiveTVChannel].self, from: data)
    }

    static func write(_ channels: [LiveTVChannel], playlistURL: String) {
        guard let url = fileURL(for: playlistURL), let data = try? JSONEncoder().encode(channels) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(playlistURL: String) {
        guard let url = fileURL(for: playlistURL) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

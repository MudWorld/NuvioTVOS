//
//  PluginStreamService.swift
//  NuvioTV
//
//  Turns a title/episode into plugin stream groups for StreamsRepository:
//  resolves the TMDB id plugins expect, runs every enabled scraper and maps
//  their results onto NuvioStream.
//

import Foundation

enum PluginStreamService {
    /// Group ids start with this so they never collide with add-on groups.
    static let groupIdPrefix = "plugin:"

    struct Target {
        let scraper: PluginScraper
        var groupId: String { PluginStreamService.groupIdPrefix + scraper.id }
    }

    @MainActor
    static func targets(type: String) -> [Target] {
        PluginStore.shared.enabledScrapers(forType: type).map(Target.init)
    }

    /// Runs one scraper and returns its finished group (streams or error).
    static func fetchGroup(
        target: Target,
        type: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        tmdbApiKey: String?
    ) async -> AddonStreamGroup {
        let scraper = target.scraper
        let mediaType = PluginScraper.normalizedType(type)
        let contentId = pluginContentId(videoId: videoId, season: season, episode: episode)
        let tmdbId = await resolveTmdbId(contentId, mediaType: mediaType, apiKey: tmdbApiKey)

        let code: String
        do {
            code = try await PluginStore.code(for: scraper)
        } catch {
            return AddonStreamGroup(
                addonId: target.groupId,
                displayName: scraper.name,
                streams: [],
                isLoading: false,
                error: "Could not load plugin code"
            )
        }

        let results = await PluginRuntime.execute(
            code: code,
            scraperId: scraper.id,
            tmdbId: tmdbId,
            mediaType: mediaType,
            season: season,
            episode: episode,
            tmdbApiKey: tmdbApiKey
        )
        let streams = results.map { toNuvioStream($0, scraper: scraper) }
        return AddonStreamGroup(
            addonId: target.groupId,
            displayName: scraper.name,
            streams: streams,
            isLoading: false,
            error: nil
        )
    }

    static func toNuvioStream(_ result: PluginStreamResult, scraper: PluginScraper) -> NuvioStream {
        let details = [result.quality, result.size, result.language]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let headers = (result.headers ?? [:]).reduce(into: [String: String]()) { output, entry in
            let name = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty, name.caseInsensitiveCompare("Range") != .orderedSame else { return }
            output[name] = value
        }
        return NuvioStream(
            url: result.url,
            name: result.name ?? result.title,
            description: details.isEmpty ? result.title : ([result.title] + details).joined(separator: "\n"),
            addonName: scraper.name,
            subtitles: result.subtitles.map {
                NuvioSubtitle(url: $0.url, language: $0.language, label: $0.name, source: scraper.name)
            },
            addonLogoURL: scraper.logo,
            infoHash: result.infoHash,
            httpHeaders: headers.isEmpty ? nil : headers
        )
    }

    // MARK: - Ids

    /// Port of Android `pluginContentId`: strip `tmdb:` and the `:s:e` suffix.
    static func pluginContentId(videoId: String, season: Int?, episode: Int?) -> String {
        let trimmed = videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return videoId }
        var value = trimmed
        if value.hasPrefix("tmdb:") || value.hasPrefix("tmdb/") { value = String(value.dropFirst(5)) }
        if let season, let episode, value.hasSuffix(":\(season):\(episode)") {
            value = String(value.dropLast(":\(season):\(episode)".count))
        }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        return value.isEmpty ? trimmed : value
    }

    private static let tmdbCache = PluginTmdbIdCache()

    /// Plugins expect a TMDB id; Cinemeta titles carry IMDb ids.
    static func resolveTmdbId(_ contentId: String, mediaType: String, apiKey: String?) async -> String {
        guard contentId.hasPrefix("tt"), let apiKey, !apiKey.isEmpty else { return contentId }
        let cacheKey = "\(mediaType):\(contentId)"
        if let cached = await tmdbCache.value(for: cacheKey) { return cached }

        var components = URLComponents(string: "https://api.themoviedb.org/3/find/\(contentId)")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "external_source", value: "imdb_id"),
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return contentId
        }
        let movie = (object["movie_results"] as? [[String: Any]])?.first?["id"]
        let show = (object["tv_results"] as? [[String: Any]])?.first?["id"]
        let preferred = mediaType == "tv" ? (show ?? movie) : (movie ?? show)
        guard let number = preferred as? NSNumber else { return contentId }
        let resolved = number.stringValue
        await tmdbCache.store(resolved, for: cacheKey)
        return resolved
    }

    @MainActor
    static var tmdbApiKey: String? {
        let key = ProfileSettings.current.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }
}

private actor PluginTmdbIdCache {
    private var values: [String: String] = [:]

    func value(for key: String) -> String? { values[key] }
    func store(_ value: String, for key: String) { values[key] = value }
}

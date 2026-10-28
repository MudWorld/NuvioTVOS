//
//  PluginModels.swift
//  NuvioTV
//
//  JS scraper plugin repositories, matching the Android/iOS plugin format
//  (composeApp/.../features/plugins/PluginModels.kt): a repository serves a
//  `manifest.json` with a `scrapers` list, each scraper is one JS file that
//  exports `getStreams(tmdbId, mediaType, season, episode)`.
//

import Foundation

struct PluginManifest: Decodable {
    let name: String
    let version: String
    let description: String?
    let author: String?
    let scrapers: [PluginManifestScraper]

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, scrapers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        version = (try? container.decode(String.self, forKey: .version)) ?? ""
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        author = try? container.decodeIfPresent(String.self, forKey: .author)
        scrapers = (try? container.decode(LossyArray<PluginManifestScraper>.self, forKey: .scrapers).elements) ?? []
    }
}

struct PluginManifestScraper: Decodable {
    let id: String
    let name: String
    let description: String?
    let version: String
    let filename: String
    let supportedTypes: [String]
    let enabled: Bool
    let logo: String?
    let contentLanguage: [String]?
    let supportedPlatforms: [String]?
    let disabledPlatforms: [String]?
    let formats: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, version, filename, supportedTypes, enabled, logo
        case contentLanguage, supportedPlatforms, disabledPlatforms, formats, supportedFormats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        version = (try? container.decode(String.self, forKey: .version)) ?? ""
        filename = try container.decode(String.self, forKey: .filename)
        supportedTypes = (try? container.decode([String].self, forKey: .supportedTypes)) ?? ["movie", "tv"]
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        logo = try? container.decodeIfPresent(String.self, forKey: .logo)
        contentLanguage = try? container.decodeIfPresent([String].self, forKey: .contentLanguage)
        supportedPlatforms = try? container.decodeIfPresent([String].self, forKey: .supportedPlatforms)
        disabledPlatforms = try? container.decodeIfPresent([String].self, forKey: .disabledPlatforms)
        formats = (try? container.decodeIfPresent([String].self, forKey: .formats))
            ?? (try? container.decodeIfPresent([String].self, forKey: .supportedFormats))
    }

    /// Same rule as Android: an explicit allow-list must name the platform,
    /// and a deny-list must not. tvOS repositories may list "tvos" or "ios".
    var isSupportedOnTVOS: Bool {
        let platforms: Set<String> = ["tvos", "ios"]
        let supported = Set((supportedPlatforms ?? []).map { $0.lowercased() })
        let disabled = Set((disabledPlatforms ?? []).map { $0.lowercased() })
        if !supported.isEmpty, supported.isDisjoint(with: platforms) { return false }
        if disabled.contains("tvos") { return false }
        return true
    }
}

/// A repository the user added, persisted without scraper code.
struct PluginRepositoryItem: Codable, Identifiable, Equatable {
    var id: String { manifestURL }
    let manifestURL: String
    var name: String
    var description: String?
    var version: String?
    var scraperCount: Int
    var lastUpdated: Date?
    var errorMessage: String?
}

/// One scraper of a repository. The JS code lives in `PluginCodeCache`.
struct PluginScraper: Codable, Identifiable, Equatable {
    /// `<lowercased manifest url>:<scraper id>`, unique across repositories.
    let id: String
    let repositoryURL: String
    let scraperId: String
    var name: String
    var description: String
    var version: String
    var codeURL: String
    var supportedTypes: [String]
    var enabled: Bool
    var manifestEnabled: Bool
    var logo: String?
    var contentLanguage: [String]

    func supportsType(_ type: String) -> Bool {
        let normalized = PluginScraper.normalizedType(type)
        return supportedTypes.contains { PluginScraper.normalizedType($0) == normalized }
    }

    /// Plugins speak TMDB media types: `movie` or `tv`.
    static func normalizedType(_ value: String) -> String {
        switch value.lowercased() {
        case "series", "show", "tv", "other", "anime": return "tv"
        default: return value.lowercased()
        }
    }
}

/// One stream a scraper returned from `getStreams`.
struct PluginStreamResult {
    let title: String
    let name: String?
    let url: String
    let quality: String?
    let size: String?
    let language: String?
    let provider: String?
    let infoHash: String?
    let headers: [String: String]?
    let subtitles: [PluginSubtitleResult]
}

struct PluginSubtitleResult {
    let url: String
    let language: String
    let name: String?
}

/// Skips malformed entries instead of failing the whole list.
private struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Discarded.self)
            }
        }
        elements = result
    }

    private struct Discarded: Decodable {}
}

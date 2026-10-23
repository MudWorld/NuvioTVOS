import Foundation

// Wire contract adapted from NuvioMedia/NuvioTV, GPL-3.0.
// Android reference f7e2a78ad3b19a09080ad08315825f1f0a472934:
// app/src/main/java/com/nuvio/tv/core/party/PartyModels.kt

struct WatchPartySource: Codable, Equatable, Sendable {
    var infoHash: String? = nil
    var fileIndex: Int? = nil
    var filename: String? = nil
    var videoSize: Int64? = nil
    var bingeGroup: String? = nil
    var addonID: String? = nil
    var name: String? = nil

    enum CodingKeys: String, CodingKey {
        case infoHash = "info_hash", fileIndex = "file_idx", filename
        case videoSize = "video_size", bingeGroup = "binge_group", addonID = "addon_id", name
    }
}

struct WatchPartyMedia: Codable, Equatable, Sendable {
    var type: String
    var metaID: String
    var metaType: String
    var videoID: String? = nil
    var season: Int? = nil
    var episode: Int? = nil
    var title: String = ""
    var episodeTitle: String? = nil
    var description: String? = nil
    var poster: String? = nil
    var background: String? = nil
    var logo: String? = nil
    var source: WatchPartySource? = nil

    var key: String {
        [metaType.lowercased(), metaID, season.map(String.init) ?? "", episode.map(String.init) ?? ""]
            .joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case type, metaID = "meta_id", metaType = "meta_type", videoID = "video_id"
        case season, episode, title, episodeTitle = "episode_title"
        case description, poster, background, logo, source
    }
}

extension WatchPartyMedia {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try c.decode(String.self, forKey: .type),
            metaID: try c.decode(String.self, forKey: .metaID),
            metaType: try c.decode(String.self, forKey: .metaType),
            videoID: try c.decodeIfPresent(String.self, forKey: .videoID),
            season: try c.decodeIfPresent(Int.self, forKey: .season),
            episode: try c.decodeIfPresent(Int.self, forKey: .episode),
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            episodeTitle: try c.decodeIfPresent(String.self, forKey: .episodeTitle),
            description: try c.decodeIfPresent(String.self, forKey: .description),
            poster: try c.decodeIfPresent(String.self, forKey: .poster),
            background: try c.decodeIfPresent(String.self, forKey: .background),
            logo: try c.decodeIfPresent(String.self, forKey: .logo),
            source: try c.decodeIfPresent(WatchPartySource.self, forKey: .source)
        )
    }
}

struct WatchPartyPlayback: Codable, Equatable, Sendable {
    var seq: Int64
    var memberID: String? = nil
    var paused: Bool
    var positionMs: Int64
    var rate: Float = 1
    var at: Int64
    var mediaKey: String? = nil
    var waiting: Bool = false

    enum CodingKeys: String, CodingKey {
        case seq, memberID = "member_id", paused, positionMs = "position_ms", rate, at
        case mediaKey = "media_key", waiting
    }
}

extension WatchPartyPlayback {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rate = try c.decodeIfPresent(Float.self, forKey: .rate) ?? 1
        guard rate.isFinite, rate > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .rate, in: c, debugDescription: "Invalid playback rate")
        }
        self.init(
            seq: try c.decode(Int64.self, forKey: .seq),
            memberID: try c.decodeIfPresent(String.self, forKey: .memberID),
            paused: try c.decode(Bool.self, forKey: .paused),
            positionMs: try c.decode(Int64.self, forKey: .positionMs),
            rate: rate,
            at: try c.decode(Int64.self, forKey: .at),
            mediaKey: try c.decodeIfPresent(String.self, forKey: .mediaKey),
            waiting: try c.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        )
    }
}

struct WatchPartyMember: Codable, Equatable, Sendable {
    var id: String
    var displayName: String
    var avatarURL: String? = nil
    var avatarColor: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", avatarURL = "avatar_url", avatarColor = "avatar_color"
    }
}

struct WatchPartyNotice: Equatable, Sendable {
    var message: String
    var avatarURL: String? = nil
    var avatarColor: String? = nil
    var initials: String? = nil
}

struct WatchPartyChatMessage: Codable, Equatable, Sendable {
    var id: Int64? = nil
    var memberID: String
    var name: String? = nil
    var avatarURL: String? = nil
    var avatarColor: String? = nil
    var body: String
    var clientID: String? = nil
    var sentAt: Int64? = nil
    var mine: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case memberID = "member_id"
        case name
        case avatarURL = "avatar_url"
        case avatarColor = "avatar_color"
        case body
        case clientID = "client_id"
        case sentAt = "sent_at"
        case mine
    }
}

extension WatchPartyChatMessage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let intVal = try? c.decode(Int64.self, forKey: .id) {
            id = intVal
        } else if let strVal = try? c.decode(String.self, forKey: .id), let intVal = Int64(strVal) {
            id = intVal
        } else {
            id = nil
        }
        memberID = (try? c.decode(String.self, forKey: .memberID)) ?? ""
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        avatarURL = try? c.decodeIfPresent(String.self, forKey: .avatarURL)
        avatarColor = try? c.decodeIfPresent(String.self, forKey: .avatarColor)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        clientID = try? c.decodeIfPresent(String.self, forKey: .clientID)
        if let intVal = try? c.decode(Int64.self, forKey: .sentAt) {
            sentAt = intVal
        } else if let strVal = try? c.decode(String.self, forKey: .sentAt), let intVal = Int64(strVal) {
            sentAt = intVal
        } else {
            sentAt = nil
        }
        mine = try? c.decodeIfPresent(Bool.self, forKey: .mine)
    }
}

enum WatchPartyMemberStatus: String, Codable, Sendable {
    case browsing, loading, buffering, ready, behind
}

struct WatchPartyPresence: Codable, Equatable, Sendable {
    var memberID: String
    var status: WatchPartyMemberStatus = .browsing
    var mediaKey: String? = nil
    var behindMs: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case memberID = "member_id", status, mediaKey = "media_key", behindMs = "behind_ms"
    }
}

extension WatchPartyPresence {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            memberID: try c.decode(String.self, forKey: .memberID),
            status: try c.decodeIfPresent(WatchPartyMemberStatus.self, forKey: .status) ?? .browsing,
            mediaKey: try c.decodeIfPresent(String.self, forKey: .mediaKey),
            behindMs: try c.decodeIfPresent(Int64.self, forKey: .behindMs)
        )
    }
}

struct WatchPartyInfo: Codable, Equatable, Sendable {
    var id: String
    var code: String
    var hostMemberID: String? = nil
    var hostOnly: Bool = false
    var media: WatchPartyMedia
    var playback: WatchPartyPlayback? = nil
    var maxMembers: Int = 3

    enum CodingKeys: String, CodingKey {
        case id, code, hostMemberID = "host_member_id", hostOnly = "host_only", media, playback
        case maxMembers = "max_members"
    }
}

extension WatchPartyInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            code: try c.decode(String.self, forKey: .code),
            hostMemberID: try c.decodeIfPresent(String.self, forKey: .hostMemberID),
            hostOnly: try c.decodeIfPresent(Bool.self, forKey: .hostOnly) ?? false,
            media: try c.decode(WatchPartyMedia.self, forKey: .media),
            playback: try c.decodeIfPresent(WatchPartyPlayback.self, forKey: .playback),
            maxMembers: try c.decodeIfPresent(Int.self, forKey: .maxMembers) ?? 3
        )
    }
}

struct WatchPartySnapshot: Codable, Equatable, Sendable {
    var party: WatchPartyInfo? = nil
    var members: [WatchPartyMember] = []
    var memberID: String? = nil
    var serverTimeMs: Int64? = nil
    var error: String? = nil
    var ok: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case party, members, memberID = "member_id", serverTimeMs = "server_time_ms", error, ok
    }
}

extension WatchPartySnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            party: try c.decodeIfPresent(WatchPartyInfo.self, forKey: .party),
            members: try c.decodeIfPresent([WatchPartyMember].self, forKey: .members) ?? [],
            memberID: try c.decodeIfPresent(String.self, forKey: .memberID),
            serverTimeMs: try c.decodeIfPresent(Int64.self, forKey: .serverTimeMs),
            error: try c.decodeIfPresent(String.self, forKey: .error),
            ok: try c.decodeIfPresent(Bool.self, forKey: .ok)
        )
    }
}

struct WatchPartyPreview: Codable, Equatable, Sendable {
    var media: WatchPartyMedia? = nil
    var host: WatchPartyMember? = nil
    var members: Int = 0
    var maxMembers: Int = 0
    var error: String? = nil

    var isFull: Bool { maxMembers > 0 && members >= maxMembers }

    enum CodingKeys: String, CodingKey {
        case media, host, members, maxMembers = "max_members", error
    }
}

extension WatchPartyPreview {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            media: try c.decodeIfPresent(WatchPartyMedia.self, forKey: .media),
            host: try c.decodeIfPresent(WatchPartyMember.self, forKey: .host),
            members: try c.decodeIfPresent(Int.self, forKey: .members) ?? 0,
            maxMembers: try c.decodeIfPresent(Int.self, forKey: .maxMembers) ?? 0,
            error: try c.decodeIfPresent(String.self, forKey: .error)
        )
    }
}

enum WatchPartyFailure: Equatable {
    case notFound, full, removed, ended, rateLimited, signInRequired, unavailable, network, invalidCode

    init?(serverCode: String?) {
        guard let serverCode else { return nil }
        switch serverCode {
        case "party_not_found": self = .notFound
        case "party_full": self = .full
        case "removed", "not_member": self = .removed
        case "party_ended": self = .ended
        case "rate_limited": self = .rateLimited
        case "unavailable": self = .unavailable
        default: self = .network
        }
    }
}

enum WatchPartyCode {
    static let length = 6
    private static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { alphabet.contains($0) })
    }

    static func isValid(_ input: String) -> Bool { normalize(input).count == length }

    static func formatted(_ input: String) -> String {
        let code = normalize(input)
        guard code.count == length else { return code }
        return "\(code.prefix(3)) \(code.dropFirst(3))"
    }
}

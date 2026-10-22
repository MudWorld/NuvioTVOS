import Foundation

enum WatchPartyLaunchError: Error { case unsupportedMedia, differentMedia }

/// Matches canonical title/episode identity. Each participant still selects their own stream;
/// source URLs and providers are not part of the room key. No inference from display names or
/// an arbitrary episode of the same series.
enum WatchPartyLaunchPolicy {
    static func validate(_ media: WatchPartyMedia) throws {
        guard !media.metaID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              media.metaID.count <= 512, !media.metaID.contains("|"),
              media.metaID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WatchPartyLaunchError.unsupportedMedia
        }
        switch media.metaType.lowercased() {
        case "movie":
            guard media.season == nil, media.episode == nil else { throw WatchPartyLaunchError.unsupportedMedia }
        case "series":
            guard let season = media.season, season >= 0, let episode = media.episode, episode > 0 else {
                throw WatchPartyLaunchError.unsupportedMedia
            }
        default: throw WatchPartyLaunchError.unsupportedMedia
        }
    }

    /// Room creation needs a canonical title/episode identity, not a stream URL.
    /// A series must select an explicit episode before contacting the server.
    static func mediaForDetails(_ meta: NuvioMeta, episode: NuvioVideo?) throws -> WatchPartyMedia {
        let series = meta.isSeries
        guard (series && episode != nil) || (!series && episode == nil) else {
            throw WatchPartyLaunchError.unsupportedMedia
        }
        let media = WatchPartyMedia(
            type: series ? "series" : "movie",
            metaID: meta.streamId,
            metaType: series ? "series" : "movie",
            videoID: episode?.id,
            season: episode?.season,
            episode: episode?.episode,
            title: meta.name,
            episodeTitle: episode?.title,
            description: meta.description,
            poster: meta.posterUrl,
            background: meta.backgroundUrl,
            logo: meta.logoUrl
        )
        try validate(media)
        return media
    }

    /// Match a locally selected source against the room's accepted title identity.
    /// Preserve a room ID only when it is an exact known identifier for this title;
    /// never infer a match from display names, episode numbers or stream URLs.
    static func mediaForPlayback(
        _ meta: NuvioMeta, episode: NuvioVideo?, room: WatchPartyMedia?
    ) throws -> WatchPartyMedia {
        var media = try mediaForDetails(meta, episode: episode)
        if let room {
            let acceptedIDs = [meta.id, meta.imdbId, meta.streamId].compactMap { $0 }
            if acceptedIDs.contains(room.metaID) {
                media.metaID = room.metaID
            }
        }
        return media
    }

    static func validateSelection(_ selection: WatchPartyMedia, room: WatchPartyMedia) throws {
        try validate(selection)
        try validate(room)
        guard selection.key == room.key else { throw WatchPartyLaunchError.differentMedia }
    }
}


/// Presentation policy for explicit confirmation after the room changes content.
/// Identity uses the canonical media key, never the displayed title.
enum WatchPartyMediaReviewPolicy {
    static func changed(from oldKey: String?, to newKey: String?) -> Bool {
        guard let oldKey, let newKey else { return false }
        return oldKey != newKey
    }

    static func needsConfirmation(previewKey: String, joinedKey: String) -> Bool {
        previewKey != joinedKey
    }
}

/// Prefer an enabled control when the sidebar regains focus after room operations.
enum WatchPartyRoomFocusPolicy {
    static func initialAction(hasRoom: Bool, membershipEnded: Bool,
                              connectionReady: Bool, playerAttached: Bool,
                              busy: Bool, needsMediaReview: Bool = false) -> String? {
        guard !busy else { return nil }
        guard hasRoom else { return "room-code" }
        if membershipEnded { return "leave" }
        if !connectionReady { return "reconnect" }
        if needsMediaReview { return "review-room" }
        return playerAttached ? "return-to-player" : "choose-source"
    }
}


/// Local Details presentation belongs to an exact accepted membership. It never starts playback.
enum WatchPartyDetailsPresentationPolicy {
    static func sameMembership(_ origin: WatchPartyPlaybackContext,
                               _ current: WatchPartyPlaybackContext) -> Bool {
        origin.request == current.request && origin.membershipID == current.membershipID
            && origin.roomID == current.roomID && origin.memberID == current.memberID
    }

    /// A server may omit artwork. Only fill presentation fields for the exact same title/episode.
    static func artwork(for media: WatchPartyMedia, fallback: WatchPartyMedia?) -> WatchPartyMedia {
        let fallback = fallback?.key == media.key ? fallback : nil
        var result = media
        result.poster = nonblank(media.poster) ?? nonblank(fallback?.poster)
        result.background = nonblank(media.background) ?? nonblank(fallback?.background)
        result.logo = nonblank(media.logo) ?? nonblank(fallback?.logo)
        return result
    }

    private static func nonblank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

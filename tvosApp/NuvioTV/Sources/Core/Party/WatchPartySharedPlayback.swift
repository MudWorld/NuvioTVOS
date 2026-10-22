import Foundation

enum WatchPartySharedPlaybackError: Error, Equatable {
    case staleSelection, unsupportedResponseHeaders, missingEpisode, differentMedia
}

struct WatchPartySharedPlaybackTarget {
    let meta: NuvioMeta
    let episode: NuvioVideo?
    let url: URL
    let stream: WatchPartyStream
}

/// Adapts server response headers (e.g. Set-Cookie) into client cookies and request headers.
enum WatchPartyResponseHeadersAdapter {
    /// Adapts stream response headers into effective client request headers and populates
    /// `HTTPCookieStorage.shared` for AVPlayer playback.
    ///
    /// - Parameters:
    ///   - stream: The incoming shared stream with headers and responseHeaders.
    ///   - targetURL: The validated playback destination URL.
    /// - Returns: An adapted `WatchPartyStream` with cookies injected into `headers`
    ///   and `responseHeaders` safely handled.
    static func adapt(stream: WatchPartyStream, targetURL: URL) -> WatchPartyStream {
        guard !stream.responseHeaders.isEmpty else { return stream }
        var adaptedStream = stream
        var effectiveHeaders = stream.headers

        // Normalize response header keys to ensure case-insensitive matching for Set-Cookie
        var normalizedResponseHeaders: [String: String] = [:]
        for (key, value) in stream.responseHeaders {
            if key.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                normalizedResponseHeaders["Set-Cookie"] = value
            } else {
                normalizedResponseHeaders[key] = value
            }
        }

        // Extract and register cookies
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: normalizedResponseHeaders, for: targetURL)
        if !cookies.isEmpty {
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            let cookieRequestHeaders = HTTPCookie.requestHeaderFields(with: cookies)
            for (headerName, headerValue) in cookieRequestHeaders {
                if let existing = effectiveHeaders[headerName], !existing.isEmpty {
                    effectiveHeaders[headerName] = "\(existing); \(headerValue)"
                } else {
                    effectiveHeaders[headerName] = headerValue
                }
            }
        }

        adaptedStream.headers = effectiveHeaders
        // Response headers have been safely adapted; clear them on the playable candidate
        // so downstream components do not attempt to forward them as raw request headers.
        adaptedStream.responseHeaders = [:]
        return adaptedStream
    }
}

/// Resolves catalog identity only. Never probes, logs or persists the private source URL.
enum WatchPartySharedPlaybackResolver {
    @MainActor
    static func resolve(
        stream: WatchPartyStream, room: WatchPartyMedia,
        isCurrent: () -> Bool,
        loadMetadata: (String, String) async throws -> NuvioMeta
    ) async throws -> WatchPartySharedPlaybackTarget {
        try Task.checkCancellation()
        guard isCurrent() else { throw WatchPartySharedPlaybackError.staleSelection }
        try WatchPartyLaunchPolicy.validate(room)
        try WatchPartyStreamPolicy.validate(stream)
        guard stream.mediaKey == room.key else { throw WatchPartySharedPlaybackError.differentMedia }
        guard URL(string: stream.url) != nil else { throw WatchPartyStreamError.invalidURL }
        let meta = try await loadMetadata(room.metaID, room.metaType)
        try Task.checkCancellation()
        guard isCurrent() else { throw WatchPartySharedPlaybackError.staleSelection }
        return try target(meta: meta, stream: stream, room: room)
    }

    static func target(meta: NuvioMeta, stream: WatchPartyStream,
                       room: WatchPartyMedia) throws -> WatchPartySharedPlaybackTarget {
        try WatchPartyLaunchPolicy.validate(room)
        try WatchPartyStreamPolicy.validate(stream)
        let supportedType = meta.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "movie"
            || NuvioMeta.isSeriesType(meta.type)
        guard stream.mediaKey == room.key, supportedType else {
            throw WatchPartySharedPlaybackError.differentMedia
        }
        let episode: NuvioVideo?
        if room.metaType.lowercased() == "series" {
            let matches = (meta.videos ?? []).filter { $0.season == room.season && $0.episode == room.episode }
            guard matches.count == 1 else { throw WatchPartySharedPlaybackError.missingEpisode }
            episode = matches[0]
        } else {
            episode = nil
        }
        let selected = try WatchPartyLaunchPolicy.mediaForPlayback(meta, episode: episode, room: room)
        try WatchPartyLaunchPolicy.validateSelection(selected, room: room)
        guard let url = URL(string: stream.url) else { throw WatchPartyStreamError.invalidURL }
        let adapted = WatchPartyResponseHeadersAdapter.adapt(stream: stream, targetURL: url)
        return WatchPartySharedPlaybackTarget(meta: meta, episode: episode, url: url, stream: adapted)
    }
}

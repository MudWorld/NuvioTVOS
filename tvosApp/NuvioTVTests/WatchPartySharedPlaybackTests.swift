import XCTest
@testable import NuvioTV

@MainActor
final class WatchPartySharedPlaybackTests: XCTestCase {
    private let movie = WatchPartyMedia(type: "movie", metaID: "tt42", metaType: "movie")

    private func stream(_ key: String = "movie|tt42||") -> WatchPartyStream {
        WatchPartyStream(mediaKey: key, url: "https://media.example.test/movie.m3u8?token=PRIVATE",
                         headers: ["Referer": "https://provider.example.test"], filename: "movie.mkv")
    }

    func testMovieResolutionUsesExactCatalogIdentityAndRequestHeaders() async throws {
        var requests: [String] = []
        let source = stream()
        let target = try await WatchPartySharedPlaybackResolver.resolve(
            stream: source, room: movie, isCurrent: { true },
            loadMetadata: { id, type in
                requests.append("\(type)|\(id)")
                return NuvioMeta(id: "tmdb:42", name: "Localized title", imdbId: "tt42", type: "movie")
            }
        )
        XCTAssertEqual(requests, ["movie|tt42"])
        XCTAssertEqual(target.meta.id, "tmdb:42")
        XCTAssertNil(target.episode)
        XCTAssertEqual(target.url.absoluteString, source.url)
        XCTAssertEqual(target.stream.headers, source.headers)
        XCTAssertEqual(target.stream.filename, source.filename)
    }

    func testEpisodeResolutionKeepsTheExactSpecialAndIgnoresDisplayTitle() throws {
        let episode = NuvioVideo(id: "tt55:0:2", title: "Local special", season: 0, episode: 2)
        let meta = NuvioMeta(id: "tt55", name: "Local show", type: "series", videos: [
            NuvioVideo(id: "tt55:1:1", title: "Other", season: 1, episode: 1), episode
        ])
        let room = WatchPartyMedia(type: "series", metaID: "tt55", metaType: "series",
                                  season: 0, episode: 2, title: "Host show")
        let target = try WatchPartySharedPlaybackResolver.target(meta: meta, stream: stream(room.key), room: room)
        XCTAssertEqual(target.episode?.id, episode.id)
        XCTAssertEqual(target.episode?.season, 0)
        XCTAssertEqual(target.episode?.episode, 2)
    }

    func testUnknownOrAmbiguousEpisodeDoesNotSynthesizeAPlayTarget() {
        let room = WatchPartyMedia(type: "series", metaID: "tt55", metaType: "series", season: 1, episode: 2)
        let episode = NuvioVideo(id: "tt55:1:2", title: "Episode", season: 1, episode: 2)
        for videos in [[], [episode, episode]] as [[NuvioVideo]] {
            let meta = NuvioMeta(id: "tt55", name: "Show", type: "series", videos: videos)
            XCTAssertThrowsError(try WatchPartySharedPlaybackResolver.target(
                meta: meta, stream: stream(room.key), room: room
            )) { XCTAssertEqual($0 as? WatchPartySharedPlaybackError, .missingEpisode) }
        }
    }

    func testWrongTitleAndUnsupportedMetadataAreRejected() {
        for meta in [NuvioMeta(id: "tt999", name: "Same title", type: "movie"),
                     NuvioMeta(id: "tt42", name: "Channel", type: "channel")] {
            XCTAssertThrowsError(try WatchPartySharedPlaybackResolver.target(meta: meta, stream: stream(), room: movie))
        }
        XCTAssertThrowsError(try WatchPartySharedPlaybackResolver.target(
            meta: NuvioMeta(id: "tt42", name: "Movie", type: "movie"),
            stream: stream("movie|tt999||"), room: movie
        ))
    }

    func testResponseHeadersWithCookiesAreAdaptedIntoRequestHeadersAndCookieStorage() async throws {
        var source = stream()
        source.responseHeaders = [
            "set-cookie": "session_id=secret123; Path=/; Domain=media.example.test",
            "Content-Type": "application/vnd.apple.mpegurl"
        ]
        let target = try await WatchPartySharedPlaybackResolver.resolve(
            stream: source, room: movie, isCurrent: { true },
            loadMetadata: { _, _ in
                NuvioMeta(id: "tmdb:42", name: "Movie", imdbId: "tt42", type: "movie")
            }
        )
        // Verify Cookie request header synthesized
        XCTAssertEqual(target.stream.headers["Cookie"], "session_id=secret123")
        // Verify original request headers preserved
        XCTAssertEqual(target.stream.headers["Referer"], "https://provider.example.test")
        // Verify responseHeaders cleared on adapted stream
        XCTAssertTrue(target.stream.responseHeaders.isEmpty)
        // Verify cookie storage populated for target URL
        let storageCookies = HTTPCookieStorage.shared.cookies(for: target.url) ?? []
        XCTAssertTrue(storageCookies.contains(where: { $0.name == "session_id" && $0.value == "secret123" }))
    }

    func testResponseHeadersWithoutCookiesAreSafelyAbsorbed() async throws {
        var source = stream()
        source.responseHeaders = [
            "Content-Type": "application/vnd.apple.mpegurl",
            "Access-Control-Allow-Origin": "*"
        ]
        let target = try await WatchPartySharedPlaybackResolver.resolve(
            stream: source, room: movie, isCurrent: { true },
            loadMetadata: { _, _ in
                NuvioMeta(id: "tmdb:42", name: "Movie", imdbId: "tt42", type: "movie")
            }
        )
        XCTAssertEqual(target.stream.headers["Referer"], "https://provider.example.test")
        XCTAssertNil(target.stream.headers["Cookie"])
        XCTAssertTrue(target.stream.responseHeaders.isEmpty)
    }

    func testResponseHeadersAdapterWithExistingCookieHeaderAppends() throws {
        var source = stream()
        source.headers = ["Cookie": "device_id=456", "Referer": "https://provider.example.test"]
        source.responseHeaders = ["Set-Cookie": "auth=abc; Path=/; Domain=media.example.test"]
        let url = try XCTUnwrap(URL(string: source.url))
        let adapted = WatchPartyResponseHeadersAdapter.adapt(stream: source, targetURL: url)
        XCTAssertEqual(adapted.headers["Cookie"], "device_id=456; auth=abc")
        XCTAssertEqual(adapted.headers["Referer"], "https://provider.example.test")
        XCTAssertTrue(adapted.responseHeaders.isEmpty)
    }

    func testStaleSourceBeforeLoadingDoesNotResolveMetadata() async {
        do {
            _ = try await WatchPartySharedPlaybackResolver.resolve(
                stream: stream(), room: movie, isCurrent: { false },
                loadMetadata: { _, _ in
                    XCTFail("A stale selection must not load metadata")
                    return NuvioMeta(id: "tt42", name: "Movie", type: "movie")
                }
            )
            XCTFail("Expected stale selection")
        } catch { XCTAssertEqual(error as? WatchPartySharedPlaybackError, .staleSelection) }
    }

    func testRevocationOrNavigationDuringMetadataLoadRejectsCompletion() async {
        var current = true
        do {
            _ = try await WatchPartySharedPlaybackResolver.resolve(
                stream: stream(), room: movie, isCurrent: { current },
                loadMetadata: { _, _ in
                    await Task.yield()
                    current = false
                    return NuvioMeta(id: "tt42", name: "Movie", type: "movie")
                }
            )
            XCTFail("A stale completion must not return a playable target")
        } catch { XCTAssertEqual(error as? WatchPartySharedPlaybackError, .staleSelection) }
    }

    func testCancellationDuringMetadataLoadRejectsCompletion() async {
        let source = stream(), room = movie
        let task = Task { @MainActor in
            try await WatchPartySharedPlaybackResolver.resolve(
                stream: source, room: room, isCurrent: { true },
                loadMetadata: { _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return NuvioMeta(id: "tt42", name: "Movie", type: "movie")
                }
            )
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

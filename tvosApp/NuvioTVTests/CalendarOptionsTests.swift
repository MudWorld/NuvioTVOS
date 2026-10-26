import XCTest
@testable import NuvioTV

// Filter, spoilers, availability and TVmaze air times in the calendar.

private func day(_ d: Int, _ m: Int = 10, _ y: Int = 2026) -> CalendarDay {
    CalendarDay(year: y, month: m, day: d)
}

private func episode(_ show: Int, s: Int = 1, e: Int, on date: CalendarDay, anime: Bool = false,
                     kind release: CalendarReleaseKind = .episode, item: String? = nil) -> CalendarEntry {
    var entry = CalendarEntry(itemId: item ?? "tt\(show)", itemType: "series", kind: .series, tmdbId: show,
                              title: "Show \(show)", date: date, releaseKind: release,
                              seasonNumber: s, episodeNumber: e, episodeName: "Name \(e)")
    entry.isAnime = anime
    return entry
}

private func movie(_ id: Int, on date: CalendarDay, _ release: CalendarReleaseKind = .digital) -> CalendarEntry {
    CalendarEntry(itemId: "tt\(id)", kind: .movie, tmdbId: id, title: "Movie \(id)", date: date, releaseKind: release)
}

// MARK: - Filter

final class CalendarFilterTests: XCTestCase {
    private let entries = [
        episode(1, e: 4, on: day(20)),
        episode(2, s: 3, e: 1, on: day(20), kind: .seasonPremiere),
        episode(3, e: 9, on: day(21), anime: true),
        movie(4, on: day(22)),
    ]

    private var result: CalendarResult {
        CalendarResult(firstDay: day(1), lastDay: day(31), days: CalendarBuilder.groupByDay(entries), skipped: [])
    }

    func testEachFilterKeepsItsEntriesAndDropsEmptyDays() {
        XCTAssertEqual(result.filtered(.all).entryCount, 4)
        XCTAssertEqual(result.filtered(.premieres).allEntries.map(\.tmdbId), [2])
        XCTAssertEqual(Set(result.filtered(.series).allEntries.map(\.tmdbId)), [1, 2])
        XCTAssertEqual(result.filtered(.anime).allEntries.map(\.tmdbId), [3])
        XCTAssertEqual(result.filtered(.movies).allEntries.map(\.tmdbId), [4])
        XCTAssertEqual(result.filtered(.movies).days.map(\.date), [day(22)])
    }

    func testFinalesCountAsPremieres() {
        XCTAssertTrue(CalendarFilter.premieres.includes(episode(1, e: 10, on: day(20), kind: .seasonFinale)))
        XCTAssertTrue(CalendarFilter.premieres.includes(episode(1, e: 1, on: day(20), kind: .seriesPremiere)))
        XCTAssertFalse(CalendarFilter.premieres.includes(movie(5, on: day(20), .theatrical)))
    }

    func testCalendarSettingsAreSyncedAndResetWithTheOthers() {
        for key in [SettingsKey.showCalendarTab, SettingsKey.calendarFilter, SettingsKey.calendarHideSpoilers,
                    SettingsKey.calendarCheckAvailability, SettingsKey.calendarTvmazeTimes] {
            XCTAssertTrue(SettingsKey.all.contains(key), key)
        }
    }

    func testUnknownStoredValueShowsEverything() {
        XCTAssertEqual(CalendarFilter(stored: "nonsense"), .all)
        XCTAssertEqual(CalendarFilter(stored: "anime"), .anime)
    }
}

// MARK: - Rules

final class CalendarEntryRulesTests: XCTestCase {
    func testReleasedUsesTheTimeOnlyOnTheDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = CalendarDay(date: now)
        XCTAssertTrue(CalendarEntryRules.isReleased(episode(1, e: 1, on: today.adding(days: -1)), today: today, now: now))
        XCTAssertFalse(CalendarEntryRules.isReleased(episode(1, e: 1, on: today.adding(days: 1)), today: today, now: now))
        XCTAssertTrue(CalendarEntryRules.isReleased(episode(1, e: 1, on: today), today: today, now: now))

        var later = episode(1, e: 2, on: today)
        later.airTime = now.addingTimeInterval(3600)
        XCTAssertFalse(CalendarEntryRules.isReleased(later, today: today, now: now))
        later.airTime = now.addingTimeInterval(-60)
        XCTAssertTrue(CalendarEntryRules.isReleased(later, today: today, now: now))
    }

    func testCinemaReleasesAreNotChecked() {
        let now = Date()
        let today = CalendarDay(date: now)
        XCTAssertFalse(CalendarEntryRules.checksAvailability(movie(1, on: today.adding(days: -3), .theatrical), today: today, now: now))
        XCTAssertTrue(CalendarEntryRules.checksAvailability(movie(1, on: today.adding(days: -3), .digital), today: today, now: now))
    }

    func testSpoilersStayHiddenUntilKnownWatched() {
        let entry = episode(1, e: 5, on: day(20))
        XCTAssertFalse(CalendarEntryRules.hidesSpoilers(entry, hideSpoilers: false, watched: nil))
        XCTAssertTrue(CalendarEntryRules.hidesSpoilers(entry, hideSpoilers: true, watched: nil))
        XCTAssertTrue(CalendarEntryRules.hidesSpoilers(entry, hideSpoilers: true, watched: false))
        XCTAssertFalse(CalendarEntryRules.hidesSpoilers(entry, hideSpoilers: true, watched: true))
        XCTAssertFalse(CalendarEntryRules.hidesSpoilers(movie(2, on: day(20)), hideSpoilers: true, watched: nil))
        XCTAssertEqual(CalendarFormat.spoilerFreeSubtitle(entry), "Episode 5")
    }

    func testBatches() {
        XCTAssertEqual(CalendarEntryRules.batches([1, 2, 3, 4, 5], size: 2), [[1, 2], [3, 4], [5]])
        XCTAssertEqual(CalendarEntryRules.batches([Int](), size: 2), [])
    }
}

// MARK: - Watched and availability

@MainActor
private final class ProbeLog {
    var asked: [String] = []
}

/// Holds the add-on's answer back until the test lets it through.
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume()
    }
}

@MainActor
final class CalendarEntryStatusModelTests: XCTestCase {
    func testWatchedUsesTheAddonsEpisode() async {
        // TMDB's S2E3 is S17E3 on the add-on (found by its date).
        let meta = NuvioMeta(id: "tt1", name: "Show", type: "series", videos: [
            NuvioVideo(id: "tt1:2:3", title: "Old", season: 2, episode: 3, released: "2005-03-01T00:00:00.000Z"),
            NuvioVideo(id: "tt1:17:3", title: "New", season: 17, episode: 3, released: "2026-10-19T15:00:00.000Z"),
        ])
        let model = CalendarEntryStatusModel(
            loadMeta: { _, _ in meta },
            probe: { _, _ in false },
            isWatched: { _, _, video in video?.id == "tt1:17:3" },
            availabilityDelay: .zero
        )
        let entry = episode(1, s: 2, e: 3, on: day(19))
        model.updateWatched(for: [entry])
        XCTAssertNil(model.watched[entry.id], "unknown until the episode list has loaded")
        await model.settle()
        XCTAssertEqual(model.watched[entry.id], true)
    }

    func testMoviesNeedNoMetadata() async {
        let model = CalendarEntryStatusModel(
            loadMeta: { _, _ in XCTFail("movies are looked up by id"); return nil },
            probe: { _, _ in false },
            isWatched: { entry, meta, _ in meta == nil && entry.itemId == "tt7" },
            availabilityDelay: .zero
        )
        let film = movie(7, on: day(20))
        model.updateWatched(for: [film])
        XCTAssertEqual(model.watched[film.id], true)
    }

    func testAvailabilityAsksOnlyReleasedEntriesAndRemembersTheAnswer() async {
        let meta = NuvioMeta(id: "tt1", name: "Show", type: "series", videos: [
            NuvioVideo(id: "tt1:1:1", title: "E1", season: 1, episode: 1, released: "2026-10-20T00:00:00.000Z"),
        ])
        let log = ProbeLog()
        let model = CalendarEntryStatusModel(
            loadMeta: { id, _ in id == "tt1" ? meta : nil },
            probe: { type, id in
                log.asked.append("\(type)|\(id)")
                return id == "tt1:1:1"
            },
            isWatched: { _, _, _ in false },
            availabilityDelay: .zero
        )
        let today = day(22)
        let aired = episode(1, e: 1, on: day(20))
        let upcoming = episode(1, e: 2, on: day(25))
        let inCinemas = movie(9, on: day(21), .theatrical)
        let digital = movie(8, on: day(21), .digital)

        model.checkAvailability(for: [aired, upcoming, inCinemas, digital], today: today)
        await model.settle()
        XCTAssertEqual(Set(log.asked), ["series|tt1:1:1", "movie|tt8"])
        XCTAssertEqual(model.availability[aired.id], .available)
        XCTAssertEqual(model.availability[digital.id], .unavailable)
        XCTAssertNil(model.availability[upcoming.id])
        XCTAssertNil(model.availability[inCinemas.id])

        model.checkAvailability(for: [aired, digital], today: today)
        await model.settle()
        XCTAssertEqual(log.asked.count, 2, "answers are kept for ten minutes")
    }

    func testMovingOnClearsUnfinishedChecks() async {
        // The add-on answers only when the test says so, so the check is
        // still running when the cursor moves on.
        let gate = ProbeGate()
        let model = CalendarEntryStatusModel(
            loadMeta: { _, _ in nil },
            probe: { _, _ in
                await gate.wait()
                return true
            },
            isWatched: { _, _, _ in false },
            availabilityDelay: .zero
        )
        let digital = movie(8, on: day(21))
        model.checkAvailability(for: [digital], today: day(22))
        var spins = 0
        while model.availability[digital.id] != .checking, spins < 1_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(model.availability[digital.id], .checking)
        model.cancelAvailability()
        XCTAssertNil(model.availability[digital.id])
        gate.open()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertNil(model.availability[digital.id], "a cancelled check doesn't write its answer")
    }

    func testTurningTheOptionOffForgetsAnswers() async {
        let model = CalendarEntryStatusModel(
            loadMeta: { _, _ in nil },
            probe: { _, _ in true },
            isWatched: { _, _, _ in false },
            availabilityDelay: .zero
        )
        let digital = movie(8, on: day(21))
        model.checkAvailability(for: [digital], today: day(22))
        await model.settle()
        XCTAssertEqual(model.availability[digital.id], .available)
        model.clearAvailability()
        XCTAssertNil(model.availability[digital.id])
    }

    func testStreamIdsAreTheOnesDetailsAsksFor() {
        // TMDB-enriched episode ids go back to the IMDb-based id.
        let meta = NuvioMeta(id: "tmdb:5", name: "Show", imdbId: "tt9", type: "series", videos: [
            NuvioVideo(id: "tmdb:5:1:2", title: "E2", season: 1, episode: 2),
        ])
        let entry = episode(5, e: 2, on: day(20), item: "tmdb:5")
        XCTAssertEqual(CalendarEntryRules.streamId(for: entry, meta: meta, video: meta.videos?.first), "tt9:1:2")
        XCTAssertNil(CalendarEntryRules.streamId(for: entry, meta: nil, video: nil))

        var film = movie(7, on: day(20))
        XCTAssertEqual(CalendarEntryRules.streamId(for: film, meta: nil, video: nil), "tt7")
        film = CalendarEntry(itemId: "tmdb:7", kind: .movie, tmdbId: 7, title: "Movie", date: day(20), releaseKind: .digital)
        XCTAssertEqual(CalendarEntryRules.streamId(for: film, meta: nil, video: nil), "tmdb:7")
        let filmMeta = NuvioMeta(id: "tmdb:7", name: "Movie", imdbId: "tt7", type: "movie")
        XCTAssertEqual(CalendarEntryRules.streamId(for: film, meta: filmMeta, video: nil), "tt7")
    }

    func testOptionsAreReadFromTheGivenStore() {
        let suite = "calendar-options-tests"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertTrue(CalendarOptions.tvmazeTimes(in: store))
        store.set(false, forKey: SettingsKey.calendarTvmazeTimes)
        XCTAssertFalse(CalendarOptions.tvmazeTimes(in: store))
    }
}

// MARK: - TVmaze

private final class TvmazeMockHTTP: CalendarAnimeHTTPClient, @unchecked Sendable {
    /// "path?query" → (body, status, location).
    let routes: [String: (String, Int, String?)]
    private let lock = NSLock()
    private var log: [String] = []

    init(_ routes: [String: (String, Int, String?)]) {
        self.routes = routes
    }

    var requests: [String] { lock.withLock { log } }

    func post(_ url: URL, json: Data) async throws -> (Data, Int) {
        XCTFail("TVmaze is only read")
        return (Data(), 500)
    }

    func getWithoutRedirect(_ url: URL, headers: [String: String]) async throws -> (Data, Int, String?) {
        let key = url.path + (url.query.map { "?\($0)" } ?? "")
        lock.withLock { log.append(key) }
        guard let route = routes[key] else { return (Data(), 404, nil) }
        return (Data(route.0.utf8), route.1, route.2)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class CalendarTvmazeTimesTests: XCTestCase {
    private let prague = TimeZone(identifier: "Europe/Prague")!

    private func stamp(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    private let episodesJSON = """
    [
      {"season":1,"number":5,"airdate":"2026-10-22","airtime":"21:00","airstamp":"2026-10-23T01:00:00+00:00"},
      {"season":1,"number":6,"airdate":"2026-10-22","airtime":"","airstamp":"2026-10-22T12:00:00+00:00"},
      {"season":1,"number":7,"airdate":"2027-03-01","airtime":"21:00","airstamp":"2027-03-02T02:00:00+00:00"},
      {"season":1,"number":null,"airdate":"2026-10-22","airtime":"22:00","airstamp":"2026-10-23T02:00:00+00:00"}
    ]
    """

    func testEveningUSEpisodeMovesToTheNextLocalDay() {
        // Thursday 21:00 in New York is Friday 03:00 in Prague.
        let airing = CalendarTvmazeTimes.Airing(season: 1, number: 5, airdate: "2026-10-22", at: stamp("2026-10-23T01:00:00Z"))
        let out = CalendarTvmazeTimes.match([episode(1, e: 5, on: day(22))], airings: [1: [airing]], timeZone: prague)
        XCTAssertEqual(out[0].date, day(23))
        XCTAssertEqual(out[0].airTime, airing.at)
        XCTAssertEqual(out[0].airTimeSource, .tvmaze)
    }

    func testAnimeMoviesAndTimedEntriesAreLeftAlone() {
        let airing = CalendarTvmazeTimes.Airing(season: 1, number: 5, airdate: "2026-10-22", at: stamp("2026-10-23T01:00:00Z"))
        var timed = episode(1, e: 5, on: day(22))
        timed.airTime = stamp("2026-10-22T15:00:00Z")
        let entries = [episode(1, e: 5, on: day(22), anime: true), timed, movie(1, on: day(22))]
        let out = CalendarTvmazeTimes.match(entries, airings: [1: [airing]], timeZone: prague)
        XCTAssertEqual(out, entries)
    }

    func testWithoutAMatchingNumberOnlyASingleAiringThatDayIsUsed() {
        // TMDB's S2E1 is TVmaze's S1E14.
        let single = [CalendarTvmazeTimes.Airing(season: 1, number: 14, airdate: "2026-10-22", at: stamp("2026-10-23T01:00:00Z"))]
        let moved = CalendarTvmazeTimes.match([episode(1, s: 2, e: 1, on: day(22))], airings: [1: single], timeZone: prague)
        XCTAssertEqual(moved[0].date, day(23))

        let two = single + [CalendarTvmazeTimes.Airing(season: 1, number: 15, airdate: "2026-10-22", at: stamp("2026-10-23T02:00:00Z"))]
        let kept = CalendarTvmazeTimes.match([episode(1, s: 2, e: 1, on: day(22))], airings: [1: two], timeZone: prague)
        XCTAssertEqual(kept[0].date, day(22))
        XCTAssertNil(kept[0].airTime)
    }

    func testSameNumberFarFromTheDateIsNotUsed() {
        let rerun = CalendarTvmazeTimes.Airing(season: 1, number: 5, airdate: "2026-10-10", at: stamp("2026-10-11T01:00:00Z"))
        let out = CalendarTvmazeTimes.match([episode(1, e: 5, on: day(22))], airings: [1: [rerun]], timeZone: prague)
        XCTAssertEqual(out[0].date, day(22))
        XCTAssertNil(out[0].airTime)
    }

    func testParseKeepsNumberedEpisodesInTheWindowWithTimesWhenSet() {
        let airings = CalendarTvmazeTimes.parseEpisodes(Data(episodesJSON.utf8), first: day(1), last: day(31))
        XCTAssertEqual(airings, [
            CalendarTvmazeTimes.Airing(season: 1, number: 5, airdate: "2026-10-22", at: stamp("2026-10-23T01:00:00Z")),
            CalendarTvmazeTimes.Airing(season: 1, number: 6, airdate: "2026-10-22", at: nil),
        ])
    }

    func testDoubleEpisodeListedOnceKeepsBothOnTheirDay() {
        // TMDB has S2E1 and S2E2 that day; TVmaze one airing under other numbers.
        let one = [CalendarTvmazeTimes.Airing(season: 1, number: 20, airdate: "2026-10-22", at: stamp("2026-10-23T01:00:00Z"))]
        let out = CalendarTvmazeTimes.match([episode(1, s: 2, e: 1, on: day(22)), episode(1, s: 2, e: 2, on: day(22))],
                                            airings: [1: one], timeZone: prague)
        XCTAssertEqual(out.map(\.date), [day(22), day(22)])
        XCTAssertEqual(out.compactMap(\.airTime), [])
    }

    func testUntimedEpisodesCountWhenMatchingByDate() {
        let airings = [
            CalendarTvmazeTimes.Airing(season: 1, number: 14, airdate: "2026-10-22", at: stamp("2026-10-23T01:00:00Z")),
            CalendarTvmazeTimes.Airing(season: 1, number: 15, airdate: "2026-10-22", at: nil),
        ]
        let out = CalendarTvmazeTimes.match([episode(1, s: 2, e: 1, on: day(22))], airings: [1: airings], timeZone: prague)
        XCTAssertEqual(out[0].date, day(22))
        XCTAssertNil(out[0].airTime)
    }

    func testUntimedNumberedMatchKeepsTheDate() {
        let untimed = [CalendarTvmazeTimes.Airing(season: 1, number: 5, airdate: "2026-10-22", at: nil)]
        let out = CalendarTvmazeTimes.match([episode(1, e: 5, on: day(22))], airings: [1: untimed], timeZone: prague)
        XCTAssertEqual(out[0].date, day(22))
        XCTAssertNil(out[0].airTime)
    }

    func testLookupAnswers() {
        XCTAssertEqual(CalendarTvmazeTimes.lookupResult(status: 301, body: Data(), location: "https://api.tvmaze.com/shows/82"), .found(82))
        XCTAssertEqual(CalendarTvmazeTimes.lookupResult(status: 200, body: Data(#"{"id":5,"name":"X"}"#.utf8), location: nil), .found(5))
        XCTAssertEqual(CalendarTvmazeTimes.lookupResult(status: 404, body: Data(), location: nil), .missing)
        XCTAssertEqual(CalendarTvmazeTimes.lookupResult(status: 500, body: Data(), location: nil), .failed)
        XCTAssertEqual(CalendarTvmazeTimes.lookupResult(status: 301, body: Data(), location: nil), .failed)
        XCTAssertEqual(CalendarTvmazeTimes.showId(fromLocation: "/shows/7"), 7)
        XCTAssertNil(CalendarTvmazeTimes.showId(fromLocation: "https://api.tvmaze.com/people/7"))
    }

    func testApplyFindsTheShowByTvdbAfterImdbAndCachesBoth() async {
        let http = TvmazeMockHTTP([
            "/lookup/shows?imdb=tt100": ("", 404, nil),
            "/lookup/shows?thetvdb=555": ("", 301, "https://api.tvmaze.com/shows/77"),
            "/shows/77/episodes": (episodesJSON, 200, nil),
        ])
        let times = CalendarTvmazeTimes(http: http, timeZone: prague,
                                        cache: CalendarTvmazeCache(fileURL: nil),
                                        limiter: CalendarTvmazeRateLimiter(interval: 0))
        let entries = [episode(1, e: 5, on: day(22))]

        let first = await times.apply(to: entries, ids: [1: .init(imdb: "tt100")],
                                      externalIds: { _ in .init(imdb: "tt100", tvdb: 555) },
                                      first: day(1), last: day(31))
        XCTAssertEqual(first[0].date, day(23))
        XCTAssertEqual(http.requests, ["/lookup/shows?imdb=tt100", "/lookup/shows?thetvdb=555", "/shows/77/episodes"])

        let second = await times.apply(to: entries, ids: [1: .init(imdb: "tt100")],
                                       externalIds: { _ in XCTFail("cached"); return nil },
                                       first: day(1), last: day(31))
        XCTAssertEqual(second[0].date, day(23))
        XCTAssertEqual(http.requests.count, 3, "the show and its times come from the cache")
    }

    func testTmdbsOwnImdbIdIsTriedWhenTheLibrarysIsNotFound() async {
        let http = TvmazeMockHTTP([
            "/lookup/shows?imdb=tt100": ("", 404, nil),
            "/lookup/shows?imdb=tt200": ("", 301, "https://api.tvmaze.com/shows/12"),
        ])
        let times = CalendarTvmazeTimes(http: http, timeZone: prague, cache: CalendarTvmazeCache(fileURL: nil),
                                        limiter: CalendarTvmazeRateLimiter(interval: 0))
        let id = await times.showId(tmdbId: 1, known: .init(imdb: "tt100"), externalIds: { _ in .init(imdb: "tt200") })
        XCTAssertEqual(id, 12)
        XCTAssertEqual(http.requests, ["/lookup/shows?imdb=tt100", "/lookup/shows?imdb=tt200"])
    }

    func testCancelledLoadSendsNothing() async {
        let http = TvmazeMockHTTP([:])
        let times = CalendarTvmazeTimes(http: http, timeZone: prague, cache: CalendarTvmazeCache(fileURL: nil),
                                        limiter: CalendarTvmazeRateLimiter(interval: 0))
        let entries = [episode(1, e: 5, on: day(22)), episode(2, e: 1, on: day(22)), episode(3, e: 1, on: day(23))]
        let out = await Task { () -> [CalendarEntry] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await times.apply(to: entries, ids: [1: .init(imdb: "tt100")],
                                     externalIds: { _ in .init(tvdb: 5) }, first: day(1), last: day(31))
        }.value
        XCTAssertEqual(out, entries)
        XCTAssertEqual(http.requests, [])
    }

    func testCancelledCallerTakesNoRateLimitSlot() async {
        let limiter = CalendarTvmazeRateLimiter(interval: 30)
        await limiter.wait()
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await limiter.wait()
        }.value
        let delay = await limiter.pendingDelay()
        XCTAssertLessThanOrEqual(delay, 30)
        XCTAssertGreaterThan(delay, 25)
    }

    func testUnreachableTmdbDoesNotMarkTheShowMissing() async {
        let http = TvmazeMockHTTP([:])
        let cache = CalendarTvmazeCache(fileURL: nil)
        let times = CalendarTvmazeTimes(http: http, timeZone: prague, cache: cache,
                                        limiter: CalendarTvmazeRateLimiter(interval: 0))
        let id = await times.showId(tmdbId: 1, known: .init(), externalIds: { _ in nil })
        XCTAssertNil(id)
        let lookup = await cache.show(1)
        XCTAssertEqual(lookup, .unknown)
    }

    func testCacheForgetsMissingShowsAfterAWeekAndTimesAfterTwelveHours() async {
        let clock = TestClock()
        let cache = CalendarTvmazeCache(fileURL: nil, now: { clock.now })
        await cache.setShow(1, tvmazeId: nil)
        await cache.setShow(2, tvmazeId: 9)
        let airing = CalendarTvmazeTimes.Airing(season: 1, number: 1, airdate: "2026-10-10", at: Date())
        await cache.setAirings(9, [airing], first: day(1), last: day(31))

        var missing = await cache.show(1)
        XCTAssertEqual(missing, .missing)
        var narrower = await cache.airings(9, first: day(5), last: day(20))
        XCTAssertEqual(narrower, [airing])
        let wider = await cache.airings(9, first: day(1, 9), last: day(31))
        XCTAssertNil(wider, "a longer period than cached is fetched again")

        clock.advance(13 * 3600)
        narrower = await cache.airings(9, first: day(5), last: day(20))
        XCTAssertNil(narrower)

        clock.advance(7 * 24 * 3600)
        missing = await cache.show(1)
        XCTAssertEqual(missing, .unknown)
        let found = await cache.show(2)
        XCTAssertEqual(found, .found(9))
    }

    func testClearingForgetsEverythingAndRemovesTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tvmaze-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = CalendarTvmazeCache(fileURL: url)
        await cache.setShow(2, tvmazeId: 9)
        await cache.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let lookup = await cache.show(2)
        XCTAssertEqual(lookup, .unknown)
        let reopened = await CalendarTvmazeCache(fileURL: url).show(2)
        XCTAssertEqual(reopened, .unknown)
    }
}

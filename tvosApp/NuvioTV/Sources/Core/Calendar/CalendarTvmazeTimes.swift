import Foundation

/// Moves episodes of regular series onto the local day they air and adds the
/// broadcast time, from TVmaze. TMDB only has the date in the show's own
/// country, so an evening US episode lands a day early in Europe.
///
/// Anime keeps AniList's times and movies have no broadcast time. A show is
/// found by the library's IMDb id, else by TMDB's IMDb and TheTVDB ids.
/// Episodes are matched by season and number, else by being the only one on
/// TMDB's date. Anything without a match, or without a set broadcast time on
/// TVmaze (streaming drops), keeps its TMDB date. TVmaze data is CC BY-SA 4.0
/// and credited where it's shown.
struct CalendarTvmazeTimes: Sendable {
    typealias Progress = @Sendable ([CalendarEntry]) async -> Void

    let http: CalendarAnimeHTTPClient
    var timeZone: TimeZone
    var cache: CalendarTvmazeCache
    var limiter: CalendarTvmazeRateLimiter

    static let baseURL = URL(string: "https://api.tvmaze.com")!
    static let maxConcurrent = 2
    /// Days kept on both sides of the calendar period in the episode cache.
    static let windowMargin = 7
    /// Times found so far are shown after this many shows.
    static let progressEvery = 8

    init(http: CalendarAnimeHTTPClient = CalendarAnimeURLSessionClient(),
         timeZone: TimeZone = .current,
         cache: CalendarTvmazeCache = .shared,
         limiter: CalendarTvmazeRateLimiter = .shared) {
        self.http = http
        self.timeZone = timeZone
        self.cache = cache
        self.limiter = limiter
    }

    struct ShowIds: Hashable, Sendable {
        var imdb: String?
        var tvdb: Int?

        init(imdb: String? = nil, tvdb: Int? = nil) {
            self.imdb = imdb
            self.tvdb = tvdb
        }
    }

    struct Airing: Codable, Hashable, Sendable {
        let season: Int
        let number: Int
        /// The date in the show's own country ("2026-10-22"), as TMDB has it.
        let airdate: String
        /// nil when TVmaze has no set time (streaming drops); such an episode
        /// is still counted when matching by date, but gets no time.
        let at: Date?
    }

    /// Series that can get a time: not anime and not timed already.
    static func isEligible(_ entry: CalendarEntry) -> Bool {
        entry.kind == .series && !entry.isAnime && entry.airTime == nil
            && entry.seasonNumber != nil && entry.episodeNumber != nil
    }

    /// - Parameters:
    ///   - ids: the ids already known per TMDB show (the library's IMDb ids).
    ///   - externalIds: TMDB's external ids of a show, asked for only when
    ///     the known ids don't find it.
    ///   - progress: receives the entries with the times found so far, every
    ///     few shows, so a long first run shows times as they come.
    func apply(
        to entries: [CalendarEntry],
        ids: [Int: ShowIds],
        externalIds: @escaping @Sendable (Int) async -> ShowIds?,
        first: CalendarDay,
        last: CalendarDay,
        progress: Progress? = nil
    ) async -> [CalendarEntry] {
        let shows = Array(Set(entries.filter(Self.isEligible).map(\.tmdbId))).sorted()
        guard !shows.isEmpty else { return entries }
        let windowFirst = first.adding(days: -Self.windowMargin)
        let windowLast = last.adding(days: Self.windowMargin)
        let zone = self.timeZone

        @Sendable func load(_ show: Int) async -> (Int, [Airing]) {
            guard let tvmazeId = await showId(tmdbId: show, known: ids[show] ?? ShowIds(), externalIds: externalIds) else {
                return (show, [])
            }
            return (show, await airings(tvmazeId: tvmazeId, first: windowFirst, last: windowLast))
        }

        var byShow: [Int: [Airing]] = [:]
        await withTaskGroup(of: (Int, [Airing]).self) { group in
            var index = 0
            var finished = 0
            while index < min(Self.maxConcurrent, shows.count) {
                let show = shows[index]
                group.addTask { await load(show) }
                index += 1
            }
            while let result = await group.next() {
                finished += 1
                if !result.1.isEmpty { byShow[result.0] = result.1 }
                // A newer load took over: don't start the rest.
                if index < shows.count, !Task.isCancelled {
                    let show = shows[index]
                    group.addTask { await load(show) }
                    index += 1
                }
                if let progress, finished % Self.progressEvery == 0, finished < shows.count, !Task.isCancelled {
                    await progress(Self.match(entries, airings: byShow, timeZone: zone))
                }
            }
        }
        await cache.flush()
        guard !byShow.isEmpty else { return entries }
        return Self.match(entries, airings: byShow, timeZone: zone)
    }

    /// Takes the TVmaze airing with the same season and number within a day
    /// of TMDB's date. Failing that, an episode alone on its date for the
    /// show gets the date's airing when that is alone too; otherwise (a
    /// double episode TVmaze lists once, say) the entries keep TMDB's date,
    /// so they don't end up split over two days.
    static func match(_ entries: [CalendarEntry], airings: [Int: [Airing]], timeZone: TimeZone) -> [CalendarEntry] {
        var used = Set<Airing>()
        var result = entries
        // Numbered matches first, so a date-only match can't take their airing.
        let eligible = result.indices.filter { isEligible(result[$0]) && airings[result[$0].tmdbId] != nil }
        var unmatched: [Int] = []
        for index in eligible {
            let entry = result[index]
            let numbered = airings[entry.tmdbId]?.first { airing in
                guard !used.contains(airing),
                      airing.season == entry.seasonNumber, airing.number == entry.episodeNumber,
                      let day = CalendarDay(iso: airing.airdate) else { return false }
                return abs(day.days(until: entry.date)) <= 1
            }
            if let numbered {
                used.insert(numbered)
                place(&result[index], at: numbered, timeZone: timeZone)
            } else {
                unmatched.append(index)
            }
        }
        var unmatchedOnDay: [String: Int] = [:]
        for index in unmatched {
            unmatchedOnDay["\(result[index].tmdbId)|\(result[index].date.iso)", default: 0] += 1
        }
        for index in unmatched {
            let entry = result[index]
            guard unmatchedOnDay["\(entry.tmdbId)|\(entry.date.iso)"] == 1 else { continue }
            let sameDay = (airings[entry.tmdbId] ?? []).filter { $0.airdate == entry.date.iso && !used.contains($0) }
            guard sameDay.count == 1, let only = sameDay.first else { continue }
            used.insert(only)
            place(&result[index], at: only, timeZone: timeZone)
        }
        return result
    }

    private static func place(_ entry: inout CalendarEntry, at airing: Airing, timeZone: TimeZone) {
        guard let at = airing.at else { return }
        entry.date = CalendarDay(date: at, timeZone: timeZone)
        entry.airTime = at
        entry.airTimeSource = .tvmaze
    }

    // MARK: - Shows

    /// The TVmaze id of a TMDB show: the library's IMDb id first, then the
    /// IMDb and TheTVDB ids TMDB has. A show none of them finds is
    /// remembered as missing; a failed request is tried again next load.
    func showId(tmdbId: Int, known: ShowIds, externalIds: @Sendable (Int) async -> ShowIds?) async -> Int? {
        switch await cache.show(tmdbId) {
        case .found(let id): return id
        case .missing: return nil
        case .unknown: break
        }

        func lookups(_ ids: ShowIds) -> [(String, String)] {
            var list: [(String, String)] = []
            if let imdb = ids.imdb { list.append(("imdb", imdb)) }
            if let tvdb = ids.tvdb { list.append(("thetvdb", String(tvdb))) }
            return list
        }

        var queue = lookups(known)
        var tried = Set<String>()
        var askedTmdb = false
        var failed = false
        while !Task.isCancelled {
            if queue.isEmpty {
                guard !askedTmdb else { break }
                askedTmdb = true
                guard let external = await externalIds(tmdbId) else {
                    failed = true
                    break
                }
                queue = lookups(external)
                continue
            }
            let (key, value) = queue.removeFirst()
            guard tried.insert("\(key)=\(value)").inserted else { continue }
            switch await lookup(key, value) {
            case .found(let id):
                await cache.setShow(tmdbId, tvmazeId: id)
                return id
            case .missing:
                break
            case .failed:
                failed = true
            }
        }
        if !failed, !Task.isCancelled { await cache.setShow(tmdbId, tvmazeId: nil) }
        return nil
    }

    enum LookupResult: Equatable {
        case found(Int)
        case missing
        case failed
    }

    func lookup(_ key: String, _ value: String) async -> LookupResult {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("lookup/shows"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: key, value: value)]
        guard let url = components.url, let response = await get(url) else { return .failed }
        return Self.lookupResult(status: response.1, body: response.0, location: response.2)
    }

    /// TVmaze answers a found show with a redirect to it; a client that
    /// followed the redirect gets the show itself.
    static func lookupResult(status: Int, body: Data, location: String?) -> LookupResult {
        switch status {
        case 301, 302, 303, 307, 308:
            guard let location, let id = showId(fromLocation: location) else { return .failed }
            return .found(id)
        case 200:
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            guard let id = object?["id"] as? Int else { return .failed }
            return .found(id)
        case 404:
            return .missing
        default:
            return .failed
        }
    }

    /// "https://api.tvmaze.com/shows/82" → 82.
    static func showId(fromLocation location: String) -> Int? {
        guard let path = URL(string: location)?.path else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[parts.count - 2] == "shows" else { return nil }
        return Int(parts[parts.count - 1])
    }

    // MARK: - Episodes

    func airings(tvmazeId: Int, first: CalendarDay, last: CalendarDay) async -> [Airing] {
        if let cached = await cache.airings(tvmazeId, first: first, last: last) { return cached }
        let url = Self.baseURL.appendingPathComponent("shows/\(tvmazeId)/episodes")
        guard let response = await get(url), response.1 == 200 else { return [] }
        let found = Self.parseEpisodes(response.0, first: first, last: last)
        await cache.setAirings(tvmazeId, found, first: first, last: last)
        return found
    }

    /// Numbered episodes inside the window; the time only when TVmaze has
    /// a set broadcast time.
    static func parseEpisodes(_ data: Data, first: CalendarDay, last: CalendarDay) -> [Airing] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return list.compactMap { episode in
            guard let season = episode["season"] as? Int,
                  let number = episode["number"] as? Int,
                  let airdate = episode["airdate"] as? String,
                  let day = CalendarDay(iso: airdate), day >= first, day <= last else { return nil }
            let airtime = (episode["airtime"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let at = airtime.isEmpty ? nil : (episode["airstamp"] as? String).flatMap(formatter.date(from:))
            return Airing(season: season, number: number, airdate: day.iso, at: at)
        }
    }

    // MARK: - HTTP

    /// One GET within TVmaze's rate limit; a 429 waits and retries once.
    /// Nothing is sent for a cancelled load.
    private func get(_ url: URL) async -> (Data, Int, String?)? {
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return nil }
            await limiter.wait()
            guard !Task.isCancelled else { return nil }
            guard let response = try? await http.getWithoutRedirect(url, headers: ["Accept": "application/json"]) else {
                return nil
            }
            if response.1 == 429, attempt == 0 {
                await limiter.pause(seconds: 10)
                continue
            }
            return response
        }
        return nil
    }
}

/// Spaces TVmaze requests out: it allows at least 20 every 10 seconds.
actor CalendarTvmazeRateLimiter {
    static let shared = CalendarTvmazeRateLimiter()

    private let interval: TimeInterval
    private var nextSlot = Date.distantPast

    init(interval: TimeInterval = 0.5) {
        self.interval = interval
    }

    /// Waits for the next free slot. A cancelled caller takes no slot.
    func wait() async {
        guard !Task.isCancelled else { return }
        let now = Date()
        let start = max(now, nextSlot)
        nextSlot = start.addingTimeInterval(interval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }

    func pause(seconds: TimeInterval) {
        nextSlot = max(nextSlot, Date().addingTimeInterval(seconds))
    }

    /// How long the next caller would wait (tests).
    func pendingDelay() -> TimeInterval {
        max(0, nextSlot.timeIntervalSinceNow)
    }
}

/// TVmaze ids (kept; a show TVmaze doesn't have is asked again after a week)
/// and episode times (12 hours), on disk so the next calendar load needs few
/// requests.
actor CalendarTvmazeCache {
    static let shared = CalendarTvmazeCache(fileURL: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("calendar-tvmaze-v1.json"))

    static let missingRetry: TimeInterval = 7 * 24 * 3600
    static let airingsLifetime: TimeInterval = 12 * 3600

    enum ShowLookup: Equatable {
        case found(Int)
        case missing
        case unknown
    }

    struct ShowRecord: Codable {
        var tvmazeId: Int?
        var checkedAt: Date
    }

    struct AiringsRecord: Codable {
        var fetchedAt: Date
        var first: CalendarDay
        var last: CalendarDay
        var airings: [CalendarTvmazeTimes.Airing]
    }

    private struct Store: Codable {
        var shows: [String: ShowRecord] = [:]
        var airings: [String: AiringsRecord] = [:]
    }

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var store = Store()
    private var loaded = false
    private var dirty = false

    /// `fileURL` nil keeps everything in memory (tests).
    init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
    }

    func show(_ tmdbId: Int) -> ShowLookup {
        loadIfNeeded()
        guard let record = store.shows[String(tmdbId)] else { return .unknown }
        if let id = record.tvmazeId { return .found(id) }
        return now().timeIntervalSince(record.checkedAt) < Self.missingRetry ? .missing : .unknown
    }

    func setShow(_ tmdbId: Int, tvmazeId: Int?) {
        loadIfNeeded()
        store.shows[String(tmdbId)] = ShowRecord(tvmazeId: tvmazeId, checkedAt: now())
        dirty = true
    }

    /// Cached airings when they are fresh and cover the asked window.
    func airings(_ tvmazeId: Int, first: CalendarDay, last: CalendarDay) -> [CalendarTvmazeTimes.Airing]? {
        loadIfNeeded()
        guard let record = store.airings[String(tvmazeId)],
              now().timeIntervalSince(record.fetchedAt) < Self.airingsLifetime,
              record.first <= first, record.last >= last else { return nil }
        return record.airings.filter { airing in
            guard let day = CalendarDay(iso: airing.airdate) else { return false }
            return day >= first && day <= last
        }
    }

    func setAirings(_ tvmazeId: Int, _ airings: [CalendarTvmazeTimes.Airing], first: CalendarDay, last: CalendarDay) {
        loadIfNeeded()
        store.airings[String(tvmazeId)] = AiringsRecord(fetchedAt: now(), first: first, last: last, airings: airings)
        dirty = true
    }

    /// Settings → Clear cache: forgets every show and time.
    func clear() {
        store = Store()
        loaded = true
        dirty = false
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    func flush() {
        guard dirty, let fileURL else { return }
        // Drop stale episode times so the file doesn't grow.
        let current = now()
        store.airings = store.airings.filter { current.timeIntervalSince($0.value.fetchedAt) < Self.airingsLifetime }
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
        dirty = false
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Store.self, from: data) else { return }
        store = decoded
    }
}

import Foundation

enum CalendarLoadError: Error, Equatable, Sendable {
    case tmdbNotConfigured
    case invalidApiKey
}

/// Loads the calendar for a list of library items.
///
/// Read-only: it never changes the library, watched state or sync. A failure
/// for one title is recorded as skipped and does not stop the others; only a
/// missing or rejected TMDB key fails the whole load. Titles with nothing in
/// the period are simply absent.
struct CalendarService: Sendable {
    typealias IdResolver = @Sendable (CalendarItem) async -> Int?

    let client: CalendarTmdb.Client
    let resolveTmdbId: IdResolver
    var maxConcurrent: Int
    var region: String
    /// Broadcast times for anime (AniList); nil leaves TMDB dates as they are.
    var animeTimes: CalendarAnimeTimes?

    init(client: CalendarTmdb.Client, maxConcurrent: Int = 6, region: String,
         animeTimes: CalendarAnimeTimes? = nil, resolveTmdbId: @escaping IdResolver) {
        self.client = client
        self.resolveTmdbId = resolveTmdbId
        self.maxConcurrent = max(1, maxConcurrent)
        self.region = region
        self.animeTimes = animeTimes
    }

    enum Outcome: Sendable {
        case entries([CalendarEntry])
        case skipped(CalendarSkipReason)
        case authFailure
    }

    func load(items: [CalendarItem], first: CalendarDay, last: CalendarDay) async throws -> CalendarResult {
        guard !client.apiKey.isEmpty else { throw CalendarLoadError.tmdbNotConfigured }

        // Movies released more than a year before the period cannot have a
        // release inside it; don't spend a request on each of them.
        let items = items.filter { item in
            guard item.kind == .movie, let year = item.year else { return true }
            return year >= first.year - 1
        }

        // 1. Resolve ids, then drop duplicates (the same title saved twice
        //    under different ids).
        let resolutions = await concurrentMap(items) { item in
            (item, await resolveTmdbId(item))
        }

        var skipped: [CalendarSkippedItem] = []
        var targets: [(CalendarItem, Int)] = []
        var seenTargets = Set<String>()
        var libraryItems: [String: CalendarItem] = [:]
        for (item, tmdbId) in resolutions {
            guard let tmdbId else {
                skipped.append(CalendarSkippedItem(item: item, reason: .unsupportedId))
                continue
            }
            let key = "\(item.kind.rawValue):\(tmdbId)"
            if seenTargets.insert(key).inserted {
                targets.append((item, tmdbId))
                libraryItems[key] = item
            }
        }

        // 2. Fetch episodes / releases inside the period.
        let outcomes = await concurrentMap(targets) { target in
            (target.0, await fetch(item: target.0, tmdbId: target.1, first: first, last: last))
        }

        var entries: [CalendarEntry] = []
        for (item, outcome) in outcomes {
            switch outcome {
            case .entries(let found):
                entries.append(contentsOf: found)
            case .skipped(let reason):
                skipped.append(CalendarSkippedItem(item: item, reason: reason))
            case .authFailure:
                throw CalendarLoadError.invalidApiKey
            }
        }

        if let animeTimes, entries.contains(where: \.isAnime) {
            var imdbByTmdb: [Int: String] = [:]
            for (item, tmdbId) in targets where item.kind == .series && item.id.hasPrefix("tt") {
                imdbByTmdb[tmdbId] = String(item.id.prefix { $0 != ":" })
            }
            entries = await animeTimes.apply(to: entries, imdbByTmdb: imdbByTmdb, first: first, last: last)
        }

        return CalendarResult(
            firstDay: first,
            lastDay: last,
            days: CalendarBuilder.groupByDay(entries),
            skipped: skipped,
            libraryKeys: seenTargets,
            libraryItems: libraryItems
        )
    }

    func fetch(item: CalendarItem, tmdbId: Int, first: CalendarDay, last: CalendarDay) async -> Outcome {
        do {
            switch item.kind {
            case .series:
                let details = try await client.tvDetails(tmdbId)
                let seasons = CalendarBuilder.seasonsToFetch(for: details, first: first, last: last)
                var episodes: [CalendarTmdb.Episode] = []
                for number in seasons {
                    do {
                        episodes += try await client.season(tmdbId, number: number).episodes ?? []
                    } catch {
                        if Self.isAuthError(error) { return .authFailure }
                        // A missing season page should not hide the rest;
                        // fall back to the episodes the show page names.
                        for known in [details.lastEpisodeToAir, details.nextEpisodeToAir].compactMap({ $0 })
                        where known.seasonNumber == number {
                            episodes.append(known)
                        }
                    }
                }
                return .entries(CalendarBuilder.episodeEntries(
                    item: item, details: details, episodes: episodes, first: first, last: last
                ))
            case .movie:
                let details = try await client.movieDetails(tmdbId)
                return .entries(CalendarBuilder.movieEntries(
                    item: item, details: details, region: region, first: first, last: last
                ))
            }
        } catch {
            if Self.isAuthError(error) { return .authFailure }
            return .skipped(.failed(Self.describe(error)))
        }
    }

    /// Runs `transform` over `input` with at most `maxConcurrent` calls in
    /// flight, keeping the input order.
    func concurrentMap<T: Sendable, R: Sendable>(_ input: [T], _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
        guard !input.isEmpty else { return [] }
        var results = [R?](repeating: nil, count: input.count)
        await withTaskGroup(of: (Int, R).self) { group in
            var next = 0
            while next < min(maxConcurrent, input.count) {
                let index = next
                group.addTask { (index, await transform(input[index])) }
                next += 1
            }
            while let finished = await group.next() {
                results[finished.0] = finished.1
                if next < input.count {
                    let index = next
                    group.addTask { (index, await transform(input[index])) }
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }

    static func isAuthError(_ error: Error) -> Bool {
        guard let tmdb = error as? CalendarTmdbError else { return false }
        return tmdb == .unauthorized || tmdb == .missingApiKey
    }

    static func describe(_ error: Error) -> String {
        if let tmdb = error as? CalendarTmdbError {
            switch tmdb {
            case .http(let code): return "HTTP \(code)"
            case .decoding: return "Invalid TMDB response"
            case .notFound: return "Not found on TMDB"
            case .unauthorized, .missingApiKey: return "TMDB key rejected"
            }
        }
        return error.localizedDescription
    }
}

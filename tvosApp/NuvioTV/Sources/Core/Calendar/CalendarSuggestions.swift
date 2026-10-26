import Foundation

/// Ready-made TMDB lists for adding many titles to the library at once
/// ("anime this season", "series airing now", "upcoming movies").
enum CalendarSuggestionList: String, CaseIterable, Identifiable, Sendable {
    case animeToday
    case animeThisSeason
    case seriesToday
    case airingNow
    case upcomingMovies
    /// What the calendar already follows from the library, to remove titles.
    case inCalendar

    var id: String { rawValue }

    /// Lists built from TMDB/AniList; `inCalendar` comes from the library.
    var isLibraryList: Bool { self == .inCalendar }

    var kind: CalendarMediaKind {
        self == .upcomingMovies ? .movie : .series
    }

    /// Top-level button the list sits under in Add shows.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case anime, series, movies, library
        var id: String { rawValue }

        var title: String {
            switch self {
            case .anime: return L10n.string("calendar_suggest_group_anime", fallback: "Anime")
            case .series: return L10n.string("calendar_suggest_group_series", fallback: "Series")
            case .movies: return L10n.string("calendar_suggest_group_movies", fallback: "Movies")
            case .library: return L10n.string("calendar_suggest_group_library", fallback: "In calendar")
            }
        }

        var lists: [CalendarSuggestionList] {
            CalendarSuggestionList.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .animeToday, .animeThisSeason: return .anime
        case .seriesToday, .airingNow: return .series
        case .upcomingMovies: return .movies
        case .inCalendar: return .library
        }
    }

    /// Name inside its group's menu.
    var shortTitle: String {
        switch self {
        case .animeToday, .seriesToday: return L10n.string("calendar_suggest_today", fallback: "Today")
        case .animeThisSeason: return L10n.string("calendar_suggest_this_season", fallback: "This season")
        case .airingNow: return L10n.string("calendar_suggest_airing_now", fallback: "Airing now")
        case .upcomingMovies: return L10n.string("calendar_suggest_upcoming", fallback: "Upcoming")
        case .inCalendar: return L10n.string("calendar_suggest_group_library", fallback: "In calendar")
        }
    }

    var title: String {
        switch self {
        case .animeToday: return L10n.string("calendar_suggest_anime_today", fallback: "Anime today")
        case .animeThisSeason: return L10n.string("calendar_suggest_anime", fallback: "Anime this season")
        case .seriesToday: return L10n.string("calendar_suggest_series_today", fallback: "Series today")
        case .airingNow: return L10n.string("calendar_suggest_airing", fallback: "Series airing now")
        case .upcomingMovies: return L10n.string("calendar_suggest_movies", fallback: "Upcoming movies")
        case .inCalendar: return L10n.string("calendar_suggest_group_library", fallback: "In calendar")
        }
    }
}

struct CalendarSuggestionRequest: Equatable, Sendable {
    let path: String
    let query: [String: String]
}

enum CalendarSuggestions {
    /// TMDB pages per list (20 titles each).
    static let pages = 5

    /// The anime broadcast season `day` falls in: winter Jan–Mar, spring
    /// Apr–Jun, summer Jul–Sep, fall Oct–Dec.
    static func animeSeason(containing day: CalendarDay) -> (first: CalendarDay, last: CalendarDay) {
        let startMonth = ((day.month - 1) / 3) * 3 + 1
        let first = CalendarDay(year: day.year, month: startMonth, day: 1)
        let last = first.addingMonths(2).lastOfMonth
        return (first, last)
    }

    /// Genres left out of "airing now": animation (has its own list), news,
    /// reality and talk shows, which would otherwise crowd the top.
    static let airingNowExcludedGenres = "16,10763,10764,10767"

    static func request(for list: CalendarSuggestionList, today: CalendarDay, region: String) -> CalendarSuggestionRequest {
        switch list {
        case .animeToday:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "with_genres": "16",
                "with_origin_country": "JP",
                "air_date.gte": today.iso,
                "air_date.lte": today.iso,
                "sort_by": "popularity.desc",
            ])
        case .seriesToday:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "without_genres": airingNowExcludedGenres,
                "air_date.gte": today.iso,
                "air_date.lte": today.iso,
                "sort_by": "popularity.desc",
            ])
        case .animeThisSeason:
            let season = animeSeason(containing: today)
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "with_genres": "16",
                "with_origin_country": "JP",
                "air_date.gte": season.first.iso,
                "air_date.lte": season.last.iso,
                "sort_by": "popularity.desc",
            ])
        case .airingNow:
            return CalendarSuggestionRequest(path: "discover/tv", query: [
                "without_genres": airingNowExcludedGenres,
                "air_date.gte": today.iso,
                "air_date.lte": today.adding(days: 14).iso,
                "sort_by": "popularity.desc",
            ])
        case .upcomingMovies:
            return CalendarSuggestionRequest(path: "movie/upcoming", query: ["region": region])
        case .inCalendar:
            // Built from the library, no request.
            return CalendarSuggestionRequest(path: "", query: [:])
        }
    }

    static func key(kind: CalendarMediaKind, tmdbId: Int) -> String {
        "\(kind.rawValue):\(tmdbId)"
    }
}

/// One title in the "Add shows" picker, from a TMDB list or from the
/// AniList + Simkl "Anime today" list.
struct CalendarSuggestionItem: Identifiable, Hashable, Sendable {
    /// Matches `CalendarResult.libraryKeys` ("series:123") when the TMDB id is known.
    let key: String
    let kind: CalendarMediaKind
    let tmdbId: Int?
    let imdbId: String?
    let title: String
    let posterURL: URL?
    let year: Int?
    /// Shown under the title instead of the year (e.g. the broadcast time).
    let detail: String?

    var id: String { key }
    var isAddable: Bool { tmdbId != nil || imdbId != nil }

    init(key: String, kind: CalendarMediaKind, tmdbId: Int?, imdbId: String?, title: String,
         posterURL: URL?, year: Int?, detail: String? = nil) {
        self.key = key
        self.kind = kind
        self.tmdbId = tmdbId
        self.imdbId = imdbId
        self.title = title
        self.posterURL = posterURL
        self.year = year
        self.detail = detail
    }

    init(tmdb result: CalendarTmdb.ListResult, kind: CalendarMediaKind) {
        self.init(
            key: CalendarSuggestions.key(kind: kind, tmdbId: result.id),
            kind: kind,
            tmdbId: result.id,
            imdbId: nil,
            title: result.displayTitle,
            posterURL: CalendarTmdb.imageURL(result.posterPath, size: "w342"),
            year: result.year
        )
    }
}

extension CalendarSuggestions {
    /// The "In calendar" list: every library title the calendar follows,
    /// with its next date, then the titles it couldn't place.
    static func libraryItems(
        library: [String: CalendarItem],
        nextDates: [String: CalendarDay],
        skipped: [String: CalendarSkippedItem],
        today: CalendarDay
    ) -> [CalendarSuggestionItem] {
        func item(_ key: String, _ entry: CalendarItem, detail: String) -> CalendarSuggestionItem {
            let tmdb = key.hasPrefix("skipped:") ? nil : key.split(separator: ":").last.flatMap { Int($0) }
            return CalendarSuggestionItem(
                key: key,
                kind: entry.kind,
                tmdbId: tmdb,
                imdbId: entry.id.hasPrefix("tt") ? entry.id : nil,
                title: entry.name ?? entry.id,
                posterURL: entry.posterURL.flatMap(URL.init(string:)),
                year: entry.year,
                detail: detail
            )
        }
        let placed = library
            .filter { skipped[$0.key] == nil }
            .map { key, entry in
                item(key, entry, detail: nextDates[key].map { CalendarFormat.nextDate($0, today: today) }
                    ?? L10n.string("calendar_suggest_nothing_upcoming", fallback: "Nothing upcoming"))
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let unplaced = skipped
            .filter { library[$0.key] != nil }
            .map { key, skip in item(key, skip.item, detail: CalendarFormat.skipReason(skip.reason)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return placed + unplaced
    }

    /// Library keys of skipped titles ("skipped:series:tt…"), so they can be
    /// listed and removed next to the placed ones.
    static func skippedKey(_ skip: CalendarSkippedItem) -> String { "skipped:\(skip.id)" }
}

/// Adds titles picked from a suggestion list to the active library, the same
/// way "Add to Library" in Details does: the remote watchlist when a Trakt,
/// Simkl, MDBList or WeTrakr library is selected, otherwise the local one.
enum CalendarLibraryWriter {
    @MainActor
    private static var useRemote: Bool {
        TraktSettingsStore.librarySourceMode != .local && SelectedLibraryService.isSelectedAndAuthenticated
    }

    /// Adds the titles and returns the library item stored for each key.
    @MainActor
    static func add(_ items: [CalendarSuggestionItem], client: CalendarTmdb.Client) async -> [String: CalendarItem] {
        var added: [String: CalendarItem] = [:]
        let remote = useRemote
        for item in items where item.isAddable {
            // Addons look titles up by IMDb id, so prefer it over tmdb:.
            var imdb = item.imdbId
            if imdb == nil, let tmdb = item.tmdbId {
                imdb = try? await client.imdbId(tmdbId: tmdb, kind: item.kind)
            }
            guard let id = imdb ?? item.tmdbId.map({ "tmdb:\($0)" }) else { continue }
            let type = item.kind == .series ? "series" : "movie"
            let meta = NuvioMeta(
                id: id,
                name: item.title,
                posterUrl: item.posterURL?.absoluteString,
                imdbId: imdb,
                tmdbId: item.tmdbId,
                type: type,
                year: item.year
            )
            let ok: Bool
            if remote {
                ok = await SelectedLibraryService.setWatchlist(meta, isInWatchlist: true)
            } else {
                LibraryStore.add(meta)
                ok = true
            }
            if ok {
                added[item.key] = CalendarItem(id: id, kind: item.kind, type: type, name: item.title,
                                               posterURL: meta.posterUrl, year: item.year)
            }
        }
        return added
    }

    /// Removes library titles; returns the keys that were removed.
    @MainActor
    static func remove(_ keys: [String], items: [String: CalendarItem]) async -> Set<String> {
        var removed = Set<String>()
        let remote = useRemote
        for key in keys {
            guard let item = items[key] else { continue }
            let type = item.type.isEmpty ? (item.kind == .series ? "series" : "movie") : item.type
            let tmdb = key.split(separator: ":").last.flatMap { Int($0) }
            let meta = NuvioMeta(
                id: item.id,
                name: item.name ?? item.id,
                posterUrl: item.posterURL,
                imdbId: item.id.hasPrefix("tt") ? item.id : nil,
                tmdbId: tmdb,
                type: type,
                year: item.year
            )
            if remote {
                if await SelectedLibraryService.setWatchlist(meta, isInWatchlist: false) { removed.insert(key) }
            } else if LibraryStore.contains(metaId: item.id, type: type) {
                // toggle returns the new state: false = no longer in the library.
                if !LibraryStore.toggle(meta: meta) { removed.insert(key) }
            }
        }
        return removed
    }
}

import Foundation

/// Connects the calendar to Nuvio: the active library, the TMDB settings
/// and the existing TMDB id resolution.
enum CalendarLibrarySource {
    /// Titles of the library the user is looking at: the signed-in remote
    /// library (Trakt, Simkl, MDBList, WeTrakr) or the local one. `nil` when
    /// the remote library could not be loaded.
    @MainActor
    static func libraryMetas(repository: CatalogRepository = CinemetaCatalogRepository()) async -> [NuvioMeta]? {
        if SelectedLibraryService.isSelectedAndAuthenticated {
            return await SelectedLibraryService.fetchLibrary(repository: repository)?.map(\.meta)
        }
        return LibraryStore.items().map(\.meta)
    }

    static func item(for meta: NuvioMeta) -> CalendarItem {
        CalendarItem(
            id: meta.id,
            kind: meta.isSeries ? .series : .movie,
            type: meta.type,
            name: meta.name,
            posterURL: meta.posterUrl,
            year: meta.year
        )
    }

    /// TMDB must be switched on and have a key, as for every other TMDB
    /// feature in Nuvio.
    static var isTmdbConfigured: Bool {
        let store = ProfileSettings.current
        let enabled = (store.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false
        return enabled && !(TmdbDetailsService.currentApiKey ?? "").isEmpty
    }

    static func makeClient() -> CalendarTmdb.Client {
        CalendarTmdb.Client(
            apiKey: TmdbDetailsService.currentApiKey ?? "",
            language: TmdbDetailsService.preferredLanguage
        )
    }

    /// Region for movie release dates, from the device locale.
    static var region: String {
        Locale.current.region?.identifier ?? "US"
    }

    static func makeService(metas: [NuvioMeta]) -> CalendarService {
        let byKey = Dictionary(
            metas.map { ("\(item(for: $0).kind.rawValue):\($0.id)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return CalendarService(client: makeClient(), region: region, animeTimes: CalendarAnimeTimes()) { item in
            guard let meta = byKey["\(item.kind.rawValue):\(item.id)"] else { return nil }
            return await TmdbDetailsService.resolveTmdbId(for: meta)?.id
        }
    }
}

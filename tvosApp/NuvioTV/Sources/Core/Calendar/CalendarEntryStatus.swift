import Combine
import Foundation

enum CalendarAvailability: Equatable, Sendable {
    case checking
    case available
    case unavailable
}

/// Small decisions behind the day panel, kept apart so they can be tested.
enum CalendarEntryRules {
    /// Out already: an earlier day, or today once its known time has passed.
    static func isReleased(_ entry: CalendarEntry, today: CalendarDay, now: Date) -> Bool {
        if entry.date < today { return true }
        guard entry.date == today else { return false }
        guard let airTime = entry.airTime else { return true }
        return airTime <= now
    }

    /// Worth asking the add-ons about: out already, and not a cinema release.
    static func checksAvailability(_ entry: CalendarEntry, today: CalendarDay, now: Date) -> Bool {
        entry.releaseKind != .theatrical && isReleased(entry, today: today, now: now)
    }

    /// Hide the episode's name and picture: spoilers are hidden and it isn't
    /// known to be watched. Not known yet counts as not watched, so nothing
    /// flashes up before the watched state arrives.
    static func hidesSpoilers(_ entry: CalendarEntry, hideSpoilers: Bool, watched: Bool?) -> Bool {
        hideSpoilers && entry.kind == .series && watched != true
    }

    /// Splits `items` into groups of at most `size`, in order.
    static func batches<T>(_ items: [T], size: Int) -> [[T]] {
        let size = max(1, size)
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// The id stream add-ons know a title or episode by, as Details asks
    /// them: the IMDb-based episode id when the metadata has one.
    static func streamId(for entry: CalendarEntry, meta: NuvioMeta?, video: NuvioVideo?) -> String? {
        switch entry.kind {
        case .movie:
            return meta?.streamId ?? NuvioMeta.canonicalImdbID(from: entry.itemId) ?? entry.itemId
        case .series:
            guard let meta, let video else { return nil }
            return meta.canonicalEpisodeStreamId(for: video)
        }
    }
}

/// Watched state and add-on availability for the entries the day panel shows.
///
/// Episodes are matched to the add-on's episode the way opening one does
/// (number, then air date), from the title's metadata, which is loaded once
/// per title (a failed load is tried again after a few minutes). Availability
/// is only asked for the selected day, after the cursor rests on it, two
/// titles at a time, and kept for ten minutes.
@MainActor
final class CalendarEntryStatusModel: ObservableObject {
    typealias MetaLoader = @Sendable (_ id: String, _ type: String) async -> NuvioMeta?
    typealias StreamProbe = @MainActor (_ type: String, _ videoId: String) async -> Bool
    typealias WatchedLookup = @MainActor (_ entry: CalendarEntry, _ meta: NuvioMeta?, _ video: NuvioVideo?) -> Bool

    @Published private(set) var watched: [String: Bool] = [:]
    @Published private(set) var availability: [String: CalendarAvailability] = [:]

    static let availabilityLifetime: TimeInterval = 10 * 60
    static let metaRetryAfter: TimeInterval = 5 * 60
    static let maxConcurrentChecks = 2
    static let maxConcurrentMetas = 3

    private let loadMeta: MetaLoader
    private let probe: StreamProbe
    private let isWatched: WatchedLookup
    /// How long the cursor rests on a day before the add-ons are asked.
    private let availabilityDelay: Duration
    private var metas: [String: NuvioMeta] = [:]
    private var metaLoads: [String: Task<NuvioMeta?, Never>] = [:]
    private var metaFailedAt: [String: Date] = [:]
    private var checkedAt: [String: Date] = [:]
    private var watchedEntries: [CalendarEntry] = []
    private var watchedTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        loadMeta: @escaping MetaLoader = { id, type in
            try? await CinemetaCatalogRepository().getMetadata(id: id, type: type)
        },
        probe: @escaping StreamProbe = { type, videoId in
            await StreamsRepository.hasAnyAddonStream(type: type, videoId: videoId)
        },
        isWatched: @escaping WatchedLookup = CalendarEntryStatusModel.storeIsWatched,
        availabilityDelay: Duration = .seconds(1)
    ) {
        self.loadMeta = loadMeta
        self.probe = probe
        self.isWatched = isWatched
        self.availabilityDelay = availabilityDelay
        NotificationCenter.default.publisher(for: WatchedStore.changedNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.recomputeWatched() }
            }
            .store(in: &cancellables)
    }

    static func storeIsWatched(_ entry: CalendarEntry, _ meta: NuvioMeta?, _ video: NuvioVideo?) -> Bool {
        switch entry.kind {
        case .movie:
            if let meta { return WatchedStore.contains(meta: meta) }
            return WatchedStore.contains(metaId: entry.itemId, type: entry.itemType.isEmpty ? "movie" : entry.itemType)
        case .series:
            guard let video else { return false }
            if let meta { return WatchedStore.containsEpisode(meta: meta, season: video.season, episode: video.episode) }
            return WatchedStore.containsEpisode(metaId: entry.itemId, season: video.season, episode: video.episode)
        }
    }

    // MARK: Watched

    /// Watched state for every entry the panel lists (the displayed month).
    func updateWatched(for entries: [CalendarEntry]) {
        watchedEntries = entries
        recomputeWatched()
        let pending = uniqueTitles(entries.filter { $0.kind == .series }).filter { needsMeta($0.itemId) }
        guard !pending.isEmpty else { return }
        // Loads already running carry on; a newer list just waits for them too.
        watchedTask?.cancel()
        let batches = CalendarEntryRules.batches(pending, size: Self.maxConcurrentMetas)
        watchedTask = Task { [weak self] in
            for batch in batches {
                guard let self, !Task.isCancelled else { return }
                await self.loadMetas(batch)
                self.recomputeWatched()
            }
        }
    }

    private func recomputeWatched() {
        var result: [String: Bool] = [:]
        for entry in watchedEntries {
            let meta = metas[entry.itemId]
            // A series without its episode list stays unknown (spoilers hidden).
            if entry.kind == .series, meta == nil { continue }
            result[entry.id] = isWatched(entry, meta, video(for: entry, in: meta))
        }
        if result != watched { watched = result }
    }

    // MARK: Availability

    /// Asks the add-ons about the selected day's released entries once the
    /// cursor has rested on it. Moving on cancels what hasn't finished.
    func checkAvailability(for entries: [CalendarEntry], today: CalendarDay, now: Date = Date()) {
        cancelAvailability()
        let due = entries.filter { entry in
            guard CalendarEntryRules.checksAvailability(entry, today: today, now: now) else { return false }
            guard let checked = checkedAt[entry.id] else { return true }
            return now.timeIntervalSince(checked) >= Self.availabilityLifetime
        }
        guard !due.isEmpty else { return }
        let delay = availabilityDelay
        let batches = CalendarEntryRules.batches(due, size: Self.maxConcurrentChecks)
        availabilityTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            for batch in batches {
                guard let self, !Task.isCancelled else { return }
                await self.check(batch)
            }
        }
    }

    /// Stops checking; answers already in stay.
    func cancelAvailability() {
        availabilityTask?.cancel()
        availabilityTask = nil
        // Checks that were cut short start over next time.
        let unfinished = availability.filter { $0.value == .checking }.map(\.key)
        for id in unfinished { availability[id] = nil }
    }

    /// The option was turned off: stop and forget every answer.
    func clearAvailability() {
        cancelAvailability()
        availability = [:]
        checkedAt = [:]
    }

    /// Waits for the current checks and metadata loads (tests).
    func settle() async {
        await watchedTask?.value
        await availabilityTask?.value
    }

    private func check(_ batch: [CalendarEntry]) async {
        for entry in batch { availability[entry.id] = .checking }
        await loadMetas(batch)
        guard !Task.isCancelled else { return }
        // The episode lists just loaded also settle watched and spoilers.
        recomputeWatched()
        let targets = batch.map { entry in (entry, streamTarget(for: entry)) }
        let probe = probe
        let results = await withTaskGroup(of: (String, Bool?).self) { group in
            for (entry, target) in targets {
                group.addTask {
                    guard let target else { return (entry.id, nil) }
                    return (entry.id, await probe(target.type, target.videoId))
                }
            }
            var collected: [(String, Bool?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        guard !Task.isCancelled else { return }
        let now = Date()
        for (id, found) in results {
            guard let found else {
                availability[id] = nil
                continue
            }
            availability[id] = found ? .available : .unavailable
            checkedAt[id] = now
        }
    }

    /// What to ask the add-ons for: the movie, or the add-on's episode.
    private func streamTarget(for entry: CalendarEntry) -> (type: String, videoId: String)? {
        let meta = metas[entry.itemId]
        let type = entry.itemType.isEmpty ? entry.kind.rawValue : entry.itemType
        guard let id = CalendarEntryRules.streamId(for: entry, meta: meta, video: video(for: entry, in: meta)) else {
            return nil
        }
        return (type, id)
    }

    // MARK: Metadata

    private func uniqueTitles(_ entries: [CalendarEntry]) -> [CalendarEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.itemId).inserted }
    }

    private func needsMeta(_ id: String) -> Bool {
        guard metas[id] == nil, metaLoads[id] == nil else { return false }
        if let failed = metaFailedAt[id], Date().timeIntervalSince(failed) < Self.metaRetryAfter { return false }
        return true
    }

    /// Loads the titles' metadata, sharing a load already running for one.
    private func loadMetas(_ entries: [CalendarEntry]) async {
        let titles = uniqueTitles(entries)
        guard !titles.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for entry in titles {
                group.addTask { [weak self] in _ = await self?.metadata(for: entry) }
            }
        }
    }

    private func metadata(for entry: CalendarEntry) async -> NuvioMeta? {
        let id = entry.itemId
        if let meta = metas[id] { return meta }
        if let running = metaLoads[id] { return await running.value }
        guard needsMeta(id) else { return nil }
        let loader = loadMeta
        let type = entry.itemType.isEmpty ? entry.kind.rawValue : entry.itemType
        let load = Task { await loader(id, type) }
        metaLoads[id] = load
        let meta = await load.value
        metaLoads[id] = nil
        if let meta {
            metas[id] = meta
            metaFailedAt[id] = nil
        } else {
            metaFailedAt[id] = Date()
        }
        return meta
    }

    private func video(for entry: CalendarEntry, in meta: NuvioMeta?) -> NuvioVideo? {
        guard entry.kind == .series, let meta, let season = entry.seasonNumber, let episode = entry.episodeNumber else {
            return nil
        }
        let focus = DetailsEpisodeFocus(metaID: entry.itemId, season: season, episode: episode, airDate: entry.date)
        return focus.pick(from: meta.videos ?? [])
    }
}

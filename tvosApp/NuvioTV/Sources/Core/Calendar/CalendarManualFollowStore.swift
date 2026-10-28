import Foundation

/// Per-profile list of titles explicitly followed in the calendar. This is
/// separate from library and tracking accounts, and is never profile-seeded.
@MainActor
enum CalendarManualFollowStore {
    struct ProfileContext: Equatable, Sendable {
        let settingsProfileID: String?
        let libraryProfileID: String?

        var profileID: String? {
            guard let settingsProfileID, !settingsProfileID.isEmpty,
                  settingsProfileID == libraryProfileID else { return nil }
            return settingsProfileID
        }

        var isCurrent: Bool {
            ProfileSettings.activeProfileID == settingsProfileID
                && LibraryStore.activeProfileId == libraryProfileID
        }
    }

    static let changedNotification = Notification.Name("nuvio.tv.calendar.manualFollows.changed")

    nonisolated private static let storageDirectory = "calendarManualFollows"
    nonisolated private static let storagePrefix = "calendarManualFollows."
    private static let payloadVersion = 1

    private struct Payload: Codable {
        let version: Int
        let items: [String: CalendarItem]
    }

    static func captureProfileContext() -> ProfileContext {
        ProfileContext(
            settingsProfileID: ProfileSettings.activeProfileID,
            libraryProfileID: LibraryStore.activeProfileId
        )
    }

    static func items() -> [String: CalendarItem] {
        items(profileID: captureProfileContext().profileID)
    }

    static func items(profileID: String?) -> [String: CalendarItem] {
        guard let profileID, !profileID.isEmpty,
              let data = LargePayloadStore.read(key: storageKey(profileID), directory: storageDirectory),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == payloadVersion else { return [:] }
        return payload.items
    }

    static func signature() -> String {
        signature(profileID: captureProfileContext().profileID)
    }

    static func signature(profileID: String?) -> String {
        let records = items(profileID: profileID).sorted { $0.key < $1.key }.map { key, item in
            [key, item.id, item.type, item.name ?? "", item.posterURL ?? "", item.year.map(String.init) ?? "",
             item.imdbId ?? "", item.tmdbId.map(String.init) ?? ""].joined(separator: "|")
        }
        return CalendarSnapshot.digest(records.joined(separator: "\n"))
    }

    /// Adds suggestions only to the calendar's own list. The persisted item
    /// retains the TMDB/IMDb ids and type needed to resolve movies and anime.
    static func resolvingTMDBIDs(
        for suggestions: [CalendarSuggestionItem],
        profileContext: ProfileContext
    ) async -> [CalendarSuggestionItem] {
        guard profileContext.isCurrent else { return [] }
        var tmdbIDs = suggestions.map(\.tmdbId)
        let unresolved = suggestions.enumerated().compactMap { index, suggestion -> (Int, String)? in
            guard suggestion.tmdbId == nil,
                  let imdbID = NuvioMeta.canonicalImdbID(from: suggestion.imdbId ?? "") else { return nil }
            return (index, imdbID)
        }
        let batchSize = 4
        var start = 0
        while start < unresolved.count {
            guard !Task.isCancelled, profileContext.isCurrent else { return [] }
            let end = min(start + batchSize, unresolved.count)
            let batch = Array(unresolved[start..<end])
            let resolvedBatch = await withTaskGroup(of: (Int, Int?).self) { group in
                for (index, imdbID) in batch {
                    let suggestion = suggestions[index]
                    group.addTask { @MainActor in
                        guard !Task.isCancelled, profileContext.isCurrent else { return (index, nil) }
                        let meta = NuvioMeta(
                            id: imdbID,
                            name: suggestion.title,
                            imdbId: imdbID,
                            type: suggestion.type,
                            year: suggestion.year
                        )
                        let tmdbID = await TmdbDetailsService.resolveTmdbId(for: meta)?.id
                        guard !Task.isCancelled, profileContext.isCurrent else { return (index, nil) }
                        return (index, tmdbID)
                    }
                }
                var values: [(Int, Int?)] = []
                for await value in group {
                    if Task.isCancelled || !profileContext.isCurrent {
                        group.cancelAll()
                        break
                    }
                    values.append(value)
                }
                return values
            }
            guard !Task.isCancelled, profileContext.isCurrent else { return [] }
            for (index, tmdbID) in resolvedBatch where tmdbID != nil {
                tmdbIDs[index] = tmdbID
            }
            start = end
        }

        return suggestions.enumerated().map { index, suggestion in
            let tmdbID = tmdbIDs[index]
            return CalendarSuggestionItem(
                key: tmdbID.map { CalendarSuggestions.key(kind: suggestion.kind, tmdbId: $0) } ?? suggestion.key,
                kind: suggestion.kind,
                type: suggestion.type,
                tmdbId: tmdbID,
                imdbId: suggestion.imdbId,
                title: suggestion.title,
                posterURL: suggestion.posterURL,
                year: suggestion.year,
                detail: suggestion.detail,
                isAutomaticallyFollowed: suggestion.isAutomaticallyFollowed
            )
        }
    }

    @discardableResult
    static func add(_ suggestions: [CalendarSuggestionItem], profileID: String?) -> [String: CalendarItem] {
        guard let profileID, !profileID.isEmpty else { return [:] }
        var current = items(profileID: profileID)
        var added: [String: CalendarItem] = [:]
        for suggestion in suggestions where suggestion.isAddable {
            let imdbID = NuvioMeta.canonicalImdbID(from: suggestion.imdbId ?? "")
            let tmdbID = suggestion.tmdbId
            guard let id = imdbID ?? tmdbID.map({ "tmdb:\($0)" }) else { continue }
            let item = CalendarItem(
                id: id,
                kind: suggestion.kind,
                type: suggestion.type,
                name: suggestion.title,
                posterURL: suggestion.posterURL?.absoluteString,
                year: suggestion.year,
                imdbId: imdbID,
                tmdbId: tmdbID
            )
            let key = key(for: item)
            current[key] = item
            added[key] = item
        }
        guard !added.isEmpty, persist(current, profileID: profileID) else { return [:] }
        notifyChanged(profileID: profileID)
        return added
    }

    @discardableResult
    static func remove(_ keys: Set<String>, profileID: String?) -> Set<String> {
        guard let profileID, !profileID.isEmpty else { return [] }
        var current = items(profileID: profileID)
        let removed = keys.intersection(current.keys)
        guard !removed.isEmpty else { return [] }
        for key in removed { current.removeValue(forKey: key) }
        guard persist(current, profileID: profileID) else { return [] }
        notifyChanged(profileID: profileID)
        return removed
    }

    nonisolated static func clear(profileID: String) {
        guard !profileID.isEmpty else { return }
        LargePayloadStore.remove(key: storageKey(profileID), directory: storageDirectory)
    }

    nonisolated static func key(for item: CalendarItem) -> String {
        let tmdbID = item.tmdbId ?? tmdbID(from: item.id)
        if let tmdbID { return "\(item.kind.rawValue):\(tmdbID)" }
        let imdbID = NuvioMeta.canonicalImdbID(from: item.imdbId ?? item.id)
        if let imdbID { return "\(item.kind.rawValue):\(imdbID)" }
        return item.sourceIdentityKey
    }

    nonisolated static func key(for suggestion: CalendarSuggestionItem) -> String {
        if let tmdbID = suggestion.tmdbId { return CalendarSuggestions.key(kind: suggestion.kind, tmdbId: tmdbID) }
        if let imdbID = NuvioMeta.canonicalImdbID(from: suggestion.imdbId ?? "") {
            return "\(suggestion.kind.rawValue):\(imdbID)"
        }
        return suggestion.key
    }

    nonisolated static func matchingKey(for suggestion: CalendarSuggestionItem, in items: [String: CalendarItem]) -> String? {
        let canonicalKey = key(for: suggestion)
        if items[canonicalKey] != nil { return canonicalKey }
        let candidate = item(for: suggestion)
        return items.first { sameTitle($0.value, candidate) }?.key
    }

    nonisolated static func matchingKey(
        for suggestion: CalendarSuggestionItem,
        in items: [String: CalendarItem],
        resolvedManualFollows: [String: CalendarItem]
    ) -> String? {
        if let direct = matchingKey(for: suggestion, in: items) { return direct }
        let candidate = item(for: suggestion)
        let resolved = resolvedManualFollows[key(for: suggestion)]
            ?? resolvedManualFollows.values.first { sameTitle($0, candidate) }
        guard let resolved else { return nil }
        return items.first { sameTitle($0.value, resolved) }?.key
    }

    nonisolated static func matches(_ suggestion: CalendarSuggestionItem, item: CalendarItem) -> Bool {
        sameTitle(item, self.item(for: suggestion))
    }

    nonisolated private static func item(for suggestion: CalendarSuggestionItem) -> CalendarItem {
        CalendarItem(
            id: suggestion.imdbId ?? suggestion.tmdbId.map { "tmdb:\($0)" } ?? suggestion.key,
            kind: suggestion.kind,
            type: suggestion.type,
            imdbId: suggestion.imdbId,
            tmdbId: suggestion.tmdbId
        )
    }

    nonisolated static func sameTitle(_ lhs: CalendarItem, _ rhs: CalendarItem) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        let left = aliases(for: lhs)
        let right = aliases(for: rhs)
        return !left.isDisjoint(with: right)
    }

    nonisolated private static func aliases(for item: CalendarItem) -> Set<String> {
        var result = Set<String>()
        if let tmdbID = item.tmdbId ?? tmdbID(from: item.id) { result.insert("tmdb:\(tmdbID)") }
        if let imdbID = NuvioMeta.canonicalImdbID(from: item.imdbId ?? item.id) { result.insert(imdbID) }
        result.insert(item.id.lowercased())
        return result
    }

    nonisolated private static func tmdbID(from id: String) -> Int? {
        guard id.hasPrefix("tmdb:") else { return nil }
        return Int(id.dropFirst("tmdb:".count))
    }

    private static func persist(_ items: [String: CalendarItem], profileID: String) -> Bool {
        let key = storageKey(profileID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(version: payloadVersion, items: items)) else { return false }
        return LargePayloadStore.write(data, key: key, directory: storageDirectory)
    }

    nonisolated private static func storageKey(_ profileID: String) -> String {
        storagePrefix + profileID
    }

    private static func notifyChanged(profileID: String) {
        NotificationCenter.default.post(
            name: changedNotification,
            object: nil,
            userInfo: ["profileID": profileID]
        )
    }
}

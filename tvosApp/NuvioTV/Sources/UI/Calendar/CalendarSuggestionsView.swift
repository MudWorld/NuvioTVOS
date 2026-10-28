import SwiftUI

/// Pick titles to follow manually in the calendar. Watched and in-progress
/// titles are shown as automatic follows and cannot be removed here.
struct CalendarSuggestionsView: View {
    let automaticFollowItems: [String: CalendarItem]
    let resolvedManualFollowItems: [String: CalendarItem]
    /// Next day each followed title has something on (for "In calendar").
    let nextDates: [String: CalendarDay]
    let skipped: [String: CalendarSkippedItem]
    let profileContext: CalendarManualFollowStore.ProfileContext
    let accent: Color
    let onClose: (_ changed: Int) -> Void

    @State private var list: CalendarSuggestionList = .animeToday
    @State private var results: [CalendarSuggestionItem] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selected = Set<String>()
    @State private var isBusy = false
    @State private var loadTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    /// Manual follow state as changed in this sheet.
    @State private var manualFollowItems: [String: CalendarItem]
    @State private var changed = 0
    @State private var confirmingRemove = false

    init(manualFollowItems: [String: CalendarItem], automaticFollowItems: [String: CalendarItem],
         resolvedManualFollowItems: [String: CalendarItem], nextDates: [String: CalendarDay] = [:],
         skipped: [String: CalendarSkippedItem] = [:],
         profileContext: CalendarManualFollowStore.ProfileContext,
         accent: Color,
         onClose: @escaping (_ changed: Int) -> Void) {
        self.automaticFollowItems = automaticFollowItems
        self.resolvedManualFollowItems = resolvedManualFollowItems
        self.nextDates = nextDates
        self.skipped = skipped
        self.profileContext = profileContext
        self.accent = accent
        self.onClose = onClose
        _manualFollowItems = State(initialValue: manualFollowItems)
    }

    private let columns = [GridItem(
        .adaptive(minimum: LibraryGridMetrics.posterWidth, maximum: LibraryGridMetrics.posterWidth),
        spacing: LibraryGridMetrics.posterGap,
        alignment: .top
    )]

    private var toAdd: [CalendarSuggestionItem] {
        results.filter { selected.contains($0.key) && $0.isAddable && manualFollowKey(for: $0) == nil }
    }

    private var toRemove: [String] {
        results.compactMap { result in
            guard selected.contains(result.key) else { return nil }
            return manualFollowKey(for: result)
        }
    }

    private var automaticRemovalCount: Int {
        toRemove.filter { key in
            results.first(where: { manualFollowKey(for: $0) == key }).map(isAutomaticallyFollowed) == true
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(L10n.string("calendar_suggest_add_to_calendar", fallback: "Add to calendar"))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text(L10n.string(
                    "calendar_suggest_manual_auto_hint",
                    fallback: "Manual follows stay until removed. Watched or in-progress shows follow automatically."
                ))
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.5))
            }
            // Lists and actions share the row right above the posters, so
            // confirming is one step up instead of a scroll to the end.
            HStack(spacing: 20) {
                // Anime and Series open a small menu (Today / This season,
                // Today / Airing now); Movies has a single list.
                ForEach(CalendarSuggestionList.Group.allCases) { group in
                    let isCurrent = list.group == group
                    let label = isCurrent && group.lists.count > 1
                        ? "\(group.title): \(list.shortTitle)"
                        : group.title
                    if group.lists.count > 1 {
                        FilterMenu(label: label) {
                            ForEach(group.lists) { option in
                                Button {
                                    pick(option)
                                } label: {
                                    if option == list {
                                        Label(option.shortTitle, systemImage: "checkmark")
                                    } else {
                                        Text(option.shortTitle)
                                    }
                                }
                            }
                        }
                    } else if let only = group.lists.first {
                        SourceModeChip(title: label, isSelected: isCurrent) {
                            pick(only)
                        }
                    }
                }
                Spacer(minLength: 20)
                Group {
                    SourceModeChip(
                        title: isBusy
                            ? L10n.string("calendar_suggest_working", fallback: "Saving…")
                            : L10n.format("calendar_suggest_add", fallback: "Add %d", toAdd.count),
                        isSelected: false
                    ) {
                        addSelected()
                    }
                    .disabled(toAdd.isEmpty || isBusy)
                    .opacity(toAdd.isEmpty || isBusy ? 0.4 : 1)

                    if !toRemove.isEmpty {
                        SourceModeChip(
                            title: L10n.format("calendar_suggest_remove", fallback: "Remove %d", toRemove.count),
                            isSelected: false
                        ) {
                            // Several at once (or everything) asks first.
                            if toRemove.count > 1 || automaticRemovalCount > 0 {
                                confirmingRemove = true
                            } else {
                                removeSelected()
                            }
                        }
                        .disabled(isBusy)
                        .opacity(isBusy ? 0.4 : 1)
                    }

                    SourceModeChip(title: L10n.string("calendar_suggest_select_all", fallback: "Select all"), isSelected: false) {
                        if list.isCalendarList {
                            selected = Set(results.compactMap { result in
                                manualFollowKey(for: result) == nil ? nil : result.key
                            })
                        } else {
                            selected = Set(results.filter { $0.isAddable && manualFollowKey(for: $0) == nil }.map(\.key))
                        }
                    }
                    .disabled(results.isEmpty || isBusy)
                    .opacity(results.isEmpty || isBusy ? 0.4 : 1)

                    SourceModeChip(
                        title: isBusy
                            ? L10n.string("calendar_suggest_cancel", fallback: "Cancel")
                            : L10n.string("action_close", fallback: "Close"),
                        isSelected: false
                    ) {
                        if isBusy { saveTask?.cancel() }
                        onClose(changed)
                    }
                }
            }
            .zIndex(1)

            content
        }
        .padding(.horizontal, LibraryGridMetrics.pageInset)
        .padding(.top, 50)
        .ignoresSafeArea(edges: .bottom)
        // Opaque, so the calendar doesn't show through behind the posters.
        .background(Color.black.ignoresSafeArea())
        .onAppear { load() }
        // Play/Pause on the remote adds the selection from anywhere in the grid.
        .onPlayPauseCommand {
            if !toAdd.isEmpty && !isBusy { addSelected() }
        }
        .onExitCommand {
            if isBusy { saveTask?.cancel() }
            onClose(changed)
        }
        .alert(
            removalConfirmation,
            isPresented: $confirmingRemove
        ) {
            Button(L10n.string("calendar_suggest_manual_remove_action", fallback: "Remove from calendar"), role: .destructive) {
                removeSelected()
            }
            Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) {}
        }
        .onDisappear {
            loadTask?.cancel()
            saveTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            Text(errorText)
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: LibraryGridMetrics.posterGap) {
                    ForEach(results) { result in
                        CalendarSuggestionCell(
                            result: displayedResult(result),
                            isSelected: selected.contains(result.key),
                            hasManualFollow: manualFollowKey(for: result) != nil,
                            showsFollowStatus: list.isCalendarList,
                            accent: accent,
                            onSelect: { toggleSelection(result) },
                            onHold: { holdAction(result) }
                        )
                        // Unaddable and already-followed titles stay focusable
                        // so their status is visible on the focused card.
                        .disabled(isBusy)
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 12)
                .padding(.bottom, 90)
            }
        }
    }

    private func pick(_ option: CalendarSuggestionList) {
        guard option != list else { return }
        list = option
        load()
    }

    private func toggleSelection(_ result: CalendarSuggestionItem) {
        guard result.isAddable || manualFollowKey(for: result) != nil else { return }
        if selected.contains(result.key) {
            selected.remove(result.key)
        } else {
            selected.insert(result.key)
        }
    }

    private func holdAction(_ result: CalendarSuggestionItem) {
        guard !isBusy else { return }
        if let key = manualFollowKey(for: result) {
            if isAutomaticallyFollowed(result) {
                selected = [result.key]
                confirmingRemove = true
            } else {
                remove([key])
            }
        } else if result.isAddable {
            add([result])
        }
    }

    private func load() {
        loadTask?.cancel()
        selected = []
        errorText = nil
        isLoading = true
        let list = list
        let request = CalendarSuggestions.request(
            for: list, today: CalendarDay(date: Date()), region: CalendarLibrarySource.region
        )
        let client = CalendarLibrarySource.makeClient()
        loadTask = Task {
            do {
                let found: [CalendarSuggestionItem]
                if list == .inCalendar {
                    found = CalendarSuggestions.calendarItems(
                        manualFollows: manualFollowItems,
                        automaticFollows: automaticFollowItems,
                        resolvedManualFollows: resolvedManualFollowItems,
                        nextDates: nextDates,
                        skipped: skipped,
                        today: CalendarDay(date: Date())
                    )
                } else if list == .animeToday {
                    // Exact broadcast times from AniList, ids from arm / Simkl.
                    found = try await CalendarAnimeToday.load(tmdb: client)
                } else {
                    found = try await client.list(request.path, query: request.query, pages: CalendarSuggestions.pages)
                        .map { CalendarSuggestionItem(tmdb: $0, kind: list.kind, type: list.itemType) }
                }
                guard !Task.isCancelled else { return }
                guard profileContext.isCurrent else { return }
                results = found
                isLoading = false
                if found.isEmpty {
                    errorText = list.isCalendarList
                        ? L10n.string("calendar_suggest_follow_empty", fallback: "No manual or automatic calendar follows yet.")
                        : L10n.string("calendar_suggest_empty", fallback: "TMDB has nothing in this list right now.")
                }
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorText = CalendarService.describe(error)
            }
        }
    }

    private func addSelected() { add(toAdd) }

    private func removeSelected() { remove(toRemove) }

    private func add(_ items: [CalendarSuggestionItem]) {
        guard !items.isEmpty else { return }
        isBusy = true
        guard profileContext.isCurrent else {
            isBusy = false
            errorText = L10n.string("calendar_manual_profile_changed", fallback: "The active profile changed. Reopen this list to continue.")
            return
        }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            let resolvedItems = await CalendarManualFollowStore.resolvingTMDBIDs(
                for: items,
                profileContext: profileContext
            )
            guard !Task.isCancelled else { return }
            guard profileContext.isCurrent else {
                isBusy = false
                errorText = L10n.string("calendar_manual_profile_changed", fallback: "The active profile changed. Reopen this list to continue.")
                return
            }
            let added = CalendarManualFollowStore.add(resolvedItems, profileID: profileContext.profileID)
            for (key, item) in added { manualFollowItems[key] = item }
            selected.subtract(items.map(\.key))
            changed += added.count
            if added.isEmpty {
                errorText = L10n.string("calendar_manual_save_failed", fallback: "Couldn't save the calendar follow. Try again.")
            }
            refreshCalendarListIfNeeded()
            isBusy = false
            saveTask = nil
        }
    }

    private func remove(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        isBusy = true
        guard profileContext.isCurrent else {
            isBusy = false
            errorText = L10n.string("calendar_manual_profile_changed", fallback: "The active profile changed. Reopen this list to continue.")
            return
        }
        let removed = CalendarManualFollowStore.remove(Set(keys), profileID: profileContext.profileID)
        let removedResultKeys = results.compactMap { result -> String? in
            guard selected.contains(result.key), let key = manualFollowKey(for: result), removed.contains(key) else { return nil }
            return result.key
        }
        for key in removed { manualFollowItems.removeValue(forKey: key) }
        selected.subtract(keys)
        selected.subtract(removedResultKeys)
        changed += removed.count
        if removed.isEmpty { errorText = L10n.string("calendar_manual_save_failed", fallback: "Couldn't save the calendar follow. Try again.") }
        refreshCalendarListIfNeeded()
        isBusy = false
    }

    private func manualFollowKey(for result: CalendarSuggestionItem) -> String? {
        CalendarManualFollowStore.matchingKey(
            for: result,
            in: manualFollowItems,
            resolvedManualFollows: resolvedManualFollowItems
        )
    }

    private func isAutomaticallyFollowed(_ result: CalendarSuggestionItem) -> Bool {
        guard !result.isAutomaticallyFollowed else { return true }
        if automaticFollowItems[CalendarManualFollowStore.key(for: result)] != nil { return true }
        if let manualKey = manualFollowKey(for: result),
           let manual = manualFollowItems[manualKey],
           let resolved = resolvedManualFollowItems.first(where: { CalendarManualFollowStore.sameTitle($0.value, manual) }),
           automaticFollowItems[resolved.key] != nil {
            return true
        }
        return automaticFollowItems.values.contains(where: { CalendarManualFollowStore.matches(result, item: $0) })
    }

    private func displayedResult(_ result: CalendarSuggestionItem) -> CalendarSuggestionItem {
        var displayed = result
        displayed.isAutomaticallyFollowed = isAutomaticallyFollowed(result)
        return displayed
    }

    private func refreshCalendarListIfNeeded() {
        guard list.isCalendarList else { return }
        results = CalendarSuggestions.calendarItems(
            manualFollows: manualFollowItems,
            automaticFollows: automaticFollowItems,
            resolvedManualFollows: resolvedManualFollowItems,
            nextDates: nextDates,
            skipped: skipped,
            today: CalendarDay(date: Date())
        )
    }

    private var removalConfirmation: String {
        if automaticRemovalCount > 0 {
            return L10n.format(
                "calendar_suggest_remove_manual_automatic_confirm",
                fallback: "Remove %d manual follows? Watched or in-progress titles will remain in the calendar.",
                toRemove.count
            )
        }
        return L10n.format(
            "calendar_suggest_manual_remove_confirm",
            fallback: "Remove %d manual follows from your calendar?",
            toRemove.count
        )
    }
}

/// A poster that selects on click and runs `onHold` after a half-second hold.
private struct CalendarSuggestionCell: View {
    let result: CalendarSuggestionItem
    let isSelected: Bool
    let hasManualFollow: Bool
    var showsFollowStatus = false
    let accent: Color
    let onSelect: () -> Void
    let onHold: () -> Void

    @State private var didTriggerHold = false

    var body: some View {
        Button {
            // The click that ends a hold must not also toggle the selection.
            if didTriggerHold {
                didTriggerHold = false
                return
            }
            onSelect()
        } label: {
            CalendarSuggestionCard(result: result, isSelected: isSelected, hasManualFollow: hasManualFollow,
                                   showsFollowStatus: showsFollowStatus, accent: accent)
        }
        .buttonStyle(CalendarHoldButtonStyle(onHold: onHold, didTriggerHold: $didTriggerHold))
        .focusEffectDisabledIfAvailable()
    }
}

private struct CalendarHoldButtonStyle: ButtonStyle {
    let onHold: () -> Void
    @Binding var didTriggerHold: Bool
    @State private var holdTask: Task<Void, Never>?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                holdTask?.cancel()
                holdTask = nil
                guard isPressed else { return }
                holdTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    didTriggerHold = true
                    onHold()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        didTriggerHold = false
                    }
                }
            }
    }
}

private struct CalendarSuggestionCard: View {
    @Environment(\.isFocused) private var isFocused
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    let result: CalendarSuggestionItem
    let isSelected: Bool
    let hasManualFollow: Bool
    var showsFollowStatus = false
    let accent: Color

    private var cardCornerRadius: CGFloat { AppCardStyle.cornerRadius(for: cardCornerRadiusSetting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: result.posterURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "photo").foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: LibraryGridMetrics.posterWidth, height: LibraryGridMetrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .opacity(showsFollowStatus ? 1 : (hasManualFollow || !result.isAddable ? 0.45 : 1))

                if isSelected || (hasManualFollow && !showsFollowStatus) {
                    Image(systemName: isSelected && hasManualFollow ? "minus.circle.fill"
                          : (hasManualFollow ? "checkmark.circle" : "checkmark.circle.fill"))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(isSelected && hasManualFollow ? .red : (hasManualFollow ? .white.opacity(0.8) : accent))
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.white : (isSelected ? (hasManualFollow ? Color.red : accent) : Color.clear),
                        lineWidth: isFocused || isSelected ? 4 : 0
                    )
            )
            Text(result.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(width: LibraryGridMetrics.posterWidth, alignment: .leading)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var subtitle: String {
        if showsFollowStatus {
            return result.detail ?? L10n.string("calendar_suggest_nothing_upcoming", fallback: "Nothing upcoming")
        }
        let automaticLabel = L10n.string(
            "calendar_suggest_automatic_follow",
            fallback: "Automatically followed while watched or in progress"
        )
        if hasManualFollow {
            let manualLabel = L10n.string("calendar_suggest_manual_follow", fallback: "Manual follow")
            let source = result.isAutomaticallyFollowed
                ? "\(manualLabel) · \(L10n.string("calendar_suggest_also_automatic", fallback: "also followed automatically"))"
                : manualLabel
            return [source, result.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if result.isAutomaticallyFollowed {
            return [automaticLabel, result.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if !result.isAddable { return L10n.string("calendar_suggest_no_ids", fallback: "No TMDB or IMDb id") }
        return result.detail ?? result.year.map(String.init) ?? ""
    }
}

import SwiftUI

/// Pick titles from a list and add them to the library, or take them out.
/// Select = mark for a bulk add/remove; hold = add or remove that one now.
struct CalendarSuggestionsView: View {
    let libraryItems: [String: CalendarItem]
    /// Next day each library title has something on (for "In calendar").
    let nextDates: [String: CalendarDay]
    /// Library titles the calendar couldn't place, by their "skipped:" key.
    let skipped: [String: CalendarSkippedItem]
    let accent: Color
    let onClose: (_ changed: Int) -> Void

    @State private var list: CalendarSuggestionList = .animeToday
    @State private var results: [CalendarSuggestionItem] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selected = Set<String>()
    @State private var isBusy = false
    @State private var loadTask: Task<Void, Never>?
    /// Library state as changed in this sheet (starts as the calendar's).
    @State private var library: [String: CalendarItem]
    @State private var changed = 0
    @State private var confirmingRemove = false

    init(libraryItems: [String: CalendarItem], nextDates: [String: CalendarDay] = [:],
         skipped: [String: CalendarSkippedItem] = [:], accent: Color,
         onClose: @escaping (_ changed: Int) -> Void) {
        self.libraryItems = libraryItems
        self.nextDates = nextDates
        self.skipped = skipped
        self.accent = accent
        self.onClose = onClose
        _library = State(initialValue: libraryItems)
    }

    private let columns = Array(repeating: GridItem(.fixed(190), spacing: 28), count: 7)

    private var toAdd: [CalendarSuggestionItem] {
        results.filter { selected.contains($0.key) && $0.isAddable && library[$0.key] == nil }
    }

    private var toRemove: [String] {
        results.map(\.key).filter { selected.contains($0) && library[$0] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(L10n.string("calendar_suggest_title", fallback: "Add to library"))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text(L10n.string("calendar_suggest_hint", fallback: "Hold: add or remove one · Play/Pause: add selected"))
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
                        Menu {
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
                        } label: {
                            Label(label, systemImage: "chevron.down")
                                .font(.system(size: 22, weight: isCurrent ? .bold : .regular))
                        }
                    } else if let only = group.lists.first {
                        Button {
                            pick(only)
                        } label: {
                            Text(label)
                                .font(.system(size: 22, weight: isCurrent ? .bold : .regular))
                        }
                    }
                }
                Spacer(minLength: 20)
                Group {
                    Button {
                        addSelected()
                    } label: {
                        Label(
                            isBusy
                                ? L10n.string("calendar_suggest_working", fallback: "Saving…")
                                : L10n.format("calendar_suggest_add", fallback: "Add %d", toAdd.count),
                            systemImage: "plus"
                        )
                    }
                    .disabled(toAdd.isEmpty || isBusy)

                    if !toRemove.isEmpty {
                        Button {
                            // Several at once (or everything) asks first.
                            if toRemove.count > 1 {
                                confirmingRemove = true
                            } else {
                                removeSelected()
                            }
                        } label: {
                            Label(L10n.format("calendar_suggest_remove", fallback: "Remove %d", toRemove.count),
                                  systemImage: "minus")
                        }
                        .disabled(isBusy)
                    }

                    Button(L10n.string("calendar_suggest_select_all", fallback: "Select all")) {
                        if list.isLibraryList {
                            selected = Set(results.map(\.key).filter { library[$0] != nil })
                        } else {
                            selected = Set(results.filter { $0.isAddable && library[$0.key] == nil }.map(\.key))
                        }
                    }
                    .disabled(results.isEmpty || isBusy)

                    Button(L10n.string("action_close", fallback: "Close")) { onClose(changed) }
                        .disabled(isBusy)
                }
                .font(.system(size: 22, weight: .semibold))
            }

            content
        }
        .padding(.horizontal, 70)
        .padding(.vertical, 50)
        // Opaque, so the calendar doesn't show through behind the posters.
        .background(Color.black.ignoresSafeArea())
        .onAppear { load() }
        // Play/Pause on the remote adds the selection from anywhere in the grid.
        .onPlayPauseCommand {
            if !toAdd.isEmpty && !isBusy { addSelected() }
        }
        .onExitCommand { if !isBusy { onClose(changed) } }
        .alert(
            L10n.format("calendar_suggest_remove_confirm", fallback: "Remove %d titles from your library?", toRemove.count),
            isPresented: $confirmingRemove
        ) {
            Button(L10n.string("calendar_suggest_remove_action", fallback: "Remove"), role: .destructive) {
                removeSelected()
            }
            Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) {}
        }
        .onDisappear { loadTask?.cancel() }
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
                LazyVGrid(columns: columns, spacing: 34) {
                    ForEach(results) { result in
                        CalendarSuggestionCell(
                            result: result,
                            isSelected: selected.contains(result.key),
                            inLibrary: library[result.key] != nil,
                            showsDetailInLibrary: list.isLibraryList,
                            accent: accent,
                            onSelect: { toggleSelection(result) },
                            onHold: { holdAction(result) }
                        )
                        // Every title stays focusable, also ones already in the
                        // library (to remove them) or without ids (to see why).
                        .disabled(isBusy)
                    }
                }
                .padding(20)
            }
            .scrollClipDisabledIfAvailable()
        }
    }

    private func pick(_ option: CalendarSuggestionList) {
        guard option != list else { return }
        list = option
        load()
    }

    private func toggleSelection(_ result: CalendarSuggestionItem) {
        guard result.isAddable || library[result.key] != nil else { return }
        if selected.contains(result.key) {
            selected.remove(result.key)
        } else {
            selected.insert(result.key)
        }
    }

    private func holdAction(_ result: CalendarSuggestionItem) {
        guard !isBusy else { return }
        if library[result.key] != nil {
            remove([result.key])
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
                    found = CalendarSuggestions.libraryItems(
                        library: library, nextDates: nextDates, skipped: skipped, today: CalendarDay(date: Date())
                    )
                } else if list == .animeToday {
                    // Exact broadcast times from AniList, ids from arm / Simkl.
                    found = try await CalendarAnimeToday.load()
                } else {
                    found = try await client.list(request.path, query: request.query, pages: CalendarSuggestions.pages)
                        .map { CalendarSuggestionItem(tmdb: $0, kind: list.kind) }
                }
                guard !Task.isCancelled else { return }
                results = found
                isLoading = false
                if found.isEmpty {
                    errorText = list.isLibraryList
                        ? L10n.string("calendar_suggest_library_empty", fallback: "Your library has nothing the calendar follows.")
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
        let client = CalendarLibrarySource.makeClient()
        Task {
            let added = await CalendarLibraryWriter.add(items, client: client)
            for (key, item) in added { library[key] = item }
            selected.subtract(added.keys)
            changed += added.count
            isBusy = false
        }
    }

    private func remove(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        isBusy = true
        let current = library
        Task {
            let removed = await CalendarLibraryWriter.remove(keys, items: current)
            for key in removed { library[key] = nil }
            // "In calendar" only lists library titles: drop the removed ones.
            if list.isLibraryList { results.removeAll { removed.contains($0.key) } }
            selected.subtract(removed)
            changed += removed.count
            isBusy = false
        }
    }
}

/// A poster that selects on click and runs `onHold` after a half-second hold.
private struct CalendarSuggestionCell: View {
    let result: CalendarSuggestionItem
    let isSelected: Bool
    let inLibrary: Bool
    var showsDetailInLibrary = false
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
            CalendarSuggestionCard(result: result, isSelected: isSelected, inLibrary: inLibrary,
                                   showsDetailInLibrary: showsDetailInLibrary, accent: accent)
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
    let result: CalendarSuggestionItem
    let isSelected: Bool
    let inLibrary: Bool
    var showsDetailInLibrary = false
    let accent: Color

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
                .frame(width: 190, height: 285)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Dim what can't be added; in "In calendar" everything is in the
                // library, so nothing is dimmed and only selection is marked.
                .opacity(showsDetailInLibrary ? 1 : (inLibrary || !result.isAddable ? 0.45 : 1))

                if isSelected || (inLibrary && !showsDetailInLibrary) {
                    // Selected library title = marked for removal.
                    Image(systemName: isSelected && inLibrary ? "minus.circle.fill"
                          : (inLibrary ? "checkmark.circle" : "checkmark.circle.fill"))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(isSelected && inLibrary ? .red : (inLibrary ? .white.opacity(0.8) : accent))
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .padding(10)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isFocused ? Color.white : (isSelected ? (inLibrary ? Color.red : accent) : Color.clear),
                        lineWidth: isFocused || isSelected ? 4 : 0
                    )
            )
            Text(result.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(width: 190, alignment: .leading)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.6))
        }
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var subtitle: String {
        if inLibrary {
            // "In calendar" shows the next date instead.
            if showsDetailInLibrary, let detail = result.detail { return detail }
            return L10n.string("calendar_suggest_in_library", fallback: "In library")
        }
        if !result.isAddable { return L10n.string("calendar_suggest_no_ids", fallback: "No TMDB or IMDb id") }
        return result.detail ?? result.year.map(String.init) ?? ""
    }
}

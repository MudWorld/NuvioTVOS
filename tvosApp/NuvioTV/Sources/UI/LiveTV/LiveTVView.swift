//
//  LiveTVView.swift
//  NuvioTV
//
//  Live TV tab: favorites first, then one row per M3U `group-title`.
//  "Select" mode (or a long press) marks channels as favorites or hides
//  them; hidden channels only show under the "Hidden" filter. Search
//  filters by channel name. Playlists are managed in Settings → Integrations.
//

import SwiftUI

private enum LiveTVFilter: Hashable {
    case all
    case favorites
    case hidden
    case group(String)
}

struct LiveTVView: View {
    let onPlay: (LiveTVChannel) -> Void

    @ObservedObject private var store = LiveTVStore.shared
    @State private var filter: LiveTVFilter = .all
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var actionChannel: LiveTVChannel?

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if store.channels.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 40) {
                    header
                    toolbar
                    filterChips
                    content
                }
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .confirmationDialog(
                actionChannel?.name ?? "",
                isPresented: Binding(get: { actionChannel != nil }, set: { if !$0 { actionChannel = nil } }),
                titleVisibility: .visible,
                presenting: actionChannel
            ) { channel in
                channelActions(channel)
                Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) {}
            }
            .onChange(of: store.favoriteIDs) { _, favorites in
                if filter == .favorites, favorites.isEmpty { filter = .all }
            }
            .onChange(of: store.hiddenIDs) { _, hidden in
                if filter == .hidden, hidden.isEmpty { filter = .all }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("tvos_livetv_title", fallback: "Live TV"))
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.white)
            Text(isSelecting
                ? L10n.string("tvos_livetv_select_hint", fallback: "Choose a channel to add it to favorites or hide it")
                : L10n.format(
                    "tvos_livetv_summary",
                    fallback: "%@ channels in %@ groups",
                    String(store.channels.count - store.hiddenIDs.count),
                    String(store.groups.count)
                ))
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(isSelecting ? Color.yellow : Color.white.opacity(0.6))
        }
        .padding(.horizontal, 60)
    }

    private var toolbar: some View {
        HStack(spacing: 20) {
            LiveTVSearchField(text: $searchText)
            LiveTVToolbarButton(
                title: isSelecting
                    ? L10n.string("tvos_livetv_done", fallback: "Done")
                    : L10n.string("tvos_livetv_select", fallback: "Select"),
                systemImage: isSelecting ? "checkmark.circle.fill" : "checkmark.circle",
                isActive: isSelecting
            ) {
                isSelecting.toggle()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
        .focusSection()
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                LiveTVGroupChip(title: L10n.string("tvos_livetv_all", fallback: "All"), isSelected: filter == .all) {
                    filter = .all
                }
                if !store.favoriteIDs.isEmpty {
                    LiveTVGroupChip(
                        title: "★ " + L10n.string("tvos_livetv_favorites", fallback: "Favorites"),
                        isSelected: filter == .favorites
                    ) { filter = filter == .favorites ? .all : .favorites }
                }
                ForEach(store.groups, id: \.name) { group in
                    LiveTVGroupChip(title: group.name, isSelected: filter == .group(group.name)) {
                        filter = filter == .group(group.name) ? .all : .group(group.name)
                    }
                }
                if !store.hiddenIDs.isEmpty {
                    LiveTVGroupChip(
                        title: L10n.format("tvos_livetv_hidden_count", fallback: "Hidden (%@)", String(store.hiddenChannels.count)),
                        isSelected: filter == .hidden
                    ) { filter = filter == .hidden ? .all : .hidden }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    @ViewBuilder
    private var content: some View {
        if !trimmedSearch.isEmpty {
            let pool = filter == .hidden ? store.hiddenChannels : store.channels.filter { !store.isHidden($0) }
            let results = pool.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
            if results.isEmpty {
                message(L10n.format("tvos_livetv_no_results", fallback: "No channels found for “%@”", trimmedSearch))
            } else {
                gridSection(
                    title: L10n.format("tvos_livetv_results", fallback: "Results for “%@”", trimmedSearch),
                    channels: results
                )
            }
        } else {
            switch filter {
            case .all:
                if !store.favoriteChannels.isEmpty {
                    row(title: "★ " + L10n.string("tvos_livetv_favorites", fallback: "Favorites"), channels: store.favoriteChannels)
                }
                if !store.recentChannels.isEmpty {
                    row(title: L10n.string("tvos_livetv_recent", fallback: "Recently watched"), channels: store.recentChannels)
                }
                ForEach(store.groups, id: \.name) { group in
                    row(title: group.name, channels: group.channels)
                }
            case .favorites:
                gridSection(title: "★ " + L10n.string("tvos_livetv_favorites", fallback: "Favorites"), channels: store.favoriteChannels)
            case .hidden:
                gridSection(title: L10n.string("tvos_livetv_hidden", fallback: "Hidden channels"), channels: store.hiddenChannels)
            case .group(let name):
                gridSection(title: name, channels: store.groups.first { $0.name == name }?.channels ?? [])
            }
        }
    }

    private func row(title: String, channels: [LiveTVChannel]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(title, count: channels.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 36) {
                    ForEach(channels) { card($0) }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private func gridSection(title: String, channels: [LiveTVChannel]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(title, count: channels.count)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(280), spacing: 36), count: 5), alignment: .leading, spacing: 40) {
                ForEach(channels) { card($0) }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 20)
        }
        .focusSection()
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title)  ·  \(count)")
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 60)
    }

    private func card(_ channel: LiveTVChannel) -> some View {
        LiveTVChannelCard(
            channel: channel,
            isFavorite: store.isFavorite(channel),
            isHidden: store.isHidden(channel),
            isSelecting: isSelecting
        ) {
            if isSelecting {
                actionChannel = channel
            } else {
                play(channel)
            }
        }
        .contextMenu { channelActions(channel) }
    }

    @ViewBuilder
    private func channelActions(_ channel: LiveTVChannel) -> some View {
        Button {
            store.toggleFavorite(channel)
        } label: {
            Label(
                store.isFavorite(channel)
                    ? L10n.string("tvos_livetv_unfavorite", fallback: "Remove from favorites")
                    : L10n.string("tvos_livetv_favorite", fallback: "Add to favorites"),
                systemImage: store.isFavorite(channel) ? "star.slash" : "star"
            )
        }
        Button {
            store.toggleHidden(channel)
        } label: {
            Label(
                store.isHidden(channel)
                    ? L10n.string("tvos_livetv_unhide", fallback: "Show channel again")
                    : L10n.string("tvos_livetv_hide", fallback: "Hide channel"),
                systemImage: store.isHidden(channel) ? "eye" : "eye.slash"
            )
        }
        Button {
            play(channel)
        } label: {
            Label(L10n.string("tvos_livetv_play", fallback: "Play"), systemImage: "play.fill")
        }
    }

    private func play(_ channel: LiveTVChannel) {
        store.markWatched(channel)
        onPlay(channel)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .medium))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "tv")
                .font(.system(size: 72, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Text(L10n.string("tvos_livetv_empty_title", fallback: "No Live TV channels yet"))
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
            Text(L10n.string(
                "tvos_livetv_empty_detail",
                fallback: "Add an M3U playlist under Settings → Integrations → Live TV."
            ))
            .font(.system(size: 22, weight: .medium))
            .foregroundColor(.white.opacity(0.6))
            .multilineTextAlignment(.center)
            if !store.refreshingURLs.isEmpty {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Components

private struct LiveTVChannelCard: View {
    let channel: LiveTVChannel
    let isFavorite: Bool
    let isHidden: Bool
    let isSelecting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                        logo
                    }
                    .opacity(isHidden ? 0.45 : 1)

                    HStack(spacing: 6) {
                        if isFavorite { badge("star.fill", color: .yellow) }
                        if isHidden { badge("eye.slash.fill", color: .white) }
                        if isSelecting && !isFavorite && !isHidden { badge("circle", color: .white.opacity(0.8)) }
                    }
                    .padding(10)
                }
                .frame(width: 280, height: 158)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isSelecting ? Color.yellow.opacity(0.7) : Color.clear, lineWidth: 2)
                )

                Text(channel.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(width: 270)
                    .padding(.bottom, 10)
            }
        }
        .buttonStyle(.card)
    }

    @ViewBuilder
    private var logo: some View {
        if let logo = channel.logoURL, let url = URL(string: logo) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(22)
                } else {
                    initials
                }
            }
        } else {
            initials
        }
    }

    private var initials: some View {
        Text(String(channel.name.prefix(3)).uppercased())
            .font(.system(size: 40, weight: .heavy))
            .foregroundColor(.white.opacity(0.75))
    }

    private func badge(_ systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(color)
            .padding(8)
            .background(Circle().fill(Color.black.opacity(0.6)))
    }
}

private struct LiveTVSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            TextField(L10n.string("tvos_livetv_search", fallback: "Search channels"), text: $text)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 520)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LiveTVToolbarButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(isFocused ? Color.black : (isActive ? Color.yellow : Color.white))
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(Capsule().fill(isFocused ? Color.white : Color.white.opacity(isActive ? 0.22 : 0.1)))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}

private struct LiveTVGroupChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isFocused ? Color.black : Color.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(isFocused ? Color.white : (isSelected ? Color.white.opacity(0.32) : Color.white.opacity(0.1)))
                )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}

extension LiveTVChannel {
    /// Player metadata: the `iptv:` id and `iptv` type make the player treat
    /// the stream as live (no resume, no progress sync).
    var playbackMeta: NuvioMeta {
        NuvioMeta(id: id, name: name, posterUrl: logoURL, logoUrl: logoURL, type: "iptv", genres: [group])
    }
}

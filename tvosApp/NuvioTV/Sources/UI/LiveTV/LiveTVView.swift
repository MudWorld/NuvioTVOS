//
//  LiveTVView.swift
//  NuvioTV
//
//  Live TV tab: one row per M3U `group-title`, channel tiles that start
//  playback directly. Playlists are managed in Settings → Integrations.
//

import SwiftUI

struct LiveTVView: View {
    let onPlay: (LiveTVChannel) -> Void

    @ObservedObject private var store = LiveTVStore.shared
    @State private var selectedGroup: String?

    private var visibleGroups: [(name: String, channels: [LiveTVChannel])] {
        let all = store.groups
        guard let selectedGroup else { return all }
        return all.filter { $0.name == selectedGroup }
    }

    var body: some View {
        if store.channels.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 44) {
                    header
                    groupFilter
                    ForEach(visibleGroups, id: \.name) { group in
                        LiveTVGroupRow(name: group.name, channels: group.channels, onPlay: onPlay)
                    }
                }
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("tvos_livetv_title", fallback: "Live TV"))
                .font(.system(size: 44, weight: .bold))
                .foregroundColor(.white)
            Text(L10n.format(
                "tvos_livetv_summary",
                fallback: "%@ channels in %@ groups",
                String(store.channels.count),
                String(store.groups.count)
            ))
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 60)
    }

    /// Group chips to jump to one category ("Sport", "News", ...).
    private var groupFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                LiveTVGroupChip(title: L10n.string("tvos_livetv_all", fallback: "All"), isSelected: selectedGroup == nil) {
                    selectedGroup = nil
                }
                ForEach(store.groups, id: \.name) { group in
                    LiveTVGroupChip(title: group.name, isSelected: selectedGroup == group.name) {
                        selectedGroup = selectedGroup == group.name ? nil : group.name
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .focusSection()
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

private struct LiveTVGroupRow: View {
    let name: String
    let channels: [LiveTVChannel]
    let onPlay: (LiveTVChannel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(name)  ·  \(channels.count)")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 36) {
                    ForEach(channels) { channel in
                        LiveTVChannelCard(channel: channel) { onPlay(channel) }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

private struct LiveTVChannelCard: View {
    let channel: LiveTVChannel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
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
                .frame(width: 280, height: 158)

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

    private var initials: some View {
        Text(String(channel.name.prefix(3)).uppercased())
            .font(.system(size: 40, weight: .heavy))
            .foregroundColor(.white.opacity(0.75))
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
                .foregroundColor(isFocused ? .black : .white)
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

import SwiftUI
import UIKit

struct AppNoticeBanner: View {
    private enum Action: Hashable {
        case viewRelease
        case dismiss
        case skip
    }

    let notice: AppNotice
    let currentVersion: String
    let accentColor: Color
    let focusRequestGeneration: UInt
    let isDetailsPresented: Bool
    let onShowDetails: () -> Void
    let onDismiss: () -> Void
    let onSkip: () -> Void

    @FocusState private var focusedAction: Action?
    @State private var appliedFocusRequestGeneration: UInt?

    private var title: String {
        switch notice {
        case .release(let release):
            L10n.string("release_update_available_title", fallback: "NuvioTV \(release.displayVersion) is available")
        case .announcement(let announcement):
            announcement.title
        }
    }

    private var isAnnouncement: Bool {
        if case .announcement = notice { return true }
        return false
    }

    private var message: String {
        switch notice {
        case .release:
            L10n.string("release_update_available_subtitle", fallback: "You’re using version \(currentVersion). View the release or scan its QR code.")
        case .announcement(let announcement):
            announcement.message
        }
    }

    private var primaryTitle: String {
        switch notice {
        case .release:
            L10n.string("release_update_view_release", fallback: "View Release")
        case .announcement:
            L10n.string("announcement_read_message", fallback: "Read Message")
        }
    }

    private var primarySystemImage: String {
        switch notice {
        case .release: "qrcode"
        case .announcement: "doc.text"
        }
    }

    private var primaryAccessibilityIdentifier: String {
        switch notice {
        case .release: "release-notice-view-release"
        case .announcement: "announcement-notice-view-details"
        }
    }

    private var dismissAccessibilityIdentifier: String {
        switch notice {
        case .release: "release-notice-dismiss"
        case .announcement: "announcement-notice-dismiss"
        }
    }

    private var skipTitle: String {
        switch notice {
        case .release:
            L10n.string("release_update_skip_version", fallback: "Skip This Version")
        case .announcement:
            L10n.string("announcement_dont_show_again", fallback: "Don't Show Again")
        }
    }

    private var skipAccessibilityIdentifier: String {
        switch notice {
        case .release: "release-notice-skip"
        case .announcement: "announcement-notice-skip"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(isAnnouncement ? 2 : nil)
                        .truncationMode(.tail)
                    Text(message)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(isAnnouncement ? 3 : nil)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: !isAnnouncement)
                }
            }

            HStack(spacing: 12) {
                actionButton(
                    primaryTitle,
                    systemImage: primarySystemImage,
                    focus: .viewRelease,
                    accessibilityIdentifier: primaryAccessibilityIdentifier,
                    action: onShowDetails
                )
                Spacer(minLength: 8)
                actionButton(
                    L10n.string("action_dismiss", fallback: "Dismiss"),
                    focus: .dismiss,
                    accessibilityIdentifier: dismissAccessibilityIdentifier,
                    action: onDismiss
                )
                actionButton(
                    skipTitle,
                    focus: .skip,
                    accessibilityIdentifier: skipAccessibilityIdentifier,
                    action: onSkip
                )
            }
        }
        .padding(24)
        .frame(width: 860, alignment: .leading)
        .loginGlassPanel()
        .accessibilityElement(children: .contain)
        .focusSection()
        .defaultFocus($focusedAction, .viewRelease, priority: .userInitiated)
        .task(id: focusRequestIdentity) {
            await requestViewReleaseFocusIfNeeded()
        }
        .onChange(of: isDetailsPresented) { _, presented in
            if presented { focusedAction = nil }
        }
    }

    private var focusRequestIdentity: String {
        "\(focusRequestGeneration)-\(isDetailsPresented)"
    }

    private func requestViewReleaseFocusIfNeeded() async {
        guard !isDetailsPresented else { return }
        await Task.yield()
        guard !Task.isCancelled, !isDetailsPresented else { return }

        let isNewFocusRequest = appliedFocusRequestGeneration != focusRequestGeneration
        appliedFocusRequestGeneration = focusRequestGeneration
        if isNewFocusRequest {
            // A modal can leave SwiftUI's focus binding stale after UIKit has
            // moved focus. Reset only at a new lifecycle request, then request
            // the primary action again before the retry window starts.
            focusedAction = nil
            await Task.yield()
            guard !Task.isCancelled, !isDetailsPresented else { return }
            focusedAction = .viewRelease
        }

        requestViewReleaseFocusIfNil()

        for delay in [60_000_000, 180_000_000, 350_000_000] {
            try? await Task.sleep(nanoseconds: UInt64(delay))
            guard !Task.isCancelled, !isDetailsPresented else { return }
            requestViewReleaseFocusIfNil()
        }
    }

    private func requestViewReleaseFocusIfNil() {
        guard focusedAction == nil, !isDetailsPresented else { return }
        focusedAction = .viewRelease
    }

    private func actionButton(
        _ title: String,
        systemImage: String? = nil,
        focus: Action,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .controlSize(.regular)
        .focused($focusedAction, equals: focus)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Kept as a compatibility wrapper for callers that present release notices directly.
struct ReleaseUpdateNoticeBanner: View {
    let release: ReleaseUpdateMetadata
    let currentVersion: String
    let accentColor: Color
    let focusRequestGeneration: UInt
    let isQRPresented: Bool
    let onShowQR: () -> Void
    let onDismiss: () -> Void
    let onSkip: () -> Void

    var body: some View {
        AppNoticeBanner(
            notice: .release(release),
            currentVersion: currentVersion,
            accentColor: accentColor,
            focusRequestGeneration: focusRequestGeneration,
            isDetailsPresented: isQRPresented,
            onShowDetails: onShowQR,
            onDismiss: onDismiss,
            onSkip: onSkip
        )
    }
}

struct ReleaseQRCodeSheet: View {
    let release: ReleaseUpdateMetadata

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            Text(L10n.string("release_update_install_title", fallback: "Get NuvioTV \(release.displayVersion)"))
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.white)

            Text(L10n.string(
                "release_update_sideload_explanation",
                fallback: "Scan this code with your phone to open the release page. Download the tvOS build and install it with your sideloading tool."
            ))
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(.white.opacity(0.68))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if let image = QRCode.image(from: release.releaseURL.absoluteString, scale: 10) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 300, height: 300)
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel(L10n.string("release_update_qr_accessibility", fallback: "QR code for the NuvioTV release page"))
            }

            Text(release.releaseURL.absoluteString)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(1)

            ProviderLoginGlassButton(
                title: L10n.string("tvos_settings_done", fallback: "Done"),
                isPrimary: true
            ) { dismiss() }
            .accessibilityIdentifier("release-qr-done")
        }
        .frame(width: 960)
        .padding(.horizontal, 88)
        .padding(.vertical, 64)
        .onExitCommand { dismiss() }
    }
}

struct AppNoticeDetailsSheet: View {
    let notice: AppNotice

    @ViewBuilder
    var body: some View {
        switch notice {
        case .release(let release):
            ReleaseQRCodeSheet(release: release)
        case .announcement(let announcement):
            AnnouncementDetailsSheet(announcement: announcement)
        }
    }
}

private struct AnnouncementDetailsSheet: View {
    let announcement: Announcement

    @Environment(\.dismiss) private var dismiss
    @FocusState private var doneFocused: Bool
    @FocusState private var focusedParagraphID: String?

    private var titleParagraphs: [String] { splitLines(announcement.title) }
    private var messageParagraphs: [String] { splitLines(announcement.message) }

    var body: some View {
        VStack(spacing: 28) {
            ScrollView(.vertical) {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        ForEach(Array(titleParagraphs.enumerated()), id: \.offset) { index, paragraph in
                            announcementParagraph(
                                paragraph,
                                id: "announcement-details-title-paragraph-\(index)",
                                font: .system(size: 42, weight: .regular),
                                color: .white
                            )
                        }
                    }

                    VStack(spacing: 4) {
                        ForEach(Array(messageParagraphs.enumerated()), id: \.offset) { index, paragraph in
                            announcementParagraph(
                                paragraph,
                                id: "announcement-details-message-paragraph-\(index)",
                                font: .system(size: 23, weight: .medium),
                                color: .white.opacity(0.68)
                            )
                        }
                    }

                    if let linkURL = announcement.linkURL {
                        if let image = QRCode.image(from: linkURL.absoluteString, scale: 10) {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 300, height: 300)
                                .padding(16)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .accessibilityLabel(L10n.string("announcement_qr_accessibility", fallback: "QR code for the announcement link"))
                                .accessibilityIdentifier("announcement-details-qr-code")
                        }

                        Text(linkURL.absoluteString)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 620)
            .accessibilityIdentifier("announcement-details-scroll")
            .focusSection()

            ProviderLoginGlassButton(
                title: L10n.string("tvos_settings_done", fallback: "Done"),
                isPrimary: true,
                focusBinding: $doneFocused
            ) { dismiss() }
            .accessibilityIdentifier("announcement-details-done")
        }
        .frame(width: 960)
        .padding(.horizontal, 88)
        .padding(.vertical, 64)
        .onExitCommand { dismiss() }
        .defaultFocus($doneFocused, true, priority: .automatic)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            doneFocused = true
        }
    }

    @ViewBuilder
    private func announcementParagraph(
        _ text: String,
        id: String,
        font: Font,
        color: Color
    ) -> some View {
        if text.isEmpty {
            Text(" ")
                .font(font)
                .frame(height: 28)
                .accessibilityIdentifier(id)
                .accessibilityLabel("")
        } else {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(id)
                .focusable()
                .focused($focusedParagraphID, equals: id)
                .focusEffectDisabledIfAvailable()
        }
    }

    private func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
    }
}

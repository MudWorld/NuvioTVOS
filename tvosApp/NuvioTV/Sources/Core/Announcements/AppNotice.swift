import Foundation

enum AppNotice: Equatable, Identifiable {
    case release(ReleaseUpdateMetadata)
    case announcement(Announcement)

    var id: String {
        switch self {
        case .release(let release): "release:\(release.id)"
        case .announcement(let announcement): "announcement:\(announcement.id)"
        }
    }

    static func select(
        release: ReleaseUpdateMetadata?,
        releaseIsAvailable: Bool,
        announcementsEnabled: Bool,
        activeAnnouncements: [Announcement],
        skippedAnnouncementIDs: Set<String>,
        dismissedAnnouncementIDs: Set<String>
    ) -> AppNotice? {
        if releaseIsAvailable, let release {
            return .release(release)
        }
        guard announcementsEnabled else { return nil }
        guard let announcement = activeAnnouncements.first(where: {
            !skippedAnnouncementIDs.contains($0.id) && !dismissedAnnouncementIDs.contains($0.id)
        }) else {
            return nil
        }
        return .announcement(announcement)
    }
}

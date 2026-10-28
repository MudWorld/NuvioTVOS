import XCTest
@testable import NuvioTV

final class TraktContinueWatchingOwnershipTests: XCTestCase {
    private var profileA = ""
    private var profileB = ""
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousContinueWatchingProfileID: String?

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousContinueWatchingProfileID = ContinueWatchingStore.activeProfileId
        profileA = "trakt-cw-a-\(UUID().uuidString)"
        profileB = "trakt-cw-b-\(UUID().uuidString)"
        activate(profileA)
    }

    override func tearDown() async throws {
        await MainActor.run {
            for profileID in [profileA, profileB] {
                activate(profileID)
                TraktProgressService.forgetLocalPlayback(meta: checkpointMeta, notify: false)
                TraktProgressService.forgetLocalPlayback(meta: remoteMeta, notify: false)
                UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
            }
            ContinueWatchingStore.setActiveProfile(previousContinueWatchingProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
        }
        try await super.tearDown()
    }

    @MainActor
    func testOldProfileResultsCannotMergeNewProfileCheckpointsOrPublishSnapshot() {
        let context = capture()
        activate(profileB)
        seedCheckpoint()

        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        )

        XCTAssertNil(result)
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testSettingsProfileSwitchAloneRejectsResultsBeforeCheckpointReconciliation() {
        let context = capture()
        seedCheckpoint()
        ProfileSettings.setActiveProfile(profileB, isPrimary: false)

        XCTAssertNil(TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        ))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testSourceSwitchRejectsDisplayedResultsBeforeCheckpointReconciliation() {
        let context = capture()
        seedCheckpoint()
        ProfileSettings.current.set(TraktWatchProgressSource.nuvioSync.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)

        XCTAssertNil(TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation(), item(meta: remoteMeta)], context: context
        ))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testCurrentProfileResultsStillMergeAndPublish() {
        seedCheckpoint()
        let remote = item(meta: remoteMeta)
        let result = TraktProgressService.finalizeContinueWatchingFetch([remote], context: capture())

        XCTAssertEqual(Set(result?.map { $0.meta.id } ?? []), Set([checkpointMeta.id, remoteMeta.id]))
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertEqual(current(remoteMeta)?.position, remote.position)
    }

    @MainActor
    func testReadOnlyOverrideReturnsProviderItemsWithoutMergingOrPublishing() {
        seedCheckpoint()
        ProfileSettings.current.set(TraktWatchProgressSource.nuvioSync.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)
        let remote = item(meta: remoteMeta)
        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [remote], context: capture(updateDisplayedSnapshot: false)
        )

        XCTAssertEqual(result?.map { $0.meta.id }, [remoteMeta.id])
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testCalendarFetchMergesCheckpointsWithoutReplacingHomeSnapshot() {
        seedCheckpoint()
        let homeMeta = NuvioMeta(id: "cw-home-snapshot-\(profileA)", name: "Home", type: "movie")
        let calendarMeta = NuvioMeta(id: "cw-calendar-result-\(profileA)", name: "Calendar", type: "movie")
        _ = TraktProgressService.finalizeContinueWatchingFetch(
            [item(meta: homeMeta)],
            context: capture()
        )

        let calendarItems = TraktProgressService.finalizeContinueWatchingFetch(
            [item(meta: calendarMeta)],
            context: capture(replaceSnapshot: false)
        )

        XCTAssertEqual(
            Set(calendarItems?.map(\.meta.id) ?? []),
            Set([checkpointMeta.id, calendarMeta.id])
        )
        XCTAssertEqual(current(homeMeta)?.meta.id, homeMeta.id)
        XCTAssertEqual(current(calendarMeta)?.meta.id, calendarMeta.id)
    }

    @MainActor
    func testCalendarConfirmationUpdatesResumeCheckpoint() {
        seedCheckpoint()
        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [remoteConfirmation()], context: capture(replaceSnapshot: false)
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(current(checkpointMeta)?.position, 800)
    }

    @MainActor
    func testCancelledResultCannotReconcileOrPublish() async {
        seedCheckpoint()
        let context = capture()
        let items = [remoteConfirmation(), item(meta: remoteMeta)]
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return TraktProgressService.finalizeContinueWatchingFetch(items, context: context)
        }
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertEqual(current(checkpointMeta)?.position, 300)
        XCTAssertNil(current(remoteMeta))
    }

    @MainActor
    func testHomeMetadataResolutionBackfillsBeyondTheFirstTwentyCandidates() async {
        let seeds = Array(0..<TraktProgressService.maxHomeContinueWatchingSeeds)
        let resolved = await TraktProgressService.resolveContinueWatchingMetadata(
            from: seeds,
            candidateLimit: TraktProgressService.maxHomeContinueWatchingSeeds
        ) { seed in
            self.item(
                meta: NuvioMeta(id: "home-seed-\(seed)", name: "Seed \(seed)", type: "movie"),
                date: Date().addingTimeInterval(Double(-seed))
            )
        }

        let selected = TraktProgressService.selectContinueWatchingItemsForDisplay(
            resolved ?? [],
            predicate: { item in
                guard let seed = Int(item.meta.id.replacingOccurrences(of: "home-seed-", with: "")) else {
                    return false
                }
                return seed >= 16
            }
        )

        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(selected.map(\.meta.id), (16..<36).map { "home-seed-\($0)" })
    }

    @MainActor
    func testHomeMetadataResolutionNeverExceedsThirtySixCandidates() async {
        var resolvedSeeds: [Int] = []
        let resolved = await TraktProgressService.resolveContinueWatchingMetadata(
            from: Array(0..<100),
            candidateLimit: TraktProgressService.maxHomeContinueWatchingSeeds
        ) { seed in
            resolvedSeeds.append(seed)
            return self.item(
                meta: NuvioMeta(id: "bounded-seed-\(seed)", name: "Seed \(seed)", type: "movie"),
                date: Date().addingTimeInterval(Double(-seed))
            )
        }

        XCTAssertEqual(resolved?.count, 36)
        XCTAssertEqual(resolvedSeeds.sorted(), Array(0..<36))
    }

    @MainActor
    func testBackfilledHomeItemsRemainAvailableForDetailsResumeLookup() {
        let now = Date()
        let items = (0..<36).map { seed in
            item(
                meta: NuvioMeta(id: "resume-seed-\(seed)", name: "Seed \(seed)", type: "movie"),
                date: now.addingTimeInterval(Double(-seed))
            )
        }
        let displayed = TraktProgressService.finalizeContinueWatchingFetch(
            items,
            context: capture(),
            displayPredicate: { item in
                guard let seed = Int(item.meta.id.replacingOccurrences(of: "resume-seed-", with: "")) else {
                    return false
                }
                return seed >= 16
            },
            displaySort: { $0 }
        ) ?? []

        XCTAssertEqual(displayed.map(\.meta.id), (16..<36).map { "resume-seed-\($0)" })
        for item in displayed {
            XCTAssertEqual(
                TraktProgressService.currentContinueWatchingItem(for: item.meta, source: .trakt)?.meta.id,
                item.meta.id
            )
        }
    }

    @MainActor
    func testHomeEligibilityAndTitleDedupApplyAfterCheckpointMergeAndBeforeCap() {
        seedCheckpoint()
        let now = Date()
        let visibleItems = (0..<22).map { index in
            item(
                meta: NuvioMeta(id: "home-visible-\(index)", name: "Visible \(index)", type: "movie"),
                date: now.addingTimeInterval(Double(-index))
            )
        }
        let olderDuplicate = item(
            meta: visibleItems[0].meta,
            date: now.addingTimeInterval(-100)
        )
        let result = TraktProgressService.finalizeContinueWatchingFetch(
            [olderDuplicate] + visibleItems,
            context: capture(),
            displayPredicate: { $0.meta.id != self.checkpointMeta.id },
            displaySort: { $0 }
        )

        XCTAssertEqual(result?.count, 20)
        XCTAssertEqual(result?.map(\.meta.id), (0..<20).map { "home-visible-\($0)" })
        XCTAssertFalse(result?.contains { $0.meta.id == checkpointMeta.id } ?? true)
    }

    @MainActor
    func testHomeSelectionKeepsUnfilteredSharedSnapshotCappedAtTwenty() {
        let now = Date()
        let hiddenItems = (0..<4).map { index in
            item(
                meta: NuvioMeta(id: "snapshot-hidden-\(index)", name: "Hidden \(index)", type: "movie"),
                date: now.addingTimeInterval(Double(100 - index))
            )
        }
        let visibleItems = (0..<20).map { index in
            item(
                meta: NuvioMeta(id: "snapshot-visible-\(index)", name: "Visible \(index)", type: "movie"),
                date: now.addingTimeInterval(Double(-index))
            )
        }

        let result = TraktProgressService.finalizeContinueWatchingFetch(
            hiddenItems + visibleItems,
            context: capture(),
            displayPredicate: { $0.meta.id.hasPrefix("snapshot-visible-") }
        )
        let sharedSnapshot = TraktProgressService.currentContinueWatchingItems(source: .trakt)

        XCTAssertEqual(result?.count, 20)
        XCTAssertEqual(sharedSnapshot?.count, 20)
        XCTAssertTrue(sharedSnapshot?.contains { $0.meta.id == "snapshot-hidden-0" } ?? false)
        XCTAssertFalse(result?.contains { $0.meta.id == "snapshot-hidden-0" } ?? true)
    }

    @MainActor
    func testSeparateUpcomingSelectionKeepsUpcomingInTheCombinedTwentyItemPool() {
        let now = Date()
        let releasedItems = (0..<20).map { index in
            item(
                meta: NuvioMeta(id: "released-\(index)", name: "Released \(index)", type: "movie"),
                date: now.addingTimeInterval(Double(-100 - index))
            )
        }
        let upcoming = ContinueWatchingItem(
            meta: NuvioMeta(id: "upcoming-show", name: "Upcoming", type: "series"),
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: now,
            season: 1,
            episode: 2,
            released: "2099-01-01",
            isUpNext: true
        )
        let selected = TraktProgressService.selectContinueWatchingItemsForDisplay(
            releasedItems + [upcoming],
            predicate: { _ in true },
            sort: {
                TraktProgressService.sortContinueWatchingForDisplaySelection(
                    $0,
                    preference: "Separate Upcoming Row"
                )
            }
        )

        XCTAssertEqual(selected.count, 20)
        XCTAssertTrue(selected.contains { $0.meta.id == upcoming.meta.id })
    }

    @MainActor
    private func capture(
        updateDisplayedSnapshot: Bool = true,
        replaceSnapshot: Bool = true
    ) -> TraktProgressService.ContinueWatchingFetchContext {
        TraktProgressService.ContinueWatchingFetchContext(source: .trakt,
                                                       updateDisplayedSnapshot: updateDisplayedSnapshot,
                                                       replaceSnapshot: replaceSnapshot)
    }

    private var checkpointMeta: NuvioMeta { NuvioMeta(id: "cw-checkpoint-\(profileA)", name: "Local", type: "movie") }
    private var remoteMeta: NuvioMeta { NuvioMeta(id: "cw-remote-\(profileA)", name: "Remote", type: "movie") }

    private func activate(_ profileID: String) {
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        ContinueWatchingStore.setActiveProfile(profileID)
        ProfileSettings.current.set(TraktWatchProgressSource.trakt.rawValue,
                                    forKey: SettingsKey.traktWatchProgressSource)
    }

    @MainActor
    private func seedCheckpoint() {
        TraktProgressService.recordLocalPlayback(meta: checkpointMeta, position: 300, duration: 1000,
                                                season: nil, episode: nil, source: .trakt, notify: false)
    }

    private func item(meta: NuvioMeta, position: Double = 100, date: Date = Date()) -> ContinueWatchingItem {
        ContinueWatchingItem(meta: meta, streamUrl: "", position: position, duration: 1000,
                             lastWatchedAt: date, season: nil, episode: nil)
    }

    private func remoteConfirmation() -> ContinueWatchingItem {
        // If stale reconciliation runs, this newer/further row removes the
        // current profile's local checkpoint as server-confirmed progress.
        item(meta: checkpointMeta, position: 800, date: Date().addingTimeInterval(60))
    }

    @MainActor
    private func current(_ meta: NuvioMeta) -> ContinueWatchingItem? {
        TraktProgressService.currentContinueWatchingItem(for: meta, source: .trakt)
    }
}

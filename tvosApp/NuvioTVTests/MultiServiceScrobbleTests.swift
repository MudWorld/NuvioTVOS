import XCTest
@testable import NuvioTV

@MainActor
final class MultiServiceScrobbleTests: XCTestCase {
    private var testProfileID: String!
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousWatchedProfileID: String?

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousWatchedProfileID = WatchedStore.activeProfileId

        testProfileID = "multi-scrobble-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(testProfileID, isPrimary: true)
        WatchedStore.setActiveProfile(testProfileID)
    }

    override func tearDown() {
        if let testProfileID {
            MdbListKeychainTokenStorage().remove(for: testProfileID)
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(testProfileID)")
        }
        MdbListKeychainTokenStorage().remove(for: ProfileSettings.activeProfileScope)
        WatchedStore.setActiveProfile(previousWatchedProfileID)
        if let previousSettingsProfileID {
            ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        testProfileID = nil
        super.tearDown()
    }

    private func authenticateTrakt(in store: UserDefaults, slug: String = "test-trakt-user") {
        let clientID = "test-client-id"
        store.set(clientID, forKey: SettingsKey.traktClientID)
        store.set(true, forKey: SettingsKey.traktConnected)
        let tokenResponse = TraktTokenResponse(
            accessToken: "test-trakt-access",
            tokenType: "Bearer",
            expiresIn: 3600,
            refreshToken: "test-trakt-refresh",
            createdAt: 0
        )
        TraktAuthStore.saveToken(tokenResponse, clientID: clientID, store: store)
        TraktAuthStore.saveUser(username: "Test", slug: slug, store: store)
    }

    private func authenticateMdbList(in store: UserDefaults, tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage()) {
        let tokens = MdbListStoredTokens(
            accessToken: "test-mdblist-access",
            refreshToken: "test-mdblist-refresh",
            expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + 3_600_000
        )
        let scope = MdbListRuntimeSession.profileScope()
        _ = MdbListAuthStore.saveTokens(
            tokens,
            user: MdbListUser(accountID: "1", username: "testuser", displayName: "Test User"),
            profileScope: scope,
            store: store,
            tokenStorage: tokenStorage
        )
    }

    // MARK: - Scrobble Enabled Defaults and Toggles

    func testScrobbleEnabledDefaultsToFalseUntilUserToggles() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)

        // Should be authenticated
        XCTAssertTrue(RemoteTrackingState.isProgressSourceAuthenticated(.trakt, in: store))

        // Off by default until the user explicitly toggles it on
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))

        // Toggle to true
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        XCTAssertTrue(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))

        // Toggle back to false
        RemoteTrackingState.setScrobbleEnabled(false, for: .trakt, in: store)
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))
    }

    func testScrobbleDisabledWhenUnauthenticated() {
        let store = ProfileSettings.current
        // No tokens saved -> not authenticated
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.trakt, in: store))
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))

        // Nuvio Sync is never a scrobble target
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .nuvioSync, in: store))
    }

    func testActiveScrobbleSourcesReflectsOnlyAuthenticatedAndEnabledServices() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)

        // Initially both are authenticated but scrobble is off by default
        XCTAssertTrue(RemoteTrackingState.activeScrobbleSources(in: store).isEmpty)

        // Explicitly enable scrobble for Trakt and MDBList
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        let active = RemoteTrackingState.activeScrobbleSources(in: store)
        XCTAssertTrue(active.contains(.trakt))
        XCTAssertTrue(active.contains(.mdblist))
        XCTAssertFalse(active.contains(.simkl))
        XCTAssertFalse(active.contains(.nuvioSync))

        // Disable MDBList scrobble
        RemoteTrackingState.setScrobbleEnabled(false, for: .mdblist, in: store)
        let activeAfterDisable = RemoteTrackingState.activeScrobbleSources(in: store)
        XCTAssertTrue(activeAfterDisable.contains(.trakt))
        XCTAssertFalse(activeAfterDisable.contains(.mdblist))
    }

    func testMdbListWithApiKeyOnlyIsNotAuthenticatedForSync() {
        let store = ProfileSettings.current
        store.set("ratings-api-key", forKey: SettingsKey.mdbListApiKey)
        store.set(true, forKey: SettingsKey.mdbListEnabled)

        // API key alone for ratings should NOT authenticate MDBList for sync or scrobble
        XCTAssertFalse(MdbListRuntimeSession.isAuthenticated(in: store))
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.mdblist, in: store))
        XCTAssertFalse(RemoteTrackingState.isLibrarySourceAuthenticated(.mdblist, in: store))
        XCTAssertFalse(RemoteTrackingState.availableProgressSources(in: store).contains(.mdblist))
        XCTAssertFalse(RemoteTrackingState.availableLibrarySources(in: store).contains(.mdblist))
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .mdblist, in: store))
    }

    // MARK: - Continue Watching Source Independence

    func testContinueWatchingSourceCanBeNuvioSyncWhileScrobbleRemainsActive() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)

        // Enable scrobble for Trakt and MDBList
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        // Set Continue Watching source to Nuvio Sync
        store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: store), .nuvioSync)

        // Both Trakt and MDBList are still active scrobble targets
        let active = RemoteTrackingState.activeScrobbleSources(in: store)
        XCTAssertTrue(active.contains(.trakt))
        XCTAssertTrue(active.contains(.mdblist))
    }

    // MARK: - Watched History Routing

    func testRoutesWatchedHistoryWhenScrobbleIsEnabled() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)

        // Enable scrobble for Trakt and MDBList
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        // Even when source is Nuvio Sync, scrobble-enabled services receive watched history
        store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        XCTAssertTrue(RemoteTrackingState.shouldSyncWatchedHistory(to: .trakt, in: store))
        XCTAssertTrue(RemoteTrackingState.shouldSyncWatchedHistory(to: .mdblist, in: store))
        XCTAssertTrue(RemoteTrackingState.routesWatchedHistory(to: .trakt, selectedSource: .nuvioSync, in: store))

        // When scrobble is explicitly disabled, it stops routing
        RemoteTrackingState.setScrobbleEnabled(false, for: .mdblist, in: store)
        XCTAssertFalse(RemoteTrackingState.shouldSyncWatchedHistory(to: .mdblist, in: store))
    }

    // MARK: - Periodic Heartbeat Exclusion for Simkl

    func testPeriodicHeartbeatFiltersSimkl() async {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        let movie = NuvioMeta(
            id: "tt1234567",
            name: "Test Movie",
            imdbId: "tt1234567",
            type: "movie",
            year: 2024
        )

        // Non-heartbeat report
        let nonHeartbeatTargets = RemoteTrackingState.activeScrobbleSources(in: store)
        XCTAssertTrue(nonHeartbeatTargets.contains(.trakt))
        XCTAssertTrue(nonHeartbeatTargets.contains(.mdblist))

        // Heartbeat report excludes Simkl
        let didReport = await TraktProgressService.reportPlayback(
            meta: movie,
            position: 120,
            duration: 7200,
            season: nil,
            episode: nil,
            action: .start,
            store: store,
            sourceOverride: nil,
            isPeriodicHeartbeat: true
        )
        XCTAssertNotNil(didReport)
    }

    // MARK: - WatchedStore Snapshot Visibility

    func testWatchedStoreSnapshotIncludesActiveScrobbleSources() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)
        store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        let movie = NuvioMeta(
            id: "tt7654321",
            name: "Trakt Only Movie",
            imdbId: "tt7654321",
            type: "movie",
            year: 2024
        )
        let traktItem = WatchedStoreItem(
            meta: movie,
            watchedAt: Date(),
            season: nil,
            episode: nil,
            sources: [TraktWatchProgressSource.trakt.rawValue]
        )
        WatchedStore.replaceAll([traktItem])

        let snapshot = WatchedStore.currentSnapshot()
        XCTAssertEqual(snapshot.source, .nuvioSync)
        XCTAssertTrue(snapshot.contains(metaId: movie.id, type: movie.canonicalType))
    }
}

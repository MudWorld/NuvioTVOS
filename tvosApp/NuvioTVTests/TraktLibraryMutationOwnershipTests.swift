import XCTest
@testable import NuvioTV

private final class TraktLibraryNotificationProbe {
    var mutations = 0
    var refreshes = 0
}

final class TraktLibraryMutationOwnershipTests: XCTestCase {
    private var profileA = ""
    private var profileB = ""
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousLibraryProfileID: String?
    private var observers: [NSObjectProtocol] = []

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousLibraryProfileID = LibraryStore.activeProfileId
        profileA = "trakt-library-a-\(UUID().uuidString)"
        profileB = "trakt-library-b-\(UUID().uuidString)"
        activate(profileA)
        seedToken()
    }

    override func tearDown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        LibraryStore.setActiveProfile(previousLibraryProfileID)
        if let previousSettingsProfileID {
            ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        for profileID in [profileA, profileB] {
            MdbListKeychainTokenStorage().remove(for: profileID)
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }
        MdbListKeychainTokenStorage().remove(for: ProfileSettings.activeProfileScope)
        super.tearDown()
    }

    @MainActor
    func testCurrentMutationPublishesBothNotifications() throws {
        let mutation = try makeMutation()
        let probe = observeNotifications()
        TraktLibraryService.publishMutation(mutation)
        XCTAssertEqual(probe.mutations, 1)
        XCTAssertEqual(probe.refreshes, 1)
    }

    @MainActor
    func testProviderSwitchSuppressesPublicationAndQueuedConsumerMutation() throws {
        let mutation = try makeMutation()
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        let probe = observeNotifications()
        // MDBList is authenticated so the old generic usesRemoteLibrary guard
        // would have allowed the Trakt removal into this provider's items.
        _ = MdbListKeychainTokenStorage().save(
            MdbListStoredTokens(
                accessToken: "test-token",
                refreshToken: "test-refresh",
                expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + 3_600_000
            ),
            for: ProfileSettings.activeProfileScope
        )
        ProfileSettings.current.set("test-key", forKey: SettingsKey.mdbListApiKey)
        ProfileSettings.current.set(TraktLibrarySourceMode.mdblist.rawValue,
                                    forKey: SettingsKey.traktLibrarySourceMode)
        XCTAssertTrue(SelectedLibraryService.isSelectedAndAuthenticated)

        TraktLibraryService.publishMutation(mutation)
        viewModel.applyTraktMutation(mutation)

        XCTAssertEqual(probe.mutations, 0)
        XCTAssertEqual(probe.refreshes, 0)
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    @MainActor
    func testProfileSwitchSuppressesPublicationAndQueuedConsumerMutation() throws {
        let mutation = try makeMutation()
        activate(profileB)
        seedToken()
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        let probe = observeNotifications()

        TraktLibraryService.publishMutation(mutation)
        viewModel.applyTraktMutation(mutation)

        XCTAssertEqual(probe.mutations, 0)
        XCTAssertEqual(probe.refreshes, 0)
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    @MainActor
    func testRelinkWithIdenticalTokensStillRejectsOldAccountMutation() throws {
        let mutation = try makeMutation()
        seedToken(isNewLogin: true)
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        let probe = observeNotifications()

        TraktLibraryService.publishMutation(mutation)
        viewModel.applyTraktMutation(mutation)

        XCTAssertEqual(probe.mutations, 0)
        XCTAssertEqual(probe.refreshes, 0)
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    @MainActor
    func testTokenRotationKeepsMutationValidForSameAccount() throws {
        let mutation = try makeMutation()
        seedToken(accessToken: "rotated-access", refreshToken: "rotated-refresh")
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        viewModel.applyTraktMutation(mutation)
        XCTAssertTrue(viewModel.items.isEmpty)
    }

    @MainActor
    func testCurrentMutationStillAddsAndRemovesItems() throws {
        let context = try XCTUnwrap(TraktLibraryMutationContext())
        let viewModel = LibraryViewModel()
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: meta, isInWatchlist: true, context: context))
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: meta, isInWatchlist: false, context: context))
        XCTAssertTrue(viewModel.items.isEmpty)
    }

    @MainActor
    func testLegacySharedPayloadCannotMutateTraktLibrary() {
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: meta, isInWatchlist: false))
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    private var meta: NuvioMeta { NuvioMeta(id: "tt-library-\(profileA)", name: "Test", type: "movie") }

    private func activate(_ profileID: String) {
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        LibraryStore.setActiveProfile(profileID)
        ProfileSettings.current.set(TraktLibrarySourceMode.trakt.rawValue,
                                    forKey: SettingsKey.traktLibrarySourceMode)
        ProfileSettings.current.set("test-client", forKey: SettingsKey.traktClientID)
    }

    private func seedToken(accessToken: String = "test-access", refreshToken: String = "test-refresh",
                           isNewLogin: Bool = false) {
        TraktAuthStore.saveToken(TraktTokenResponse(accessToken: accessToken, tokenType: "Bearer",
                                                  expiresIn: 3600, refreshToken: refreshToken,
                                                  createdAt: Int(Date().timeIntervalSince1970)),
                                 clientID: "test-client", store: ProfileSettings.current, isNewLogin: isNewLogin)
    }

    @MainActor
    private func makeMutation() throws -> TraktLibraryMutation {
        TraktLibraryMutation(meta: meta, isInWatchlist: false,
                             context: try XCTUnwrap(TraktLibraryMutationContext()))
    }

    private func observeNotifications() -> TraktLibraryNotificationProbe {
        let probe = TraktLibraryNotificationProbe()
        observers.append(NotificationCenter.default.addObserver(forName: TraktLibraryService.mutationNotification,
                                                                object: nil, queue: nil) { _ in
            probe.mutations += 1
        })
        observers.append(NotificationCenter.default.addObserver(forName: TraktSettingsStore.libraryChangedNotification,
                                                                object: nil, queue: nil) { _ in
            probe.refreshes += 1
        })
        return probe
    }
}

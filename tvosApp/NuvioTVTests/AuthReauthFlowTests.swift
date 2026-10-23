import XCTest
@testable import NuvioTV

final class AuthReauthFlowTests: XCTestCase {

    func testAuthSessionExpiration() {
        let expiredSession = AuthSession(
            accessToken: "test_access",
            refreshToken: "test_refresh",
            userId: "user_123",
            email: "test@example.com",
            expiresAt: Date().timeIntervalSince1970 - 100 // 100s in past
        )
        XCTAssertTrue(expiredSession.isExpired)

        let validSession = AuthSession(
            accessToken: "test_access",
            refreshToken: "test_refresh",
            userId: "user_123",
            email: "test@example.com",
            expiresAt: Date().timeIntervalSince1970 + 3600 // 1 hr in future
        )
        XCTAssertFalse(validSession.isExpired)

        let nilExpirySession = AuthSession(
            accessToken: "test_access",
            refreshToken: "test_refresh",
            userId: "user_123",
            email: "test@example.com",
            expiresAt: nil
        )
        XCTAssertFalse(nilExpirySession.isExpired)
    }

    func testAuthErrorProperties() {
        let error400 = AuthError(message: "Invalid Refresh Token: Refresh Token Not Found", statusCode: 400)
        XCTAssertEqual(error400.statusCode, 400)
        XCTAssertEqual(error400.errorDescription, "Invalid Refresh Token: Refresh Token Not Found")

        let error401 = AuthError(message: "JWT expired", statusCode: 401)
        XCTAssertEqual(error401.statusCode, 401)

        let error403 = AuthError(message: "bad_jwt", statusCode: 403)
        XCTAssertEqual(error403.statusCode, 403)
    }

    func testReauthenticationMessage() {
        XCTAssertEqual(
            NuvioSyncManager.reauthenticationMessage,
            "Your Nuvio session expired. Sign in again to resume syncing."
        )
    }

    func testReauthLocalizationFallbacks() {
        XCTAssertFalse(L10n.string("reauth_title", fallback: "Reconnect Nuvio Account").isEmpty)
        XCTAssertFalse(L10n.string("reauth_subtitle", fallback: "Your session expired.").isEmpty)
        XCTAssertFalse(L10n.string("reauth_banner_title", fallback: "Account Sync Paused").isEmpty)
        XCTAssertFalse(L10n.string("reauth_banner_subtitle", fallback: "Your Nuvio session expired.").isEmpty)
        XCTAssertFalse(L10n.string("reauth_action_title", fallback: "Reconnect Account").isEmpty)
        XCTAssertFalse(L10n.string("reauth_action_subtitle", fallback: "Your session expired.").isEmpty)
        XCTAssertFalse(L10n.string("reauth_success", fallback: "Reconnected successfully! Resuming sync…").isEmpty)
    }

    func testTvLoginWebBaseURL() {
        XCTAssertEqual(AuthConfig.officialTvLoginWebBaseURL, "https://nuvio.tv/tv-login")
        XCTAssertEqual(AuthConfig.officialAPIBaseURL, "https://api.nuvio.tv")
        XCTAssertEqual(AuthConfig.tvLoginWebBaseURL, "https://nuvio.tv/tv-login")
        XCTAssertFalse(AuthConfig.tvLoginWebBaseURL.contains("api.nuvio.tv"))
    }

    func testTvLoginStartResultSanitizesAPINuvioURL() throws {
        // Issue #91: Backend returns web_url with api.nuvio.tv which fails when scanned by mobile camera
        let json = """
        {
            "code": "TESTCODE",
            "web_url": "https://api.nuvio.tv/tv-login?code=TESTCODE",
            "expires_at": "2026-09-15T16:00:00Z",
            "poll_interval_seconds": 3
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(TvLoginStartResult.self, from: json)
        XCTAssertEqual(result.webUrl, "https://nuvio.tv/tv-login?code=TESTCODE")
        XCTAssertFalse(result.webUrl.contains("api.nuvio.tv"))
    }

    func testTvLoginStartResultPreservesCustomServerURL() throws {
        let json = """
        {
            "code": "CUSTOMCODE",
            "web_url": "https://nuvio.mycustomdomain.com/tv-login?code=CUSTOMCODE",
            "expires_at": "2026-09-15T16:00:00Z",
            "poll_interval_seconds": 3
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(TvLoginStartResult.self, from: json)
        XCTAssertEqual(result.webUrl, "https://nuvio.mycustomdomain.com/tv-login?code=CUSTOMCODE")
    }

    func testTvLoginStartResultEmptyURLFallback() throws {
        let json = """
        {
            "code": "FALLBACKCODE",
            "web_url": "",
            "expires_at": "2026-09-15T16:00:00Z",
            "poll_interval_seconds": 3
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(TvLoginStartResult.self, from: json)
        XCTAssertEqual(result.webUrl, "\(AuthConfig.tvLoginWebBaseURL)?code=FALLBACKCODE")
    }
}
final class TraktProfileIsolationTests: XCTestCase {
    private var primaryID = ""
    private var secondaryID = ""

    override func setUp() {
        super.setUp()
        primaryID = "trakt-primary-\(UUID().uuidString)"
        secondaryID = "trakt-secondary-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(primaryID, isPrimary: true)
    }

    override func tearDown() {
        ProfileSettings.clearActiveProfile()
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(primaryID)")
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(secondaryID)")
        super.tearDown()
    }

    func testNewSecondaryProfileDoesNotInheritPrimaryTraktLink() {
        let primary = ProfileSettings.current
        primary.set("client-id", forKey: SettingsKey.traktClientID)
        primary.set("client-secret", forKey: SettingsKey.traktClientSecret)
        TraktAuthStore.saveToken(
            TraktTokenResponse(
                accessToken: "primary-access",
                tokenType: "Bearer",
                expiresIn: 3600,
                refreshToken: "primary-refresh",
                createdAt: Int(Date().timeIntervalSince1970)
            ),
            clientID: "client-id",
            store: primary
        )

        ProfileSettings.seedNewProfile(secondaryID)
        let secondary = ProfileSettings.store(for: secondaryID)

        XCTAssertNil(secondary.string(forKey: SettingsKey.traktClientID))
        XCTAssertNil(secondary.string(forKey: SettingsKey.traktClientSecret))
        XCTAssertFalse(TraktAuthStore.isAuthenticated(in: secondary))
        XCTAssertFalse(RemoteTrackingState.shouldMirrorWatchedHistoryToTrakt(in: secondary))
    }

    func testCapturedTraktStoreStopsWritingAfterProfileSwitch() {
        ProfileSettings.seedNewProfile(secondaryID)
        ProfileSettings.setActiveProfile(secondaryID, isPrimary: false)
        let secondary = ProfileSettings.current
        secondary.set("secondary-client", forKey: SettingsKey.traktClientID)
        secondary.set("secondary-secret", forKey: SettingsKey.traktClientSecret)
        TraktAuthStore.saveToken(
            TraktTokenResponse(
                accessToken: "secondary-access",
                tokenType: "Bearer",
                expiresIn: 3600,
                refreshToken: "secondary-refresh",
                createdAt: Int(Date().timeIntervalSince1970)
            ),
            clientID: "secondary-client",
            store: secondary
        )

        XCTAssertTrue(RemoteTrackingState.shouldMirrorWatchedHistoryToTrakt(in: secondary))
        ProfileSettings.setActiveProfile(primaryID, isPrimary: true)
        XCTAssertFalse(ProfileSettings.isActiveStore(secondary))
        XCTAssertFalse(RemoteTrackingState.shouldMirrorWatchedHistoryToTrakt(in: secondary))
    }
}

final class SimklProfileIsolationTests: XCTestCase {
    private var primaryID = ""
    private var secondaryID = ""
    private let tokenStorage = SimklKeychainTokenStorage()

    override func setUp() {
        super.setUp()
        primaryID = "simkl-primary-\(UUID().uuidString)"
        secondaryID = "simkl-secondary-\(UUID().uuidString)"
        tokenStorage.setAccessToken(nil, for: primaryID)
        tokenStorage.setAccessToken(nil, for: secondaryID)
        ProfileSettings.setActiveProfile(primaryID, isPrimary: true)
    }

    override func tearDown() {
        tokenStorage.setAccessToken(nil, for: primaryID)
        tokenStorage.setAccessToken(nil, for: secondaryID)
        ProfileSettings.clearActiveProfile()
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(primaryID)")
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(secondaryID)")
        super.tearDown()
    }

    func testNewSecondaryProfileDoesNotInheritPrimarySimklLink() {
        let primary = ProfileSettings.current
        primary.set("simkl-client", forKey: SettingsKey.simklClientID)
        SimklAuthStore.saveToken(
            "primary-simkl-token",
            clientID: "simkl-client",
            profileScope: primaryID,
            store: primary,
            tokenStorage: tokenStorage
        )
        primary.set(TraktWatchProgressSource.simkl.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        ProfileSettings.seedNewProfile(secondaryID)
        let secondary = ProfileSettings.store(for: secondaryID)

        XCTAssertNil(secondary.string(forKey: SettingsKey.simklClientID))
        XCTAssertNil(secondary.string(forKey: SettingsKey.simklAccessToken))
        XCTAssertNil(tokenStorage.accessToken(for: secondaryID))
        XCTAssertNil(SimklRuntimeSession.authenticatedState(store: secondary, tokenStorage: tokenStorage, profileScope: secondaryID))
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.simkl, in: secondary))
    }

    func testCapturedSimklStoreStopsWritingAfterProfileSwitch() {
        ProfileSettings.seedNewProfile(secondaryID)
        ProfileSettings.setActiveProfile(secondaryID, isPrimary: false)
        let secondary = ProfileSettings.current
        secondary.set("secondary-simkl-client", forKey: SettingsKey.simklClientID)
        SimklAuthStore.saveToken(
            "secondary-simkl-token",
            clientID: "secondary-simkl-client",
            profileScope: secondaryID,
            store: secondary,
            tokenStorage: tokenStorage
        )
        secondary.set(TraktWatchProgressSource.simkl.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        XCTAssertTrue(RemoteTrackingState.isProgressSourceAuthenticated(.simkl, in: secondary))
        ProfileSettings.setActiveProfile(primaryID, isPrimary: true)
        XCTAssertFalse(ProfileSettings.isActiveStore(secondary))
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.simkl, in: secondary))
    }
}

final class MdbListProfileIsolationTests: XCTestCase {
    private var primaryID = ""
    private var secondaryID = ""
    private let tokenStorage = MdbListKeychainTokenStorage()

    override func setUp() {
        super.setUp()
        primaryID = "mdblist-primary-\(UUID().uuidString)"
        secondaryID = "mdblist-secondary-\(UUID().uuidString)"
        tokenStorage.remove(for: primaryID)
        tokenStorage.remove(for: secondaryID)
        ProfileSettings.setActiveProfile(primaryID, isPrimary: true)
    }

    override func tearDown() {
        tokenStorage.remove(for: primaryID)
        tokenStorage.remove(for: secondaryID)
        ProfileSettings.clearActiveProfile()
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(primaryID)")
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(secondaryID)")
        super.tearDown()
    }

    func testNewSecondaryProfileDoesNotInheritPrimaryMdbListLink() {
        let primary = ProfileSettings.current
        primary.set("mdblist-api-key", forKey: SettingsKey.mdbListApiKey)
        primary.set(true, forKey: SettingsKey.mdbListEnabled)
        primary.set(TraktWatchProgressSource.mdblist.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        ProfileSettings.seedNewProfile(secondaryID)
        let secondary = ProfileSettings.store(for: secondaryID)

        XCTAssertNil(secondary.string(forKey: SettingsKey.mdbListApiKey))
        XCTAssertFalse(secondary.bool(forKey: SettingsKey.mdbListEnabled))
        XCTAssertFalse(MdbListRuntimeSession.isAuthenticated(in: secondary, tokenStorage: tokenStorage, profileScope: secondaryID))
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.mdblist, in: secondary))
    }

    func testCapturedMdbListStoreStopsWritingAfterProfileSwitch() {
        ProfileSettings.seedNewProfile(secondaryID)
        ProfileSettings.setActiveProfile(secondaryID, isPrimary: false)
        let secondary = ProfileSettings.current
        MdbListAuthStore.saveTokens(
            MdbListStoredTokens(
                accessToken: "secondary-token",
                refreshToken: "secondary-refresh",
                expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + 3_600_000
            ),
            user: MdbListUser(accountID: "sec", username: "secuser", displayName: "Secondary"),
            profileScope: secondaryID,
            store: secondary,
            tokenStorage: tokenStorage
        )
        secondary.set(TraktWatchProgressSource.mdblist.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        XCTAssertTrue(RemoteTrackingState.isProgressSourceAuthenticated(.mdblist, in: secondary, mdbListTokenStorage: tokenStorage, profileScope: secondaryID))
        ProfileSettings.setActiveProfile(primaryID, isPrimary: true)
        XCTAssertFalse(ProfileSettings.isActiveStore(secondary))
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.mdblist, in: secondary, mdbListTokenStorage: tokenStorage, profileScope: secondaryID))
    }
}

final class ProfileManagerLimitTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("profile-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testProfileLimitEnforcedInProfileManager() throws {
        let manager = try ProfileManager(baseDir: tempDir.path)

        // Initially 0 profiles, can create up to 6
        XCTAssertTrue(manager.canCreateProfile)

        for i in 1...6 {
            XCTAssertTrue(manager.canCreateProfile, "Should be able to create profile \(i)")
            _ = try manager.createProfile(input: CreateProfileInput(name: "User \(i)", profileType: .adult, avatarId: "", pin: nil))
        }

        XCTAssertEqual(try manager.getProfiles().count, 6)
        XCTAssertFalse(manager.canCreateProfile, "canCreateProfile should be false when 6 profiles exist")

        // 7th profile should throw maxProfilesReached
        XCTAssertThrowsError(try manager.createProfile(input: CreateProfileInput(name: "User 7", profileType: .adult, avatarId: "", pin: nil))) { error in
            guard let managerError = error as? ProfileManagerError else {
                return XCTFail("Expected ProfileManagerError but got \(error)")
            }
            XCTAssertEqual(managerError, .maxProfilesReached)
            XCTAssertEqual(managerError.errorDescription, "You've reached the maximum of 6 profiles. Remove one to create another.")
        }

        // Count must remain 6
        XCTAssertEqual(try manager.getProfiles().count, 6)
    }

    @MainActor
    func testProfileViewModelCanAddProfileAndErrorHandling() throws {
        let manager = try ProfileManager(baseDir: tempDir.path)
        for i in 1...6 {
            _ = try manager.createProfile(input: CreateProfileInput(name: "User \(i)", profileType: .adult, avatarId: "", pin: nil))
        }

        let viewModel = ProfileViewModel(profileManager: manager)
        XCTAssertEqual(viewModel.profiles.count, 6)
        XCTAssertFalse(viewModel.canAddProfile, "canAddProfile should be false when at limit")

        viewModel.createProfile(name: "Overflow", pin: nil)
        XCTAssertEqual(viewModel.profileCreationError, "You've reached the maximum of 6 profiles. Remove one to create another.")

        // Delete one profile to free up a slot
        if let first = viewModel.profiles.first {
            try manager.deleteProfile(id: first.id)
            viewModel.loadProfiles()
            XCTAssertTrue(viewModel.canAddProfile, "canAddProfile should be true after deleting a profile")
        }
    }
}

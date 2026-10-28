import XCTest
@testable import NuvioTV

final class ReuseLastLinkTests: XCTestCase {
    private var testProfileID: String!
    private var testStore: UserDefaults!

    override func setUp() {
        super.setUp()
        testProfileID = "test-profile-reuse-\(UUID().uuidString)"
        testStore = ProfileSettings.store(for: testProfileID)
    }

    override func tearDown() {
        if let testProfileID {
            let defaults = ProfileSettings.store(for: testProfileID)
            defaults.removePersistentDomain(forName: "nuvio.profile.\(testProfileID)")
        }
        super.tearDown()
    }

    // MARK: - Settings Keys & Defaults

    func testSettingsKeyContainedInAll() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.reuseLastLink), "reuseLastLink must be in SettingsKey.all")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.reuseLastLinkCacheHours), "reuseLastLinkCacheHours must be in SettingsKey.all")
    }

    // MARK: - Sync Key Mappings (Parity with Android TV and Mobile)

    func testSyncKeyMappingsCoverage() {
        let localKeys = PlayerSettingsSyncMapper.localToRemoteKeyMappings.map(\.local)
        XCTAssertTrue(localKeys.contains(SettingsKey.reuseLastLink))
        XCTAssertTrue(localKeys.contains(SettingsKey.reuseLastLinkCacheHours))

        let remoteKeys = PlayerSettingsSyncMapper.remoteToLocalKeyMappings.map(\.remote)
        XCTAssertTrue(remoteKeys.contains("stream_reuse_last_link_enabled"))
        XCTAssertTrue(remoteKeys.contains("stream_reuse_last_link_cache_hours"))
    }

    func testSyncPayloadExportAndImport() {
        testStore.set(true, forKey: SettingsKey.reuseLastLink)
        testStore.set(48, forKey: SettingsKey.reuseLastLinkCacheHours)

        let exported = PlayerSettingsSyncMapper.exportPayload(
            localProfileId: testProfileID,
            existing: nil,
            encodeValue: { value in
                if let boolVal = value as? Bool {
                    return ["type": "boolean", "value": boolVal]
                }
                if let intVal = value as? Int {
                    return ["type": "int", "value": intVal]
                }
                return nil
            }
        )

        let enabledEntry = exported["stream_reuse_last_link_enabled"] as? [String: Any]
        XCTAssertEqual(enabledEntry?["value"] as? Bool, true)

        let hoursEntry = exported["stream_reuse_last_link_cache_hours"] as? [String: Any]
        XCTAssertEqual(hoursEntry?["value"] as? Int, 48)

        // Test Import
        let importProfileID = "test-profile-import-\(UUID().uuidString)"
        let importStore = ProfileSettings.store(for: importProfileID)

        let remotePayload: [String: Any] = [
            "stream_reuse_last_link_enabled": [
                "type": "boolean",
                "value": true
            ],
            "stream_reuse_last_link_cache_hours": [
                "type": "int",
                "value": 72
            ]
        ]

        PlayerSettingsSyncMapper.importPayload(
            remotePayload,
            localProfileId: importProfileID,
            decodeValue: { dict in dict["value"] }
        )

        XCTAssertEqual(importStore.bool(forKey: SettingsKey.reuseLastLink), true)
        XCTAssertEqual(importStore.integer(forKey: SettingsKey.reuseLastLinkCacheHours), 72)

        importStore.removePersistentDomain(forName: "nuvio.profile.\(importProfileID)")
    }

    // MARK: - LastPlaybackStreamStore Dynamic TTL

    func testEffectiveTTLWhenReuseDisabledUsesDefaultTwoHours() {
        testStore.set(false, forKey: SettingsKey.reuseLastLink)
        let ttl = LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID)
        XCTAssertEqual(ttl, 7200, "Default TTL when Reuse Last Link is off must be 2 hours (7200s)")
    }

    func testEffectiveTTLWhenReuseEnabledUsesConfiguredHours() {
        testStore.set(true, forKey: SettingsKey.reuseLastLink)

        // Default 24 hours
        testStore.removeObject(forKey: SettingsKey.reuseLastLinkCacheHours)
        XCTAssertEqual(LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID), 24 * 3600)

        // 1 hour
        testStore.set(1, forKey: SettingsKey.reuseLastLinkCacheHours)
        XCTAssertEqual(LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID), 3600)

        // 6 hours
        testStore.set(6, forKey: SettingsKey.reuseLastLinkCacheHours)
        XCTAssertEqual(LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID), 6 * 3600)

        // 12 hours
        testStore.set(12, forKey: SettingsKey.reuseLastLinkCacheHours)
        XCTAssertEqual(LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID), 12 * 3600)

        // 48 hours (2 days)
        testStore.set(48, forKey: SettingsKey.reuseLastLinkCacheHours)
        XCTAssertEqual(LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID), 48 * 3600)

        // 72 hours (3 days)
        testStore.set(72, forKey: SettingsKey.reuseLastLinkCacheHours)
        XCTAssertEqual(LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID), 72 * 3600)

        // 168 hours (7 days)
        testStore.set(168, forKey: SettingsKey.reuseLastLinkCacheHours)
        XCTAssertEqual(LastPlaybackStreamStore.effectiveRemoteStreamTTL(profileId: testProfileID), 168 * 3600)
    }

    func testPlaybackStreamSavedAndLoadedWithinTTL() {
        testStore.set(true, forKey: SettingsKey.reuseLastLink)
        testStore.set(24, forKey: SettingsKey.reuseLastLinkCacheHours)

        let metaId = "tt-reuse-test-movie"
        let savedDate = Date(timeIntervalSince1970: 1000)
        let streamURL = "https://debrid.example.com/cached/movie.mkv"
        let headers = ["User-Agent": "Nuvio", "Authorization": "Bearer token"]

        LastPlaybackStreamStore.save(
            metaId: metaId,
            url: streamURL,
            httpHeaders: headers,
            season: nil,
            episode: nil,
            profileId: testProfileID,
            savedAt: savedDate
        )

        // Loaded 10 hours later: within 24h cache window
        let tenHoursLater = savedDate.addingTimeInterval(10 * 3600)
        let loaded = LastPlaybackStreamStore.load(
            metaId: metaId,
            season: nil,
            episode: nil,
            profileId: testProfileID,
            now: tenHoursLater
        )
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.url, streamURL)
        XCTAssertEqual(loaded?.httpHeaders, headers)

        // Loaded 25 hours later: expired
        let twentyFiveHoursLater = savedDate.addingTimeInterval(25 * 3600)
        let expired = LastPlaybackStreamStore.load(
            metaId: metaId,
            season: nil,
            episode: nil,
            profileId: testProfileID,
            now: twentyFiveHoursLater
        )
        XCTAssertNil(expired, "Stream URL must expire after configured 24 hours")

        // Once expired, subsequent check is also nil (evicted)
        XCTAssertNil(LastPlaybackStreamStore.load(
            metaId: metaId,
            season: nil,
            episode: nil,
            profileId: testProfileID,
            now: tenHoursLater
        ))
    }

    func testLocalStreamsDoNotExpireRegardlessOfCacheSetting() {
        testStore.set(true, forKey: SettingsKey.reuseLastLink)
        testStore.set(1, forKey: SettingsKey.reuseLastLinkCacheHours) // 1 hour TTL

        let metaId = "tt-local-smb-movie"
        let savedDate = Date(timeIntervalSince1970: 1000)
        let smbURL = "smb://192.168.1.100/media/movie.mkv"

        LastPlaybackStreamStore.save(
            metaId: metaId,
            url: smbURL,
            season: nil,
            episode: nil,
            profileId: testProfileID,
            savedAt: savedDate
        )

        // 30 days later, SMB stream is still valid
        let thirtyDaysLater = savedDate.addingTimeInterval(30 * 86400)
        let loaded = LastPlaybackStreamStore.load(
            metaId: metaId,
            season: nil,
            episode: nil,
            profileId: testProfileID,
            now: thirtyDaysLater
        )
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.url, smbURL)

        LastPlaybackStreamStore.remove(metaId: metaId, profileId: testProfileID)
    }

    func testEpisodeScopedLinkReuse() {
        testStore.set(true, forKey: SettingsKey.reuseLastLink)
        let metaId = "tt-series-show"
        let ep1URL = "https://debrid.example.com/ep1.mkv"
        let ep2URL = "https://debrid.example.com/ep2.mkv"

        LastPlaybackStreamStore.save(
            metaId: metaId,
            url: ep1URL,
            season: 1,
            episode: 1,
            profileId: testProfileID
        )

        LastPlaybackStreamStore.save(
            metaId: metaId,
            url: ep2URL,
            season: 1,
            episode: 2,
            profileId: testProfileID
        )

        let loadedEp2 = LastPlaybackStreamStore.load(metaId: metaId, season: 1, episode: 2, profileId: testProfileID)
        XCTAssertEqual(loadedEp2?.url, ep2URL)

        // Ep 1 was replaced in the single record for series if same metaId
        // but verifying episode matching
        let wrongEp = LastPlaybackStreamStore.load(metaId: metaId, season: 1, episode: 3, profileId: testProfileID)
        XCTAssertNil(wrongEp)

        LastPlaybackStreamStore.remove(metaId: metaId, season: 1, episode: 2, profileId: testProfileID)
        XCTAssertNil(LastPlaybackStreamStore.load(metaId: metaId, season: 1, episode: 2, profileId: testProfileID))
    }

    // MARK: - Candidate Keys & Cross-ID Stream Reuse (Issue #348)

    func testCandidateKeysGeneration() {
        let meta = NuvioMeta(
            id: "tmdb:12345",
            name: "Test Movie",
            imdbId: "tt9876543",
            tmdbId: 12345,
            type: "movie"
        )
        let keys = LastPlaybackStreamStore.candidateKeys(for: meta.id, meta: meta)
        XCTAssertTrue(keys.contains("tmdb:12345"))
        XCTAssertTrue(keys.contains("12345"))
        XCTAssertTrue(keys.contains("tt9876543"))
    }

    func testCandidateKeyStreamLookup() {
        testStore.set(true, forKey: SettingsKey.reuseLastLink)
        let meta = NuvioMeta(
            id: "tmdb:445566",
            name: "Cross ID Movie",
            imdbId: "tt7788990",
            tmdbId: 445566,
            type: "movie"
        )
        let streamURL = "https://example.com/movie.mp4"

        // Save under IMDB ID with meta attached
        LastPlaybackStreamStore.save(
            metaId: "tt7788990",
            url: streamURL,
            season: nil,
            episode: nil,
            meta: meta,
            profileId: testProfileID
        )

        // Query by TMDB ID
        let loaded = LastPlaybackStreamStore.load(
            metaId: "tmdb:445566",
            season: nil,
            episode: nil,
            meta: meta,
            profileId: testProfileID
        )
        XCTAssertNotNil(loaded, "Stream saved under IMDB ID must be retrievable by TMDB ID via candidate keys")
        XCTAssertEqual(loaded?.url, streamURL)

        LastPlaybackStreamStore.remove(metaId: "tmdb:445566", meta: meta, profileId: testProfileID)
    }

    func testMovieEpisodeMatchingNilVersusZero() {
        testStore.set(true, forKey: SettingsKey.reuseLastLink)
        let metaId = "tt-movie-nil-vs-zero"
        let streamURL = "https://example.com/movie-zeros.mp4"

        // Save with season: nil, episode: nil
        LastPlaybackStreamStore.save(
            metaId: metaId,
            url: streamURL,
            season: nil,
            episode: nil,
            profileId: testProfileID
        )

        // Load with season: 0, episode: 0
        let loadedWithZero = LastPlaybackStreamStore.load(
            metaId: metaId,
            season: 0,
            episode: 0,
            profileId: testProfileID
        )
        XCTAssertNotNil(loadedWithZero, "Movie with season: nil must match query with season: 0")
        XCTAssertEqual(loadedWithZero?.url, streamURL)

        // Save with season: 0, episode: 0
        let streamURL2 = "https://example.com/movie-zeros-2.mp4"
        LastPlaybackStreamStore.save(
            metaId: metaId,
            url: streamURL2,
            season: 0,
            episode: 0,
            profileId: testProfileID
        )

        // Load with season: nil, episode: nil
        let loadedWithNil = LastPlaybackStreamStore.load(
            metaId: metaId,
            season: nil,
            episode: nil,
            profileId: testProfileID
        )
        XCTAssertNotNil(loadedWithNil, "Movie with season: 0 must match query with season: nil")
        XCTAssertEqual(loadedWithNil?.url, streamURL2)

        LastPlaybackStreamStore.remove(metaId: metaId, season: nil, episode: nil, profileId: testProfileID)
    }

    func testContinueWatchingStoreCandidateMatchingAndLedgerFallback() {
        let meta = NuvioMeta(
            id: "tmdb:998877",
            name: "Ledger Fallback Movie",
            imdbId: "tt1122334",
            tmdbId: 998877,
            type: "movie"
        )

        // Seed durable record in WatchProgressLedger under imdb ID
        let record = WatchProgressRecord(
            progressKey: "tt1122334",
            contentId: "tt1122334",
            contentType: "movie",
            videoId: "tt1122334",
            season: nil,
            episode: nil,
            position: 600.0,
            duration: 1200.0,
            lastWatchedAt: Date()
        )
        WatchProgressLedger.upsert(record)

        // Resume position for tmdb meta should find the ledger record via candidate keys
        let resumePos = ContinueWatchingStore.resumePosition(for: meta, season: nil, episode: nil)
        XCTAssertEqual(resumePos, 600.0, "Resume position must fall back to WatchProgressLedger via candidate IDs")

        _ = WatchProgressLedger.remove(keys: ["tt1122334"])
    }
}

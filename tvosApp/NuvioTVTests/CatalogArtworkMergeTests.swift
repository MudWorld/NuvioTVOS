import XCTest
@testable import NuvioTV

/// Cover for Home's landscape shelf artwork: the merge that fills a compact
/// catalog card from its full `/meta` record must never clobber catalog-
/// provided artwork, and the Stremio `logo` field must decode into
/// `NuvioMeta.logoUrl` so `PosterCard` can draw it in the landscape overlay.
final class CatalogArtworkMergeTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testMergeFillsMissingArtworkAndIdentifiers() {
        let catalog = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            description: "catalog copy",
            posterUrl: "https://cdn.example/poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0903747",
            tmdbId: nil,
            type: "series",
            year: 2008,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil
        )
        let full = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            description: "full copy",
            posterUrl: "https://cdn.example/tmdb-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://cdn.example/logo.png",
            imdbId: "tt0903747",
            tmdbId: 1396,
            type: "series",
            year: 2008,
            genres: ["Crime"],
            rating: 9.5,
            releaseInfo: "2008",
            runtime: "47 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: "Ended",
            videos: nil,
            trailerYtIds: ["abc"]
        )

        let merged = catalog.fillingMissingHeroMetadata(from: full)

        // Catalog-provided poster wins over refreshed artwork.
        XCTAssertEqual(merged.posterUrl, "https://cdn.example/poster.jpg")
        // Missing backdrop/logo are filled.
        XCTAssertEqual(merged.backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(merged.logoUrl, "https://cdn.example/logo.png")
        // Missing identifiers, runtime, and status are filled.
        XCTAssertEqual(merged.tmdbId, 1396)
        XCTAssertEqual(merged.runtime, "47 min")
        XCTAssertEqual(merged.status, "Ended")
        // Catalog copy is preserved; refreshed copy never replaces it.
        XCTAssertEqual(merged.description, "catalog copy")
        XCTAssertNil(merged.genres)
        XCTAssertNil(merged.rating)
    }

    func testMergeKeepsSourceLogoAndTreatsBlankArtworkAsMissing() {
        let catalog = NuvioMeta(
            id: "tt0111161",
            name: "The Shawshank Redemption",
            description: nil,
            posterUrl: "https://cdn.example/poster.jpg",
            backgroundUrl: "   ",
            logoUrl: "https://source.example/logo.png",
            imdbId: nil,
            tmdbId: nil,
            type: "movie",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil
        )
        let full = NuvioMeta(
            id: "tt0111161",
            name: "The Shawshank Redemption",
            description: nil,
            posterUrl: "https://cdn.example/tmdb-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://tmdb.example/logo.png",
            imdbId: "tt0111161",
            tmdbId: 278,
            type: "movie",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: "142 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil
        )

        let merged = catalog.fillingMissingHeroMetadata(from: full)

        // A source-provided logo is never replaced by a TMDB one.
        XCTAssertEqual(merged.logoUrl, "https://source.example/logo.png")
        // A blank backdrop counts as missing and is filled.
        XCTAssertEqual(merged.backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(merged.runtime, "142 min")
        XCTAssertEqual(merged.tmdbId, 278)
    }

    /// A Stremio catalog page's `logo` field must survive decoding so Home can
    /// draw the title logo in the landscape overlay — the field this feature
    /// depends on after the merge above fills it in.
    func testDecodesStremioLogoField() throws {
        let json = Data("""
        {"metas":[{
          "id":"tt0903747","type":"series","name":"Breaking Bad",
          "poster":"https://images.example/poster.jpg",
          "background":"https://images.example/backdrop.jpg",
          "logo":"https://images.example/logo.png",
          "imdbRating":"9.5","runtime":"47 min","status":"Ended"
        }]}
        """.utf8)

        let response = try decoder.decode(CinemetaCatalogResponse.self, from: json)
        let meta = try XCTUnwrap(response.metas.first).toMeta(fallbackType: "series")

        XCTAssertEqual(meta.logoUrl, "https://images.example/logo.png")
        XCTAssertEqual(meta.backgroundUrl, "https://images.example/backdrop.jpg")
        XCTAssertEqual(meta.posterUrl, "https://images.example/poster.jpg")
        XCTAssertEqual(meta.runtime, "47 min")
        XCTAssertEqual(meta.status, "Ended")
        XCTAssertEqual(meta.imdbId, "tt0903747")
    }

    /// Search returns an IMDb-first compact record while watch history knows
    /// the title only as `tmdb:<id>`. Only the aliases the background
    /// enrichment adds can make the Search card resolve to the same watched
    /// record — movie-title matching must never be used, since duplicate
    /// names make that unsafe.
    func testEnrichedSearchResultMatchesTMDBFirstWatchedRecord() {
        let searchResult = makeMeta(
            id: "tt0903747",
            imdbId: nil,
            tmdbId: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil
        )
        let watched = makeMeta(
            id: "tmdb:1396",
            imdbId: nil,
            tmdbId: 1396,
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil
        )

        XCTAssertFalse(
            WatchedStore.sameContent(searchResult, watched),
            "compact search record cannot match a TMDB-first watched record yet"
        )

        // The refreshed /meta record carries both aliases (plus artwork).
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cdn.example/refreshed-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://cdn.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )
        let enriched = searchResult.mergingSearchMetadata(from: full)

        XCTAssertEqual(enriched.id, "tt0903747", "original result id / focus identity is preserved")
        XCTAssertEqual(enriched.imdbId, "tt0903747")
        XCTAssertEqual(enriched.tmdbId, 1396)
        XCTAssertEqual(enriched.backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(enriched.logoUrl, "https://cdn.example/logo.png")
        XCTAssertTrue(
            WatchedStore.sameContent(enriched, watched),
            "enriched aliases must match the TMDB-first watched record"
        )
        XCTAssertFalse(
            WatchedStore.sameContent(enriched, makeMeta(id: "tmdb:999", imdbId: nil, tmdbId: 999)),
            "alias matching must never fall back to movie titles"
        )
    }

    /// The background search enrichment keeps result ids, order, and complete
    /// records untouched while merging the missing aliases/artwork into the
    /// compact leading results.
    func testSearchEnrichmentPreservesIDsAndFillsAliasesAndArtwork() async {
        let rawResult = makeMeta(
            id: "tt0903747",
            imdbId: nil,
            tmdbId: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil
        )
        // A fully-populated record needs no refresh — it must pass through
        // untouched (and not generate a repository request).
        let complete = makeMeta(
            id: "tt0133093",
            imdbId: "tt0133093",
            tmdbId: 603,
            type: "movie",
            backgroundUrl: "https://cdn.example/b.jpg",
            logoUrl: "https://cdn.example/l.png",
            runtime: "136 min",
            status: nil
        )
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cdn.example/refreshed-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://cdn.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )

        let repository = StubRefreshRepository(fullByID: ["tt0903747": full])
        let enriched = await SearchResultEnrichment.enrich(
            [rawResult, complete],
            repository: repository
        )

        XCTAssertEqual(enriched.map(\.id), ["tt0903747", "tt0133093"], "ids and order are preserved")
        XCTAssertEqual(enriched[0].imdbId, "tt0903747")
        XCTAssertEqual(enriched[0].tmdbId, 1396)
        XCTAssertEqual(enriched[0].posterUrl, "https://cdn.example/refreshed-poster.jpg")
        XCTAssertEqual(enriched[0].backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(enriched[0].logoUrl, "https://cdn.example/logo.png")
        XCTAssertEqual(enriched[0].runtime, "47 min")
        XCTAssertEqual(enriched[0].status, "Ended")
        XCTAssertEqual(enriched[1].tmdbId, 603, "complete record must be untouched")
    }

    func testSearchCrossProviderDeduplicationAndAliasAdoption() {
        // Cinemeta search results return IMDb IDs without TMDB IDs.
        // TMDB/add-on search results return tmdb: prefixes without IMDb IDs.
        let rawCinemeta = makeMeta(id: "tt1375666", imdbId: "tt1375666", tmdbId: nil, type: "movie", name: "Inception", year: 2010)
        let rawTmdbAddon = makeMeta(id: "tmdb:27205", imdbId: nil, tmdbId: nil, type: "movie", name: "Inception", year: 2010)
        let rawCustomAddon = makeMeta(id: "addon:custom:99", imdbId: nil, tmdbId: nil, type: "movie", name: "Inception", year: 2010)
        let releaseInfoItem = makeMeta(id: "addon:date:1", imdbId: nil, tmdbId: nil, type: "movie", name: "Inception", year: nil, releaseInfo: "2010-07-16")
        let remakeDifferentYear = makeMeta(id: "tt9999999", imdbId: "tt9999999", tmdbId: nil, type: "movie", name: "Inception", year: 1980)
        let seriesDifferentType = makeMeta(id: "tt8888888", imdbId: "tt8888888", tmdbId: nil, type: "series", name: "Inception", year: 2010)
        let conflictingTmdb = makeMeta(id: "tmdb:99999", imdbId: nil, tmdbId: 99999, type: "movie", name: "Inception", year: 2010)

        let items = [
            rawCinemeta,
            rawTmdbAddon,
            rawCustomAddon,
            releaseInfoItem,
            remakeDifferentYear,
            seriesDifferentType,
            conflictingTmdb
        ]

        let deduplicated = CinemetaCatalogRepository.deduplicatedSearchResults(items)

        // Only rawCinemeta (kept), remake (1980), series (different type), and conflicting TMDB ID should remain.
        XCTAssertEqual(
            deduplicated.map(\.id),
            ["tt1375666", "tt9999999", "tt8888888", "tmdb:99999"]
        )

        // Kept item must adopt the tmdbId from rawTmdbAddon
        let kept = deduplicated.first { $0.id == "tt1375666" }
        XCTAssertEqual(kept?.imdbId, "tt1375666")
        XCTAssertEqual(kept?.tmdbId, 27205)
    }

    func testSearchEnrichmentDeduplicatesPostEnrichedAliases() async {
        // Two search results for the same movie with disjoint names / missing dates that initially slipped through
        let rawA = makeMeta(id: "tt0133093", imdbId: nil, tmdbId: nil, type: "movie", name: "The Matrix", year: nil)
        let rawB = makeMeta(id: "tmdb:603", imdbId: nil, tmdbId: nil, type: "movie", name: "Matrix", year: nil)

        // Both refresh to the authoritative The Matrix (1999) records with shared canonical IDs
        let fullA = makeMeta(id: "tt0133093", imdbId: "tt0133093", tmdbId: 603, type: "movie", name: "The Matrix", year: 1999)
        let fullB = makeMeta(id: "tmdb:603", imdbId: "tt0133093", tmdbId: 603, type: "movie", name: "The Matrix", year: 1999)

        let repository = StubRefreshRepository(fullByID: [
            "tt0133093": fullA,
            "tmdb:603": fullB
        ])

        let enriched = await SearchResultEnrichment.enrich([rawA, rawB], repository: repository)

        // Post-enrichment deduplication pass must eliminate the duplicate poster
        XCTAssertEqual(enriched.map(\.id), ["tt0133093"])
        XCTAssertEqual(enriched.first?.imdbId, "tt0133093")
        XCTAssertEqual(enriched.first?.tmdbId, 603)
    }

    func testMergingSearchMetadataPreservesAddonPosterWhenPreferAddonArtwork() {
        let addonCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://addon.example/badge-poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil,
            isFromAddon: true
        )
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cinemeta.example/official-poster.jpg",
            backgroundUrl: "https://cinemeta.example/backdrop.jpg",
            logoUrl: "https://cinemeta.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )

        let enriched = addonCard.mergingSearchMetadata(from: full, preferAddonArtwork: true)

        XCTAssertEqual(enriched.posterUrl, "https://addon.example/badge-poster.jpg", "Add-on custom poster must be preserved")
        XCTAssertEqual(enriched.backgroundUrl, "https://cinemeta.example/backdrop.jpg", "Missing backdrop must be filled")
        XCTAssertEqual(enriched.logoUrl, "https://cinemeta.example/logo.png", "Missing logo must be filled")
        XCTAssertEqual(enriched.tmdbId, 1396)
        XCTAssertEqual(enriched.isFromAddon, true)
    }

    func testMergingSearchMetadataReplacesCinemetaPosterWhenNotFromAddon() {
        let cinemetaCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://cinemeta.example/stale-poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil,
            isFromAddon: nil
        )
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cinemeta.example/official-poster.jpg",
            backgroundUrl: "https://cinemeta.example/backdrop.jpg",
            logoUrl: "https://cinemeta.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )

        let enriched = cinemetaCard.mergingSearchMetadata(from: full, preferAddonArtwork: true)

        XCTAssertEqual(enriched.posterUrl, "https://cinemeta.example/official-poster.jpg", "Cinemeta search poster should be refreshed")
    }

    func testMergingSearchMetadataReplacesAddonPosterWhenPreferAddonArtworkIsDisabled() {
        let addonCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://addon.example/badge-poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil,
            isFromAddon: true
        )
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cinemeta.example/official-poster.jpg",
            backgroundUrl: "https://cinemeta.example/backdrop.jpg",
            logoUrl: "https://cinemeta.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )

        let enriched = addonCard.mergingSearchMetadata(from: full, preferAddonArtwork: false)

        XCTAssertEqual(enriched.posterUrl, "https://cinemeta.example/official-poster.jpg", "When preference is disabled, refreshed poster should win")
    }

    func testSearchDeduplicationPrefersAddonPosterOverCinemeta() {
        let cinemetaCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://cinemeta.example/poster.jpg",
            isFromAddon: nil
        )
        let addonCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://addon.example/badge-poster.jpg",
            isFromAddon: true
        )

        // Cinemeta first, Addon second
        let deduplicated1 = CinemetaCatalogRepository.deduplicatedSearchResults([cinemetaCard, addonCard], preferAddonArtwork: true)
        XCTAssertEqual(deduplicated1.count, 1)
        XCTAssertEqual(deduplicated1.first?.posterUrl, "https://addon.example/badge-poster.jpg")
        XCTAssertEqual(deduplicated1.first?.isFromAddon, true)

        // Addon first, Cinemeta second
        let deduplicated2 = CinemetaCatalogRepository.deduplicatedSearchResults([addonCard, cinemetaCard], preferAddonArtwork: true)
        XCTAssertEqual(deduplicated2.count, 1)
        XCTAssertEqual(deduplicated2.first?.posterUrl, "https://addon.example/badge-poster.jpg")
        XCTAssertEqual(deduplicated2.first?.isFromAddon, true)

        // Preference disabled: Cinemeta first wins
        let deduplicated3 = CinemetaCatalogRepository.deduplicatedSearchResults([cinemetaCard, addonCard], preferAddonArtwork: false)
        XCTAssertEqual(deduplicated3.count, 1)
        XCTAssertEqual(deduplicated3.first?.posterUrl, "https://cinemeta.example/poster.jpg")
    }

    func testSearchEnrichmentPreservesAddonPosterDuringBackgroundEnrichment() async {
        let addonCard = makeMeta(
            id: "tt0903747",
            imdbId: nil,
            tmdbId: nil,
            posterUrl: "https://addon.example/badge-poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil,
            isFromAddon: true
        )
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cinemeta.example/refreshed-poster.jpg",
            backgroundUrl: "https://cinemeta.example/backdrop.jpg",
            logoUrl: "https://cinemeta.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )

        let repository = StubRefreshRepository(fullByID: ["tt0903747": full])
        let enriched = await SearchResultEnrichment.enrich([addonCard], repository: repository)

        XCTAssertEqual(enriched.count, 1)
        XCTAssertEqual(enriched.first?.posterUrl, "https://addon.example/badge-poster.jpg", "Add-on poster must not be replaced by Cinemeta")
        XCTAssertEqual(enriched.first?.backgroundUrl, "https://cinemeta.example/backdrop.jpg")
        XCTAssertEqual(enriched.first?.logoUrl, "https://cinemeta.example/logo.png")
        XCTAssertEqual(enriched.first?.tmdbId, 1396)
    }

    func testDecodesStremioLandscapePosterField() throws {
        let json = Data("""
        {"metas":[{
          "id":"tt0903747","type":"series","name":"Breaking Bad",
          "poster":"https://images.example/poster.jpg",
          "landscapePoster":"https://images.example/landscape.jpg",
          "background":"https://images.example/backdrop.jpg",
          "logo":"https://images.example/logo.png"
        }, {
          "id":"tt1375666","type":"movie","name":"Inception",
          "poster":"https://images.example/inception-poster.jpg",
          "landscape_poster":"https://images.example/inception-landscape.jpg"
        }]}
        """.utf8)

        let response = try decoder.decode(CinemetaCatalogResponse.self, from: json)
        let metas = response.metas.map { $0.toMeta(fallbackType: "movie") }

        XCTAssertEqual(metas[0].landscapePosterUrl, "https://images.example/landscape.jpg")
        XCTAssertEqual(metas[0].landscapePoster, "https://images.example/landscape.jpg")
        XCTAssertEqual(metas[0].backdropUrl, "https://images.example/backdrop.jpg")

        XCTAssertEqual(metas[1].landscapePosterUrl, "https://images.example/inception-landscape.jpg")
        XCTAssertEqual(metas[1].landscapePoster, "https://images.example/inception-landscape.jpg")
        XCTAssertEqual(metas[1].backdropUrl, "https://images.example/inception-landscape.jpg")
    }

    func testMergingSearchMetadataPreservesAddonLandscapePosterWhenPreferAddonArtwork() {
        let addonCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://addon.example/badge-poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil,
            isFromAddon: true,
            landscapePosterUrl: "https://addon.example/custom-landscape.jpg"
        )
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cinemeta.example/official-poster.jpg",
            backgroundUrl: "https://cinemeta.example/backdrop.jpg",
            logoUrl: "https://cinemeta.example/logo.png",
            runtime: "47 min",
            status: "Ended",
            landscapePosterUrl: nil
        )

        let enriched = addonCard.mergingSearchMetadata(from: full, preferAddonArtwork: true)

        XCTAssertEqual(enriched.posterUrl, "https://addon.example/badge-poster.jpg", "Add-on custom poster must be preserved")
        XCTAssertEqual(enriched.landscapePosterUrl, "https://addon.example/custom-landscape.jpg", "Add-on custom landscape poster must be preserved")
        XCTAssertEqual(enriched.backgroundUrl, "https://cinemeta.example/backdrop.jpg", "Missing backdrop must be filled")
    }

    func testSearchDeduplicationPrefersAddonLandscapePosterOverCinemeta() {
        let cinemetaCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://cinemeta.example/poster.jpg",
            isFromAddon: nil,
            landscapePosterUrl: nil
        )
        let addonCard = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: nil,
            posterUrl: "https://addon.example/badge-poster.jpg",
            isFromAddon: true,
            landscapePosterUrl: "https://addon.example/custom-landscape.jpg"
        )

        let deduplicated = CinemetaCatalogRepository.deduplicatedSearchResults([cinemetaCard, addonCard], preferAddonArtwork: true)
        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated.first?.landscapePosterUrl, "https://addon.example/custom-landscape.jpg")
        XCTAssertEqual(deduplicated.first?.isFromAddon, true)
    }

    func testPictoriumTemplateResolvesPosterAndLandscapeArtwork() {
        let meta = makeMeta(id: "tmdb:1396", imdbId: nil, tmdbId: nil, type: "movie")
        let pattern = "https://pictorium.elfhosted.com/api/poster/{type}/{tmdb_id|imdb_id}?u=test-space&live=1&rv=b719767aca&shape={shape}"

        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: meta, shape: "poster"),
            "https://pictorium.elfhosted.com/api/poster/movie/1396?u=test-space&live=1&rv=b719767aca&shape=poster"
        )
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: meta, shape: "landscape"),
            "https://pictorium.elfhosted.com/api/poster/movie/1396?u=test-space&live=1&rv=b719767aca&shape=landscape"
        )
    }

    func testPictoriumTemplateUsesOrderedTMDBThenIMDbFallback() {
        let withBothIDs = makeMeta(id: "tt0137523", imdbId: "tt0137523", tmdbId: 550, type: "movie")
        let imdbOnly = makeMeta(id: "tt0137523", imdbId: "tt0137523", tmdbId: nil, type: "movie")
        let namespacedTMDB = makeMeta(id: "tmdb:movie:1396", imdbId: nil, tmdbId: nil, type: "movie")
        let pattern = "https://pictorium.elfhosted.com/api/poster/{type}/{tmdb_id|imdb_id}?u=test-space&shape={shape}"

        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: withBothIDs),
            "https://pictorium.elfhosted.com/api/poster/movie/550?u=test-space&shape=poster"
        )
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: imdbOnly),
            "https://pictorium.elfhosted.com/api/poster/movie/tt0137523?u=test-space&shape=poster"
        )
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: namespacedTMDB),
            "https://pictorium.elfhosted.com/api/poster/movie/1396?u=test-space&shape=poster"
        )
    }

    func testCustomPosterResolverPreservesOriginalWhenRequiredIDIsMissing() {
        let original = "https://catalog.example/original.jpg"
        let meta = makeMeta(id: "catalog:unknown", imdbId: nil, tmdbId: nil, type: "movie", posterUrl: original)
        let pattern = "https://pictorium.elfhosted.com/api/poster/{type}/{tmdb_id|imdb_id}?u=test-space&shape={shape}"

        XCTAssertNil(CustomPosterURLResolver.resolve(pattern: pattern, meta: meta))
        XCTAssertEqual(CustomPosterURLResolver.resolve(pattern: pattern, meta: meta) ?? meta.posterUrl, original)
        XCTAssertNil(CustomPosterURLResolver.resolve(pattern: "https://example.com/{tmdb_id}", meta: meta, shape: "landscape"))
    }

    func testCustomPosterResolverSupportsEncodedTokensAndRejectsUnresolvedOrNonHTTPURLs() {
        let meta = makeMeta(id: "tmdb:1396", imdbId: nil, tmdbId: nil, type: "movie")
        let encodedPattern = "https://pictorium.elfhosted.com/api/poster/%7Btype%7D/%7Btmdb_id%7Cimdb_id%7D?shape=%7Bshape%7D"

        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: encodedPattern, meta: meta, shape: "square"),
            "https://pictorium.elfhosted.com/api/poster/movie/1396?shape=square"
        )
        XCTAssertNil(CustomPosterURLResolver.resolve(pattern: "https://example.com/{unknown}", meta: meta))
        XCTAssertNil(CustomPosterURLResolver.resolve(pattern: "file://example.com/{tmdb_id}", meta: meta))
    }

    func testPostersPlusPatternWithOptionalIDsAndStremioID() {
        let pattern = "https://postersplus.example.com/poster?tmdb_id={tmdb_id?}&imdb_id={imdb_id?}&stremio_id={id}&type={type}&shape={shape}"

        // 1. Movie with IMDb and TMDB
        let movieBoth = makeMeta(id: "tt0137523", imdbId: "tt0137523", tmdbId: 550, type: "movie")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: movieBoth, shape: "poster"),
            "https://postersplus.example.com/poster?tmdb_id=550&imdb_id=tt0137523&stremio_id=tt0137523&type=movie&shape=poster"
        )
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: movieBoth, shape: "landscape"),
            "https://postersplus.example.com/poster?tmdb_id=550&imdb_id=tt0137523&stremio_id=tt0137523&type=movie&shape=landscape"
        )

        // 2. Movie with IMDb ID only -> optional tmdb_id? becomes empty string
        let movieImdbOnly = makeMeta(id: "tt0137523", imdbId: "tt0137523", tmdbId: nil, type: "movie")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: movieImdbOnly, shape: "poster"),
            "https://postersplus.example.com/poster?tmdb_id=&imdb_id=tt0137523&stremio_id=tt0137523&type=movie&shape=poster"
        )

        // 3. Series with TMDB ID only -> optional imdb_id? becomes empty string
        let seriesTmdbOnly = makeMeta(id: "tmdb:1396", imdbId: nil, tmdbId: 1396, type: "series")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: seriesTmdbOnly, shape: "poster"),
            "https://postersplus.example.com/poster?tmdb_id=1396&imdb_id=&stremio_id=tmdb:1396&type=series&shape=poster"
        )

        // 4. Anime with Kitsu ID -> resolves {id} and sets optional IDs to empty
        let animeKitsu = makeMeta(id: "kitsu:7442", imdbId: nil, tmdbId: nil, type: "series")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: pattern, meta: animeKitsu, shape: "poster"),
            "https://postersplus.example.com/poster?tmdb_id=&imdb_id=&stremio_id=kitsu:7442&type=series&shape=poster"
        )

        // 5. Full Posters+ URL with client parameters
        let fullPostersPlus = "https://postersplus.stremio.ru/poster?tmdb_id={tmdb_id}&imdb_id={imdb_id?}&type={type}&primary_client=stremio_tv_nuvio&fallback_to_imdb=true&movie_weights=letterboxd%3A0.99"
        let breakingBad = makeMeta(id: "tmdb:1396", imdbId: "tt0903747", tmdbId: 1396, type: "series")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: fullPostersPlus, meta: breakingBad),
            "https://postersplus.stremio.ru/poster?tmdb_id=1396&imdb_id=tt0903747&type=series&primary_client=stremio_tv_nuvio&fallback_to_imdb=true&movie_weights=letterboxd%3A0.99"
        )
    }

    func testPostersPlusSlokkerInstanceAndJsonPasteHandling() {
        let rawPattern = "https://postersplus.slokker.cc/poster?tmdb_id={tmdb_id?}&imdb_id={imdb_id?}&stremio_id={id}&type={type}&shape={shape}"
        let fightClub = makeMeta(id: "tt0137523", imdbId: "tt0137523", tmdbId: 550, type: "movie")

        // Direct URL resolution for landscape and portrait
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: rawPattern, meta: fightClub, shape: "landscape"),
            "https://postersplus.slokker.cc/poster?tmdb_id=550&imdb_id=tt0137523&stremio_id=tt0137523&type=movie&shape=landscape"
        )
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: rawPattern, meta: fightClub, shape: "poster"),
            "https://postersplus.slokker.cc/poster?tmdb_id=550&imdb_id=tt0137523&stremio_id=tt0137523&type=movie&shape=poster"
        )

        // Pasted JSON configuration with "pattern" key
        let jsonPattern = """
        {"pattern": "https://postersplus.slokker.cc/poster?tmdb_id={tmdb_id?}&imdb_id={imdb_id?}&stremio_id={id}&type={type}&shape={shape}"}
        """
        XCTAssertEqual(
            CustomPosterURLResolver.sanitizePattern(jsonPattern),
            rawPattern
        )
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: jsonPattern, meta: fightClub, shape: "landscape"),
            "https://postersplus.slokker.cc/poster?tmdb_id=550&imdb_id=tt0137523&stremio_id=tt0137523&type=movie&shape=landscape"
        )

        // Pasted JSON configuration with "url" key
        let jsonUrl = """
        {"url": "https://postersplus.slokker.cc/poster?tmdb_id={tmdb_id?}&imdb_id={imdb_id?}&stremio_id={id}&type={type}&shape={shape}"}
        """
        XCTAssertEqual(
            CustomPosterURLResolver.sanitizePattern(jsonUrl),
            rawPattern
        )

        // Quoted string
        let quoted = "\"https://postersplus.slokker.cc/poster?tmdb_id={tmdb_id?}&imdb_id={imdb_id?}&stremio_id={id}&type={type}&shape={shape}\""
        XCTAssertEqual(
            CustomPosterURLResolver.sanitizePattern(quoted),
            rawPattern
        )
    }

    func testUnhandledOptionalTokensResolveToEmptyString() {
        let patternWithExtraOptional = "https://postersplus.slokker.cc/poster?tmdb_id={tmdb_id?}&imdb_id={imdb_id?}&stremio_id={id}&type={type}&shape={shape}&tmdb_key={tmdb_key?}&mdblist_key={mdblist_key?}"
        let fightClub = makeMeta(id: "tt0137523", imdbId: "tt0137523", tmdbId: 550, type: "movie")

        // Extra optional placeholders {tmdb_key?} and {mdblist_key?} resolve to empty string instead of failing
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: patternWithExtraOptional, meta: fightClub, shape: "landscape"),
            "https://postersplus.slokker.cc/poster?tmdb_id=550&imdb_id=tt0137523&stremio_id=tt0137523&type=movie&shape=landscape&tmdb_key=&mdblist_key="
        )
    }

    func testUniversalPatternAndRPDBFamilyAutoFallback() {
        let universalPattern = "https://api.aioratings.com/KEY/{id_type}/poster-default/{typed_id}.jpg"

        // Universal pattern with IMDb
        let imdbMeta = makeMeta(id: "tt0137523", imdbId: "tt0137523", tmdbId: nil, type: "movie")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: universalPattern, meta: imdbMeta),
            "https://api.aioratings.com/KEY/imdb/poster-default/tt0137523.jpg"
        )

        // Universal pattern with TMDB movie
        let tmdbMovie = makeMeta(id: "tmdb:550", imdbId: nil, tmdbId: 550, type: "movie")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: universalPattern, meta: tmdbMovie),
            "https://api.aioratings.com/KEY/tmdb/poster-default/movie-550.jpg"
        )

        // Universal pattern with TMDB series
        let tmdbSeries = makeMeta(id: "tmdb:1396", imdbId: nil, tmdbId: 1396, type: "series")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: universalPattern, meta: tmdbSeries),
            "https://api.aioratings.com/KEY/tmdb/poster-default/series-1396.jpg"
        )

        // RPDB auto-fallback from IMDb to TMDB
        let rpdbPattern = "https://api.ratingposterdb.com/t1-key/imdb/poster-default/{imdb_id}.jpg?fallback=true"
        let missingImdb = makeMeta(id: "tmdb:1396", imdbId: nil, tmdbId: 1396, type: "series")
        XCTAssertEqual(
            CustomPosterURLResolver.resolve(pattern: rpdbPattern, meta: missingImdb),
            "https://api.ratingposterdb.com/t1-key/tmdb/poster-default/series-1396.jpg?fallback=true"
        )
    }

    func testCustomPosterScreenFilterDefaultsToAllAndSupportsExplicitNone() {
        let allScreens = Set(CustomPosterScreen.allCases)
        let pattern = "https://example.com/{tmdb_id}?shape={shape}"
        let meta = makeMeta(id: "tmdb:1396", imdbId: nil, tmdbId: nil)

        XCTAssertEqual(CustomPosterScreen.fromStorageValue(nil), allScreens)
        XCTAssertTrue(CustomPosterScreen.fromStorageValue("none").isEmpty)
        XCTAssertTrue(CustomPosterScreen.fromStorageValue("").isEmpty)
        XCTAssertEqual(
            CustomPosterScreen.storageValue(for: allScreens),
            "home,continue_watching,collections,library,search,details,tv_recommendations"
        )
        XCTAssertNotNil(CustomPosterURLResolver.resolve(
            pattern: pattern,
            meta: meta,
            screen: .search,
            enabledScreens: "home,search"
        ))
        XCTAssertNil(CustomPosterURLResolver.resolve(
            pattern: pattern,
            meta: meta,
            screen: .library,
            enabledScreens: "home,search"
        ))
        XCTAssertNil(CustomPosterURLResolver.resolve(
            pattern: pattern,
            meta: meta,
            screen: .home,
            enabledScreens: "none"
        ))
    }

    private func makeMeta(
        id: String,
        imdbId: String?,
        tmdbId: Int?,
        type: String = "series",
        name: String = "Test Title",
        year: Int? = nil,
        releaseInfo: String? = nil,
        posterUrl: String? = "https://cdn.example/poster.jpg",
        backgroundUrl: String? = "bg",
        logoUrl: String? = "logo",
        runtime: String? = "45 min",
        status: String? = "Ended",
        isFromAddon: Bool? = nil,
        landscapePosterUrl: String? = nil
    ) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: nil,
            posterUrl: posterUrl,
            backgroundUrl: backgroundUrl,
            logoUrl: logoUrl,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: year,
            genres: nil,
            rating: nil,
            releaseInfo: releaseInfo ?? year.map(String.init),
            runtime: runtime,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: status,
            isFromAddon: isFromAddon,
            landscapePosterUrl: landscapePosterUrl
        )
    }
}

/// Repository stub whose `/meta` refresh answers from a fixed table, so the
/// search-enrichment helper can be tested without network access.
private final class StubRefreshRepository: MockCatalogRepository {
    private let fullByID: [String: NuvioMeta]

    init(fullByID: [String: NuvioMeta]) {
        self.fullByID = fullByID
    }

    override func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let full = fullByID[id] { return full }
        throw URLError(.badServerResponse)
    }
}

import XCTest
import AetherEngine
@testable import NuvioTV

@MainActor
private final class CountingSceneFrameProvider: SceneFrameProviding {
    var isSupported: Bool { false }
    var capabilityMessage: String? { "Test frame unavailable" }
    var onCapture: (() -> Void)?

    func captureCurrentFrame(maxWidth: Int, context: SceneContext) async -> SceneFrame? {
        onCapture?()
        return nil
    }
}

@MainActor
private final class PausedFrameSceneProvider: SceneFrameProviding {
    let isSupported = true
    let capabilityMessage: String? = nil
    var onCapture: (() -> Void)?
    private(set) var captureCount = 0
    private let image: CGImage

    init() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        self.image = context.makeImage()!
    }

    func captureCurrentFrame(maxWidth: Int, context: SceneContext) async -> SceneFrame? {
        captureCount += 1
        onCapture?()
        return SceneFrame(
            image: image,
            sourceTime: 10.0,
            sessionID: context.sessionID,
            generation: context.timelineGeneration
        )
    }
}

@MainActor
private final class DelayedSceneFrameProvider: SceneFrameProviding {
    let isSupported = true
    let capabilityMessage: String? = nil
    private(set) var captureCount = 0
    private(set) var cancelledCaptureCount = 0
    var onCapture: ((Int) -> Void)?
    var onCancelledCapture: ((Int) -> Void)?

    private let image: CGImage
    private var pendingCaptures: [(SceneContext, CheckedContinuation<SceneFrame?, Never>)] = []

    init() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        image = context.makeImage()!
    }

    func captureCurrentFrame(maxWidth: Int, context: SceneContext) async -> SceneFrame? {
        captureCount += 1
        let requestID = captureCount
        onCapture?(requestID)
        let result = await withCheckedContinuation { continuation in
            pendingCaptures.append((context, continuation))
        }
        if Task.isCancelled {
            cancelledCaptureCount += 1
            onCancelledCapture?(requestID)
        }
        // Deliberately return the late value even when cancelled. The coordinator must fence it.
        return result
    }

    func resumeNext(withFrame: Bool) {
        guard !pendingCaptures.isEmpty else { return }
        let (context, continuation) = pendingCaptures.removeFirst()
        let frame = withFrame
            ? SceneFrame(
                image: image,
                sourceTime: 10,
                sessionID: context.sessionID,
                generation: context.timelineGeneration
            )
            : nil
        continuation.resume(returning: frame)
    }
}

private struct EmptySceneCastProvider: SceneCastProviding {
    func fetchCast(context: SceneContext) async throws -> [SceneCastCandidate] { [] }
}

private struct EmptySceneSoundtrackProvider: SceneSoundtrackProviding {
    func fetchSoundtrack(context: SceneContext) async throws -> [SceneTimelineInterval] { [] }
}

private actor StartupCallbackGate {
    private var isHeld = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var waitingContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        waitingContinuation?.resume()
        waitingContinuation = nil
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { waitingContinuation = $0 }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

@MainActor
final class SceneLifecycleTests: XCTestCase {

    @MainActor
    func testCoordinatorDispatchWitnessBelongsOnlyToCurrentGeneration() {
        var engineSetting = "AetherEngine"
        var dispatchedGenerations: [UInt64] = []
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { engineSetting },
            loadDispatcher: { _, _, generation in dispatchedGenerations.append(generation) }
        )

        coordinator.load(PlaybackLoadRequest(videoURL: URL(string: "https://example.test/first.mkv")!))
        let undispatchedGeneration = coordinator.loadGeneration
        XCTAssertFalse(coordinator.hasDispatchedCurrentLoad(generation: undispatchedGeneration))

        engineSetting = "MPVKit"
        coordinator.load(PlaybackLoadRequest(videoURL: URL(string: "https://example.test/second.mkv")!))
        let dispatchedGeneration = coordinator.loadGeneration
        XCTAssertTrue(coordinator.hasDispatchedCurrentLoad(generation: dispatchedGeneration))
        XCTAssertFalse(coordinator.hasDispatchedCurrentLoad(generation: undispatchedGeneration))
        XCTAssertEqual(dispatchedGenerations, [dispatchedGeneration])

        coordinator.stopAll()
        XCTAssertFalse(coordinator.hasDispatchedCurrentLoad(generation: dispatchedGeneration))
    }

    func testAetherPresentationRequiresCurrentLoadEngineEpochAndPresentingCheckpoint() {
        XCTAssertFalse(AetherStartupLoadPresentationPolicy.isPresented(
            expectedLoadGeneration: 8,
            ownerLoadGeneration: 7,
            engineGenerationFloor: 14,
            progressGeneration: 14,
            checkpointIsPresenting: true
        ), "A ready frame owned by the outgoing load cannot present the replacement")

        XCTAssertFalse(AetherStartupLoadPresentationPolicy.isPresented(
            expectedLoadGeneration: 8,
            ownerLoadGeneration: 8,
            engineGenerationFloor: 14,
            progressGeneration: 13,
            checkpointIsPresenting: true
        ), "An engine progress event below the dispatch epoch is stale")

        XCTAssertFalse(AetherStartupLoadPresentationPolicy.isPresented(
            expectedLoadGeneration: 8,
            ownerLoadGeneration: 8,
            engineGenerationFloor: 14,
            progressGeneration: 14,
            checkpointIsPresenting: false
        ), "A new engine generation must reach the presenting checkpoint")

        XCTAssertTrue(AetherStartupLoadPresentationPolicy.isPresented(
            expectedLoadGeneration: 8,
            ownerLoadGeneration: 8,
            engineGenerationFloor: 14,
            progressGeneration: 14,
            checkpointIsPresenting: true
        ), "A fast current load is accepted without requiring an observed loading phase")

        XCTAssertFalse(AetherStartupLoadPresentationPolicy.isPresented(
            expectedLoadGeneration: 8,
            ownerLoadGeneration: nil,
            engineGenerationFloor: 14,
            progressGeneration: 14,
            checkpointIsPresenting: true
        ), "A context without a current load owner cannot claim presentation")
    }

    func testDispatchCheckpointEstablishesEngineBoundaryAndResetsForNextPlayback() {
        var now = Date(timeIntervalSince1970: 100)
        let benchmark = PlaybackStartupBenchmark(dateProvider: { now })

        let firstToken = benchmark.start()
        XCTAssertEqual(benchmark.t0_initiated, now)

        now = now.addingTimeInterval(7)
        benchmark.markEngineCheckpoint("dispatched", token: firstToken)
        let dispatchTime = now
        XCTAssertEqual(benchmark.t_engineDispatched, dispatchTime)

        now = now.addingTimeInterval(3)
        benchmark.markEngineCheckpoint("dispatched", token: firstToken)
        XCTAssertEqual(benchmark.t_engineDispatched, dispatchTime, "The first dispatch checkpoint defines the engine boundary")

        let nextToken = benchmark.start(title: "Next playback")
        XCTAssertEqual(benchmark.t0_initiated, now)
        XCTAssertNil(benchmark.t_engineDispatched, "A new playback must not inherit the prior engine boundary")

        benchmark.markEngineCheckpoint("dispatched", token: firstToken)
        benchmark.cancel(token: firstToken)
        XCTAssertEqual(benchmark.activeToken, nextToken, "Cancelling an old request must leave the new owner intact")
        XCTAssertEqual(benchmark.title, "Next playback")
        benchmark.cancel(token: nextToken)
        XCTAssertNil(benchmark.t_engineDispatched, "Cancelling startup must clear the engine boundary")
    }

    func testDelayedOlderOwnerSourceAndDebridCallbacksCannotMutateNewPlayback() async {
        var now = Date(timeIntervalSince1970: 175)
        let benchmark = PlaybackStartupBenchmark(dateProvider: { now })
        let oldToken = benchmark.start(title: "Old playback")
        let oldStream = NuvioStream(url: nil, name: "Old stream", description: nil, addonName: "Old addon")
        let callbackGate = StartupCallbackGate()
        let delayedCallback = Task {
            await callbackGate.hold()
            benchmark.markSourcePicked(stream: oldStream, token: oldToken)
            benchmark.markDebridResolved(token: oldToken)
        }
        await callbackGate.waitUntilHeld()

        now = now.addingTimeInterval(2)
        let currentToken = benchmark.start(title: "Current playback")
        let currentStream = NuvioStream(url: nil, name: "Current stream", description: nil, addonName: "Current addon")
        now = now.addingTimeInterval(0.4)
        benchmark.markSourcePicked(stream: currentStream, token: currentToken)
        let currentSourceTime = benchmark.t1_sourcePicked
        let currentStartTime = benchmark.t0_initiated

        benchmark.cancel(token: oldToken)
        await callbackGate.release()
        await delayedCallback.value

        XCTAssertEqual(benchmark.activeToken, currentToken)
        XCTAssertEqual(benchmark.title, "Current playback")
        XCTAssertEqual(benchmark.streamName, "Current stream")
        XCTAssertEqual(benchmark.addonName, "Current addon")
        XCTAssertEqual(benchmark.t0_initiated, currentStartTime)
        XCTAssertEqual(benchmark.t1_sourcePicked, currentSourceTime)
        XCTAssertNil(benchmark.t2_debridResolved)
    }

    func testMissingCanceledAndCompletedBenchmarkOwnersCannotMutateTiming() {
        var now = Date(timeIntervalSince1970: 150)
        let benchmark = PlaybackStartupBenchmark(dateProvider: { now })
        let cancelledToken = benchmark.start(title: "Cancelled")
        benchmark.cancel(token: cancelledToken)
        XCTAssertNil(benchmark.activeToken)

        let activeToken = benchmark.start(title: "Active")
        let activeStartTime = benchmark.t0_initiated
        let stream = NuvioStream(url: nil, name: "Current source", description: nil, addonName: "Addon")
        benchmark.markSourcePicked(stream: stream, token: nil)
        benchmark.markSourcePicked(stream: stream, token: cancelledToken)
        benchmark.markDebridResolved(token: nil)
        benchmark.markEngineCheckpoint("dispatched", token: cancelledToken)
        XCTAssertEqual(benchmark.title, "Active")
        XCTAssertEqual(benchmark.streamName, "")
        XCTAssertEqual(benchmark.addonName, "")
        XCTAssertEqual(benchmark.t0_initiated, activeStartTime)
        XCTAssertNil(benchmark.t1_sourcePicked, "Nil and cancelled owners cannot write source metadata")
        XCTAssertNil(benchmark.t2_debridResolved)
        XCTAssertNil(benchmark.t_engineDispatched)

        benchmark.markSourcePicked(stream: stream, token: activeToken)
        let activeSourceTime = benchmark.t1_sourcePicked
        let activeTitle = benchmark.title
        let activeStreamName = benchmark.streamName
        let activeAddonName = benchmark.addonName
        now = now.addingTimeInterval(0.25)
        XCTAssertNotNil(benchmark.markPlaybackStarted(token: activeToken))
        let completedAt = benchmark.t3_playbackStarted

        now = now.addingTimeInterval(1)
        benchmark.markSourcePicked(stream: stream, token: activeToken)
        benchmark.markDebridResolved(token: activeToken)
        benchmark.markEngineCheckpoint("dispatched", token: activeToken)
        benchmark.cancel(token: activeToken)
        XCTAssertEqual(benchmark.title, activeTitle)
        XCTAssertEqual(benchmark.streamName, activeStreamName)
        XCTAssertEqual(benchmark.addonName, activeAddonName)
        XCTAssertEqual(benchmark.t0_initiated, activeStartTime)
        XCTAssertEqual(benchmark.t1_sourcePicked, activeSourceTime)
        XCTAssertEqual(benchmark.t3_playbackStarted, completedAt)
        XCTAssertNil(benchmark.t2_debridResolved)
        XCTAssertNil(benchmark.t_engineDispatched)
        XCTAssertNil(benchmark.activeToken)
    }

    func testSourceSelectionAndDebridCheckpointsCompleteStartupTiming() {
        var now = Date(timeIntervalSince1970: 200)
        let benchmark = PlaybackStartupBenchmark(dateProvider: { now })

        let token = benchmark.start(title: "Episode 2")
        XCTAssertEqual(benchmark.t0_initiated, now)

        now = now.addingTimeInterval(0.4)
        let dummyStream = NuvioStream(url: nil, name: "Debrid Stream", description: nil, addonName: "Torrentio")
        benchmark.markSourcePicked(stream: dummyStream, token: token)
        XCTAssertEqual(benchmark.t1_sourcePicked, now)
        XCTAssertEqual(benchmark.streamName, "Debrid Stream")
        XCTAssertEqual(benchmark.addonName, "Torrentio")

        now = now.addingTimeInterval(0.1)
        let fallbackStream = NuvioStream(url: nil, name: "Fallback Stream", description: nil, addonName: "Fallback addon")
        benchmark.markSourcePicked(stream: fallbackStream, token: token)
        XCTAssertEqual(benchmark.t1_sourcePicked, now)
        XCTAssertEqual(benchmark.streamName, "Fallback Stream")
        XCTAssertEqual(benchmark.addonName, "Fallback addon")

        now = now.addingTimeInterval(0.2)
        benchmark.markDebridResolved(token: token)
        XCTAssertEqual(benchmark.t2_debridResolved, now)

        now = now.addingTimeInterval(0.5)
        benchmark.markEngineCheckpoint("dispatched", token: token)
        XCTAssertEqual(benchmark.t_engineDispatched, now)

        now = now.addingTimeInterval(0.2)
        let total = benchmark.markPlaybackStarted(token: token)
        XCTAssertNotNil(total)
        if let total {
            XCTAssertEqual(total, 1.4, accuracy: 0.001)
        }
        XCTAssertEqual(benchmark.t3_playbackStarted, now)
    }
    
    func testSceneContextInitializationAndEquivalence() {
        let sessionID = UUID()
        let context1 = SceneContext(
            canonicalId: "movie-123",
            mediaType: "movie",
            title: "Test Movie",
            sessionID: sessionID,
            timelineGeneration: 1
        )
        let context2 = SceneContext(
            canonicalId: "movie-123",
            mediaType: "movie",
            title: "Test Movie",
            sessionID: sessionID,
            timelineGeneration: 1
        )
        
        XCTAssertEqual(context1, context2)
        XCTAssertEqual(context1.canonicalId, "movie-123")
        XCTAssertEqual(context1.timelineGeneration, 1)
    }
    
    func testCoordinatorGenerationIncrementsOnSeekAndReset() {
        let coordinator = SceneCoordinator(
            frameProvider: UnsupportedSceneFrameProvider()
        )
        
        coordinator.openPanel()
        XCTAssertTrue(coordinator.isPanelOpen)
        
        // Seek increments generation
        coordinator.handleSeek()
        XCTAssertEqual(coordinator.currentSnapshot.actors, [])
        
        // Reset session on new source
        coordinator.resetSession()
        XCTAssertFalse(coordinator.isPanelOpen)
        XCTAssertEqual(coordinator.currentSnapshot, .empty)
    }

    func testActorResultsClearWhenCurrentSceneHasNoMatch() {
        let coordinator = SceneCoordinator(frameProvider: UnsupportedSceneFrameProvider())
        let actor = SceneRecognizedActor(id: "1", name: "Actor")

        coordinator.updateActorStatus(.recognized([actor]))
        XCTAssertEqual(coordinator.currentSnapshot.actors, [actor])

        coordinator.updateActorStatus(.noMatch)
        XCTAssertTrue(coordinator.currentSnapshot.actors.isEmpty)
        XCTAssertEqual(coordinator.currentSnapshot.actorStatus, .noMatch)

        coordinator.updateActorStatus(.recognized([actor]))
        coordinator.openPanel()
        XCTAssertTrue(coordinator.currentSnapshot.actors.isEmpty)
        XCTAssertEqual(coordinator.currentSnapshot.actorStatus, .analyzing)
        coordinator.closePanel()
    }

    func testTimelineSongAppearsWithoutAutomaticShazamSubscription() async {
        let context = SceneContext(canonicalId: "timeline-song-test", mediaType: "movie", title: "Timeline Song Test")
        let song = SceneRecognizedSong(
            id: "timeline-song-1",
            title: "Timeline Song",
            artist: "Timeline Artist",
            artworkURL: URL(string: "https://example.com/artwork.jpg"),
            observedSourceTime: 20,
            startTime: 10,
            endTime: 30
        )
        let cache = SceneResultCache()
        await cache.storeTimelineInterval(SceneTimelineInterval(
            canonicalId: context.canonicalId,
            startTime: 10,
            endTime: 30,
            actors: [],
            song: song
        ))

        let broker = PlaybackAudioTapBroker(engine: nil)
        let coordinator = SceneCoordinator(
            frameProvider: UnsupportedSceneFrameProvider(),
            castProvider: EmptySceneCastProvider(),
            soundtrackProvider: EmptySceneSoundtrackProvider(),
            audioTapBroker: broker,
            resultCache: cache
        )
        coordinator.updateContext(context)
        coordinator.setPlaybackProviders(isPlaying: { true }, sourceTime: { 20 })

        coordinator.openPanel()

        for _ in 0..<20 where coordinator.currentSnapshot.song == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(coordinator.currentSnapshot.song?.title, "Timeline Song")
        XCTAssertFalse(broker.hasActiveSubscribers, "Timeline song lookup must not subscribe to the audio tap")
        coordinator.closePanel()
    }

    func testSeekRestartsSceneSamplingWhilePanelIsOpen() async {
        let frameProvider = CountingSceneFrameProvider()
        let coordinator = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: EmptySceneCastProvider()
        )
        coordinator.updateContext(SceneContext(canonicalId: "movie-1", mediaType: "movie", title: "Movie"))
        coordinator.setPlaybackProviders(isPlaying: { true }, sourceTime: { 10 })
        coordinator.openPanel()

        let capturedAfterSeek = expectation(description: "Frame sampled after seek")
        frameProvider.onCapture = { capturedAfterSeek.fulfill() }
        coordinator.handleSeek()

        await fulfillment(of: [capturedAfterSeek], timeout: 2)
        coordinator.closePanel()
    }

    func testPauseDuringAnalysisQueuesOneStillCapture() async {
        let frameProvider = PausedFrameSceneProvider()
        let coordinator = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: EmptySceneCastProvider()
        )
        coordinator.updateContext(SceneContext(
            canonicalId: "movie-paused",
            mediaType: "movie",
            title: "Paused Movie",
            sessionID: UUID(),
            timelineGeneration: 1
        ))
        var isPlaying = true
        coordinator.setPlaybackProviders(isPlaying: { isPlaying }, sourceTime: { 10.0 })

        let initialCapture = expectation(description: "initial frame capture starts")
        let pausedCapture = expectation(description: "One still is captured after analysis finishes")
        frameProvider.onCapture = {
            if frameProvider.captureCount == 1 {
                initialCapture.fulfill()
            } else if frameProvider.captureCount == 2 {
                pausedCapture.fulfill()
            }
        }

        coordinator.openPanel()
        await fulfillment(of: [initialCapture], timeout: 2)
        XCTAssertEqual(frameProvider.captureCount, 1)
        isPlaying = false
        coordinator.handlePlaybackPaused()
        XCTAssertEqual(frameProvider.captureCount, 1, "Pause during analysis should queue rather than overlap a capture")

        await fulfillment(of: [pausedCapture], timeout: 3)
        XCTAssertEqual(frameProvider.captureCount, 2)
        coordinator.closePanel()
    }

    func testPausedReopenQueuesCaptureAfterOlderAnalysisFinishes() async {
        let frameProvider = PausedFrameSceneProvider()
        let coordinator = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: EmptySceneCastProvider()
        )
        coordinator.updateContext(SceneContext(
            canonicalId: "movie-reopened-paused",
            mediaType: "movie",
            title: "Paused Reopen Movie",
            sessionID: UUID(),
            timelineGeneration: 1
        ))
        var isPlaying = true
        coordinator.setPlaybackProviders(isPlaying: { isPlaying }, sourceTime: { 10.0 })

        let initialCapture = expectation(description: "initial frame capture starts")
        let reopenedCapture = expectation(description: "Paused reopened panel captures after prior analysis")
        frameProvider.onCapture = {
            if frameProvider.captureCount == 1 {
                initialCapture.fulfill()
            } else if frameProvider.captureCount == 2 {
                reopenedCapture.fulfill()
            }
        }

        coordinator.openPanel()
        await fulfillment(of: [initialCapture], timeout: 2)
        XCTAssertEqual(frameProvider.captureCount, 1)
        coordinator.closePanel()
        isPlaying = false
        coordinator.openPanel()
        XCTAssertEqual(frameProvider.captureCount, 1, "Reopen should queue while the old analysis still owns capture")

        await fulfillment(of: [reopenedCapture], timeout: 3)
        XCTAssertEqual(frameProvider.captureCount, 2)
        coordinator.closePanel()
    }

    func testDelayedCaptureIsSingleFlightAndDropsCancelledSessionFallback() async throws {
        let frameProvider = DelayedSceneFrameProvider()
        let actorRecognition = ActorRecognitionService()
        let resultCache = SceneResultCache()
        let staleActor = SceneRecognizedActor(id: "old-session-actor", name: "Old Session Actor", character: "Old")
        let oldContext = SceneContext(
            canonicalId: "movie-before-session-switch",
            mediaType: "movie",
            title: "Old Session",
            sessionID: UUID(),
            timelineGeneration: 1
        )
        await resultCache.storeTimelineInterval(SceneTimelineInterval(
            id: "old-session-interval",
            canonicalId: oldContext.canonicalId,
            startTime: 0,
            endTime: 30,
            actors: [staleActor]
        ))

        let coordinator = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: EmptySceneCastProvider(),
            actorRecognition: actorRecognition,
            resultCache: resultCache
        )
        coordinator.updateContext(oldContext)
        coordinator.setPlaybackProviders(isPlaying: { false }, sourceTime: { 10 })

        let firstCaptureStarted = expectation(description: "first asynchronous capture starts")
        let reopenedCaptureStarted = expectation(description: "paused reopened capture starts")
        let firstCaptureCancelled = expectation(description: "old session capture observes cancellation")
        let reopenedCaptureCancelled = expectation(description: "reopened capture observes close cancellation")
        frameProvider.onCapture = { count in
            if count == 1 { firstCaptureStarted.fulfill() }
            if count == 2 { reopenedCaptureStarted.fulfill() }
        }
        frameProvider.onCancelledCapture = { count in
            if count == 1 { firstCaptureCancelled.fulfill() }
            if count == 2 { reopenedCaptureCancelled.fulfill() }
        }

        coordinator.openPanel()
        await fulfillment(of: [firstCaptureStarted], timeout: 2)
        XCTAssertEqual(frameProvider.captureCount, 1)
        coordinator.handlePlaybackPaused()
        XCTAssertEqual(frameProvider.captureCount, 1, "paused requests queue behind the in-flight capture")

        let newContext = SceneContext(
            canonicalId: "movie-after-session-switch",
            mediaType: "movie",
            title: "New Session",
            sessionID: UUID(),
            timelineGeneration: 2
        )
        coordinator.updateContext(newContext)
        await actorRecognition.resetTemporalTracking()
        coordinator.openPanel()
        XCTAssertEqual(frameProvider.captureCount, 1, "reopen waits for ownership of the old capture to finish")

        frameProvider.resumeNext(withFrame: false)
        await fulfillment(of: [firstCaptureCancelled, reopenedCaptureStarted], timeout: 2)
        XCTAssertEqual(frameProvider.cancelledCaptureCount, 1)
        let trackedAfterStaleFallback = await actorRecognition.currentTrackedActors(at: 10)
        XCTAssertFalse(
            trackedAfterStaleFallback.contains(where: { $0.id == staleActor.id }),
            "the old session's cached timeline must not be recorded after its capture is cancelled"
        )
        XCTAssertEqual(frameProvider.captureCount, 2)

        coordinator.closePanel()
        frameProvider.resumeNext(withFrame: true)
        await fulfillment(of: [reopenedCaptureCancelled], timeout: 2)
        XCTAssertEqual(frameProvider.cancelledCaptureCount, 2)
    }
    
    func testResultCacheStorageAndRetrieval() async {
        let cache = SceneResultCache()
        let context = SceneContext(
            canonicalId: "movie-456",
            mediaType: "movie",
            title: "Inception",
            timelineGeneration: 1
        )
        
        let actor = SceneRecognizedActor(id: "1", name: "Leonardo DiCaprio", character: "Cobb")
        let snapshot = SceneSnapshot(
            timestamp: 10.5,
            actors: [actor],
            song: nil,
            actorStatus: .recognized([actor]),
            musicStatus: .disabled,
            generation: 1
        )
        
        // Store in cache
        await cache.store(snapshot: snapshot, context: context, sourceTime: 10.5)
        
        // Retrieve within the same 5-second bucket (10.0 - 15.0)
        let cached = await cache.snapshot(for: context, sourceTime: 12.0)
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.actors.first?.name, "Leonardo DiCaprio")
        
        // Retrieval in distant bucket returns nil
        let missed = await cache.snapshot(for: context, sourceTime: 45.0)
        XCTAssertNil(missed)
        
        // Clear cache
        await cache.clear()
        let cleared = await cache.snapshot(for: context, sourceTime: 12.0)
        XCTAssertNil(cleared)
    }
    
    func testPlaybackAudioTapBrokerReferenceCounting() {
        let broker = PlaybackAudioTapBroker(engine: nil)
        XCTAssertFalse(broker.hasActiveSubscribers)
        
        let sub1 = broker.subscribe()
        XCTAssertTrue(broker.hasActiveSubscribers)
        
        let sub2 = broker.subscribe()
        XCTAssertTrue(broker.hasActiveSubscribers)
        
        broker.unsubscribe(id: sub1.id)
        XCTAssertTrue(broker.hasActiveSubscribers)
        
        broker.unsubscribe(id: sub2.id)
        XCTAssertFalse(broker.hasActiveSubscribers)
    }
    
    func testSceneTimelineDatabaseIntervalLookupAndMatching() async {
        let cache = SceneResultCache()
        let context = SceneContext(
            canonicalId: "the-batman",
            mediaType: "movie",
            title: "The Batman"
        )
        
        let actor = SceneRecognizedActor(
            id: "pattinson",
            name: "Robert Pattinson",
            character: "Bruce Wayne / Batman"
        )
        
        // 00:45:31 (2731.0s) to 00:46:07 (2767.0s)
        let interval = SceneTimelineInterval(
            id: "batman-scene-1",
            canonicalId: "the-batman",
            startTime: 2731.0,
            endTime: 2767.0,
            actors: [actor]
        )
        
        await cache.storeTimelineInterval(interval)
        
        // Query inside interval: 00:45:45 (2745.0s)
        let match = await cache.findTimelineInterval(for: context, sourceTime: 2745.0)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.actors.first?.name, "Robert Pattinson")
        XCTAssertEqual(match?.actors.first?.character, "Bruce Wayne / Batman")
        
        // Query outside interval: 00:50:00 (3000.0s)
        let miss = await cache.findTimelineInterval(for: context, sourceTime: 3000.0)
        XCTAssertNil(miss)
    }
    
    func testDualPathSceneCoordinatorPrefersDatabaseWhenModelUnavailable() async {
        let cache = SceneResultCache()
        let context = SceneContext(
            canonicalId: "the-batman",
            mediaType: "movie",
            title: "The Batman"
        )
        
        let actor = SceneRecognizedActor(
            id: "pattinson",
            name: "Robert Pattinson",
            character: "Bruce Wayne / Batman"
        )
        let interval = SceneTimelineInterval(
            id: "batman-scene-1",
            canonicalId: "the-batman",
            startTime: 100.0,
            endTime: 120.0,
            actors: [actor]
        )
        await cache.storeTimelineInterval(interval)
        
        // Coordinator with unsupported frame provider (no local camera/model)
        let coordinator = SceneCoordinator(
            frameProvider: UnsupportedSceneFrameProvider(),
            resultCache: cache
        )
        coordinator.updateContext(context)
        coordinator.setPlaybackProviders(isPlaying: { true }, sourceTime: { 110.0 })
        
        coordinator.openPanel()
        
        // Allow async database task to populate snapshot
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Pre-indexed database supplies the actors even without a local ML model
        XCTAssertEqual(coordinator.currentSnapshot.actors.first?.name, "Robert Pattinson")
        XCTAssertEqual(coordinator.currentSnapshot.actors.first?.character, "Bruce Wayne / Batman")
    }
    
    func testDynamicPlayerSceneFrameProviderMPVFallback() async {
        let currentBackend: PlayerBackendKind = .mpv
        let dynamicProvider = DynamicPlayerSceneFrameProvider(
            activeEngineKindProvider: { currentBackend },
            aetherControllerProvider: { nil }
        )
        
        // When running on MPV, reports honest unsupported status without crashing
        XCTAssertFalse(dynamicProvider.isSupported)
        XCTAssertEqual(
            dynamicProvider.capabilityMessage,
            "MPV backend does not support direct display pipeline frame capture."
        )
        
        let dummyContext = SceneContext(
            canonicalId: "movie-1",
            mediaType: "movie",
            title: "Movie"
        )
        let frame = await dynamicProvider.captureCurrentFrame(maxWidth: 960, context: dummyContext)
        XCTAssertNil(frame)
    }

    func testSceneCoordinatorPrewarmFetchesCastWithoutOpeningPanel() async throws {
        let candidate = SceneCastCandidate(
            id: "cast-1",
            name: "Cillian Murphy",
            character: "J. Robert Oppenheimer",
            profileURL: nil,
            tmdbId: 2037
        )
        let castProvider = StubSceneCastProvider(candidates: [candidate])
        let frameProvider = CountingSceneFrameProvider()
        var captureCount = 0
        let firstCaptureStarted = expectation(description: "opening the panel starts frame capture")
        frameProvider.onCapture = {
            captureCount += 1
            if captureCount == 1 {
                firstCaptureStarted.fulfill()
            }
        }
        
        let coordinator = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: castProvider
        )
        
        let context = SceneContext(
            canonicalId: "movie-oppenheimer",
            mediaType: "movie",
            title: "Oppenheimer"
        )
        
        coordinator.prewarm(context: context)
        
        // Allow async cast fetch task to finish
        for _ in 0..<20 {
            if !coordinator.castCandidates.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        
        // Assert pre-warmed state:
        XCTAssertFalse(coordinator.isPanelOpen)
        XCTAssertEqual(coordinator.castCandidates.count, 1)
        XCTAssertEqual(coordinator.castCandidates.first?.name, "Cillian Murphy")
        XCTAssertEqual(castProvider.fetchCount, 1)
        XCTAssertEqual(captureCount, 0, "Pre-warming must never capture video frames while panel is closed")
        
        // Subsequent openPanel should use pre-warmed cast without re-fetching
        coordinator.openPanel()
        XCTAssertTrue(coordinator.isPanelOpen)
        XCTAssertEqual(castProvider.fetchCount, 1, "Opening panel should not re-fetch already pre-warmed cast")
        await fulfillment(of: [firstCaptureStarted], timeout: 2)
        XCTAssertGreaterThanOrEqual(captureCount, 1, "Opening panel should initiate frame capture")
    }
    
    func testAnimeContextPopulatesEpisodeCastAndBypassesFrameCapture() async throws {
        let animeCandidates = [
            SceneCastCandidate(id: "1", name: "Yuki Kaji", character: "Eren Yeager (voice)", tmdbId: 101),
            SceneCastCandidate(id: "2", name: "Yui Ishikawa", character: "Mikasa Ackerman (voice)", tmdbId: 102),
            SceneCastCandidate(id: "3", name: "Marina Inoue", character: "Armin Arlert (voice)", tmdbId: 103)
        ]
        let castProvider = StubSceneCastProvider(candidates: animeCandidates)
        let frameProvider = CountingSceneFrameProvider()
        var captureCount = 0
        frameProvider.onCapture = {
            captureCount += 1
        }
        
        let coordinator = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: castProvider
        )
        
        let animeContext = SceneContext(
            canonicalId: "kitsu:1234:1",
            mediaType: "series",
            title: "Attack on Titan",
            season: 1,
            episode: 1,
            isAnime: true
        )
        
        coordinator.updateContext(animeContext)
        XCTAssertTrue(coordinator.isAnime)
        
        coordinator.openPanel()
        XCTAssertTrue(coordinator.isPanelOpen)
        
        // Allow async cast fetch task to finish
        for _ in 0..<20 {
            if !coordinator.currentSnapshot.actors.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        
        // Assert: all anime episode voice actors are immediately populated and recognized!
        XCTAssertEqual(coordinator.currentSnapshot.actors.count, 3)
        XCTAssertEqual(coordinator.currentSnapshot.actors.map(\.name), ["Yuki Kaji", "Yui Ishikawa", "Marina Inoue"])
        XCTAssertEqual(coordinator.currentSnapshot.actors.first?.character, "Eren Yeager (voice)")
        XCTAssertEqual(coordinator.currentSnapshot.actorStatus, .recognized(coordinator.currentSnapshot.actors))
        
        // Frame capture for facial recognition must be bypassed for anime
        XCTAssertEqual(captureCount, 0, "Anime media must bypass visual face capture and directly show full episode cast")
        
        // Seeking in anime preserves the full episode cast
        coordinator.handleSeek()
        XCTAssertEqual(coordinator.currentSnapshot.actors.count, 3)
        XCTAssertEqual(coordinator.currentSnapshot.actors.map(\.name), ["Yuki Kaji", "Yui Ishikawa", "Marina Inoue"])
    }
}

extension SceneLifecycleTests {
    @MainActor
    func testSceneCaptureIdentityRejectsNativeItemReplacement() {
        let player = NSObject()
        let firstItem = NSObject()
        let replacementItem = NSObject()
        let captured = AetherSceneFrameAnalysisIdentity(
            hostGeneration: 7,
            engineStartupGeneration: 12,
            nativePlayer: player,
            nativeItem: firstItem)
        let unchanged = AetherSceneFrameAnalysisIdentity(
            hostGeneration: 7,
            engineStartupGeneration: 12,
            nativePlayer: player,
            nativeItem: firstItem)
        let itemReplaced = AetherSceneFrameAnalysisIdentity(
            hostGeneration: 7,
            engineStartupGeneration: 12,
            nativePlayer: player,
            nativeItem: replacementItem)

        XCTAssertTrue(AetherPlaybackController.sceneFrameAnalysisIdentityMatches(captured, current: unchanged))
        XCTAssertFalse(AetherPlaybackController.sceneFrameAnalysisIdentityMatches(captured, current: itemReplaced))
    }

    @MainActor
    func testSceneDV8PrimarySuccessReturnsUnchangedWithoutSourceFallback() async {
        let image = sceneAnalysisTestImage()
        let primary = AetherEngine.VideoFrameAnalysisCapture(
            image: image, sourceTime: 12.5, diagnostics: "route=native-output reason=ok")
        var fallbackCalls = 0
        let result = await AetherPlaybackController.resolveSceneCaptureAfterPrimary(
            primary, sourceDVProfile: 8, sourceEligible: true, targetSeconds: 13,
            isCurrent: { true },
            fallback: {
                fallbackCalls += 1
                return nil
            })

        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.sourceTime, primary.sourceTime)
        XCTAssertEqual(result.diagnostics, primary.diagnostics)
        XCTAssertEqual(fallbackCalls, 0)
    }

    @MainActor
    func testSceneDV5ResidentFailurePublishesActualBoundedSourceTimestamp() async {
        let primary = AetherEngine.VideoFrameAnalysisCapture(
            image: nil, sourceTime: 40,
            diagnostics: "route=resident-dovi-rpu sourceDVProfile=5 reason=resident-segment-cache-miss")
        let image = sceneAnalysisTestImage()
        var fallbackCalls = 0
        let result = await AetherPlaybackController.resolveSceneCaptureAfterPrimary(
            primary, sourceDVProfile: 5, sourceEligible: true, targetSeconds: 42,
            isCurrent: { true },
            fallback: {
                fallbackCalls += 1
                return BoundedStillFrame(image: image, actualSeconds: 42.25)
            })

        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.sourceTime, 42.25)
        XCTAssertTrue(result.diagnostics.contains("route=bounded-dovi-source reason=ok"))
        XCTAssertTrue(result.diagnostics.contains("primary={\(primary.diagnostics)}"))
    }

    @MainActor
    func testSceneYieldTraitAndNonDVFailuresNeverUseSourceFallback() async {
        let image = sceneAnalysisTestImage()
        let failures = [
            (5, true, "route=resident-dovi-rpu reason=playback-priority-yield"),
            (5, true, "route=resident-dovi-rpu reason=dv-reshaping-unavailable"),
            (8, true, "route=resident-dovi-rpu reason=resident-segment-cache-miss"),
            (5, false, "route=resident-dovi-rpu reason=resident-segment-cache-miss"),
        ]
        for (profile, sourceEligible, diagnostics) in failures {
            let primary = AetherEngine.VideoFrameAnalysisCapture(
                image: nil, sourceTime: 42, diagnostics: diagnostics)
            var fallbackCalls = 0
            let result = await AetherPlaybackController.resolveSceneCaptureAfterPrimary(
                primary, sourceDVProfile: profile, sourceEligible: sourceEligible, targetSeconds: 42,
                isCurrent: { true },
                fallback: {
                    fallbackCalls += 1
                    return BoundedStillFrame(image: image, actualSeconds: 42)
                })
            XCTAssertNil(result.image)
            XCTAssertEqual(result.diagnostics, diagnostics)
            XCTAssertEqual(fallbackCalls, 0)
        }

        let recoverablePrimary = AetherEngine.VideoFrameAnalysisCapture(
            image: nil, sourceTime: 42,
            diagnostics: "route=resident-dovi-rpu reason=resident-segment-cache-miss")
        var yieldedFallbackCalls = 0
        let yielded = await AetherPlaybackController.resolveSceneCaptureAfterPrimary(
            recoverablePrimary, sourceDVProfile: 5, sourceEligible: true, targetSeconds: 42,
            shouldYield: { true }, didYield: { true }, isCurrent: { true },
            fallback: {
                yieldedFallbackCalls += 1
                return BoundedStillFrame(image: image, actualSeconds: 42)
            })
        XCTAssertNil(yielded.image)
        XCTAssertTrue(yielded.diagnostics.contains("reason=playback-priority-yield"))
        XCTAssertEqual(yieldedFallbackCalls, 0)
    }

    @MainActor
    func testSceneStaleRequestsAndMissingFallbackNeverReportSuccess() async {
        let primary = AetherEngine.VideoFrameAnalysisCapture(
            image: nil, sourceTime: 42,
            diagnostics: "route=resident-dovi-rpu reason=resident-dv-decode-failed-or-budget-expired")
        let image = sceneAnalysisTestImage()
        var fallbackCalls = 0
        let staleBeforeFallback = await AetherPlaybackController.resolveSceneCaptureAfterPrimary(
            primary, sourceDVProfile: 5, sourceEligible: true, targetSeconds: 42,
            isCurrent: { false },
            fallback: {
                fallbackCalls += 1
                return BoundedStillFrame(image: image, actualSeconds: 42)
            })
        XCTAssertNil(staleBeforeFallback.image)
        XCTAssertTrue(staleBeforeFallback.diagnostics.contains("cancelled-or-superseded"))
        XCTAssertEqual(fallbackCalls, 0)

        var currentChecks = 0
        let staleAfterFallback = await AetherPlaybackController.resolveSceneCaptureAfterPrimary(
            primary, sourceDVProfile: 5, sourceEligible: true, targetSeconds: 42,
            isCurrent: {
                currentChecks += 1
                return currentChecks == 1
            },
            fallback: { BoundedStillFrame(image: image, actualSeconds: 42) })
        XCTAssertNil(staleAfterFallback.image)
        XCTAssertTrue(staleAfterFallback.diagnostics.contains("cancelled-or-superseded"))

        let missingFallback = await AetherPlaybackController.resolveSceneCaptureAfterPrimary(
            primary, sourceDVProfile: 5, sourceEligible: true, targetSeconds: 42,
            isCurrent: { true }, fallback: { nil })
        XCTAssertNil(missingFallback.image)
        XCTAssertFalse(missingFallback.diagnostics.contains("reason=ok"))
    }

    private func sceneAnalysisTestImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

private final class StubSceneCastProvider: SceneCastProviding, @unchecked Sendable {
    let candidates: [SceneCastCandidate]
    var fetchCount: Int = 0
    
    init(candidates: [SceneCastCandidate]) {
        self.candidates = candidates
    }
    
    func fetchCast(context: SceneContext) async throws -> [SceneCastCandidate] {
        fetchCount += 1
        return candidates
    }
}


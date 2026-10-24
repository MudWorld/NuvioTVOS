import Foundation
import CoreGraphics
import CoreImage
import Vision
import CoreML

protocol FaceEmbeddingModelProtocol: Sendable {
    var modelVersion: String { get }
    var inputDimension: CGSize { get }
    var acceptanceDistance: Float { get }
    var marginDistance: Float { get }
    func computeEmbedding(for faceImage: CGImage) async throws -> [Float]
}

extension FaceEmbeddingModelProtocol {
    var acceptanceDistance: Float { 0.35 }
    var marginDistance: Float { 0.12 }
}

struct TrackedActorInShot: Sendable {
    var actor: SceneRecognizedActor
    var boundingBox: CGRect
    var lastSeenTimestamp: Double
    var observationCount: Int
    var isConfirmed: Bool

    mutating func recordObservation(at sourceTime: Double, boundingBox: CGRect, maximumCount: Int) -> Bool {
        let isDistinctSourceFrame = observationCount == 0 || lastSeenTimestamp != sourceTime
        if isDistinctSourceFrame, observationCount < maximumCount {
            observationCount += 1
        }
        self.boundingBox = boundingBox
        lastSeenTimestamp = sourceTime
        return isDistinctSourceFrame
    }
}

private struct ServiceFaceDetection: Sendable {
    let boundingBox: CGRect
    let landmarks: [CGPoint]?
}

private struct ReferencePreparationKey: Hashable {
    let matcherIdentifier: String
    let candidateIDs: [String]
}

private struct InFlightReferencePreparation {
    let id: UUID
    let startedAt: Date
    let task: Task<Void, Never>
}

actor ActorRecognitionService {
    static let defaultAcceptanceThreshold: Float = 0.65
    static let defaultMarginThreshold: Float = 0.12
    static let minFaceRelativeDimension: CGFloat = 0.035
    static let minRequiredFrameAgreement: Int = 2
    static let shotCutThresholdSeconds: Double = 2.5
    static let singleFrameConfirmationDistance: Float = 0.48
    static let maskOcclusionGracePeriodSeconds: Double = 4.0
    static let sceneRetentionSeconds: Double = 25.0

    nonisolated static func shouldResetTemporalTracking(lastSourceTime: Double, newSourceTime: Double) -> Bool {
        lastSourceTime > 0 && newSourceTime < lastSourceTime &&
            (lastSourceTime - newSourceTime) > shotCutThresholdSeconds
    }

    nonisolated static func shouldConfirmBundledMatchOnSingleFrame(distance: Float, bundledPipelineActive: Bool) -> Bool {
        bundledPipelineActive && distance <= singleFrameConfirmationDistance
    }
    
    private var matcher: (any SceneIdentityMatching)?
    private let shouldLoadBundledPipeline: Bool
    private var didAttemptBundledPipelineLoad: Bool
    private var bundledPipeline: SceneCoreMLFacePipeline?
    private var matcherLoadFailureReason: String?
    private let referenceStore: CastReferenceStore
    private let fallbackCIContext: CIContext
    private let fallbackFaceDetector: CIDetector?
    private var referencePreparationTasks: [ReferencePreparationKey: InFlightReferencePreparation] = [:]
    private var referenceEnrichmentTasks: [ReferencePreparationKey: InFlightReferencePreparation] = [:]
    private var trackedActors: [String: TrackedActorInShot] = [:] // candidateId -> TrackedActorInShot
    private var lastShotTimestamp: Double = 0
    private var trackingEpoch: UInt64 = 0
    private var calibratedAcceptanceDistance: Float?
    private var calibratedMarginDistance: Float?
    private var didLogEmptyFaceFrame = false
    
    init(
        matcher: (any SceneIdentityMatching)? = nil,
        referenceStore: CastReferenceStore = CastReferenceStore()
    ) {
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        self.fallbackCIContext = ciContext
        self.fallbackFaceDetector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: ciContext,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        self.matcher = matcher
        self.shouldLoadBundledPipeline = matcher == nil
        self.didAttemptBundledPipelineLoad = matcher != nil
        self.referenceStore = referenceStore
    }
    
    init(
        model: (any FaceEmbeddingModelProtocol)?,
        referenceStore: CastReferenceStore = CastReferenceStore()
    ) {
        let ciContext = CIContext(options: [.useSoftwareRenderer: true])
        self.fallbackCIContext = ciContext
        self.fallbackFaceDetector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: ciContext,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        if let model {
            self.matcher = CoreMLFaceEmbeddingMatcher(model: model)
            self.bundledPipeline = model as? SceneCoreMLFacePipeline
        } else {
            self.matcher = nil
        }
        self.shouldLoadBundledPipeline = false
        self.didAttemptBundledPipelineLoad = true
        self.referenceStore = referenceStore
    }
    
    var isModelLoaded: Bool {
        matcher != nil
    }
    
    var modelVersion: String? {
        matcher?.matcherIdentifier
    }

    private var matcherUnavailableReason: String {
        if let matcherLoadFailureReason {
            return matcherLoadFailureReason
        }
        return "Face recognition model not loaded. No face matcher is configured."
    }

    private func resolveMatcher() -> (any SceneIdentityMatching)? {
        if let matcher { return matcher }
        guard shouldLoadBundledPipeline, !didAttemptBundledPipelineLoad else { return nil }

        didAttemptBundledPipelineLoad = true
        do {
            let pipeline = try SceneCoreMLFacePipeline()
            let resolvedMatcher = CoreMLFaceEmbeddingMatcher(model: pipeline)
            bundledPipeline = pipeline
            matcher = resolvedMatcher
            print("[ActorRecognition] Loaded bundled YuNet/SFace pipeline (\(resolvedMatcher.matcherIdentifier))")
            return resolvedMatcher
        } catch {
            let nsError = error as NSError
            matcherLoadFailureReason = "Face recognition model unavailable: bundled YuNet/SFace load failed domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
            print("[ActorRecognition] \(matcherLoadFailureReason ?? "Face recognition model load failed")")
            return nil
        }
    }

    private func inferenceFailureReason(stage: String, error: Error) -> String {
        let nsError = error as NSError
        return "Face recognition unavailable during \(stage): domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
    }
    
    func resetTemporalTracking() {
        trackingEpoch &+= 1
        trackedActors.removeAll()
        lastShotTimestamp = 0
        calibratedAcceptanceDistance = nil
        calibratedMarginDistance = nil
        didLogEmptyFaceFrame = false
    }
    
    /// Returns currently tracked and confirmed actors in the continuous scene.
    func currentTrackedActors(at sourceTime: Double) -> [SceneRecognizedActor] {
        trackedActors.values
            .filter { $0.isConfirmed && (sourceTime - $0.lastSeenTimestamp) <= Self.sceneRetentionSeconds }
            .sorted { $0.lastSeenTimestamp > $1.lastSeenTimestamp }
            .map { $0.actor }
    }
    
    func recordConfirmedActor(_ actor: SceneRecognizedActor, at sourceTime: Double) {
        var tracked = trackedActors[actor.id] ?? TrackedActorInShot(
            actor: actor,
            boundingBox: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1),
            lastSeenTimestamp: sourceTime,
            observationCount: Self.minRequiredFrameAgreement,
            isConfirmed: true
        )
        tracked.actor = actor
        tracked.isConfirmed = true
        tracked.lastSeenTimestamp = sourceTime
        trackedActors[actor.id] = tracked
    }

    func recordConfirmedActorForTesting(_ actor: SceneRecognizedActor, at sourceTime: Double) {
        recordConfirmedActor(actor, at: sourceTime)
    }
    
    /// Detects active dialogue speakers from subtitle cues and adds them to temporal tracking.
    @discardableResult
    func processSubtitleDialogue(
        text: String,
        candidates: [SceneCastCandidate],
        sourceTime: Double
    ) -> [SceneRecognizedActor] {
        let dialogueSpeakers = SceneSubtitleSpeakerRecognizer.detectSpeakers(
            in: text,
            candidates: candidates
        )
        guard !dialogueSpeakers.isEmpty else { return [] }
        
        var recognized: [SceneRecognizedActor] = []
        for speakerCandidate in dialogueSpeakers {
            let actor = SceneRecognizedActor(
                id: speakerCandidate.id,
                name: speakerCandidate.name,
                character: speakerCandidate.character,
                profileURL: speakerCandidate.profileURL,
                confidence: 0.95,
                tmdbId: speakerCandidate.tmdbId ?? Int(speakerCandidate.id)
            )
            var tracked = trackedActors[speakerCandidate.id] ?? TrackedActorInShot(
                actor: actor,
                boundingBox: CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1),
                lastSeenTimestamp: sourceTime,
                observationCount: 0,
                isConfirmed: false
            )
            tracked.actor = actor
            tracked.isConfirmed = true
            tracked.lastSeenTimestamp = sourceTime
            trackedActors[speakerCandidate.id] = tracked
            recognized.append(actor)
            print("[ActorRecognition] Subtitle speaker detected: \"\(speakerCandidate.name)\" as \"\(speakerCandidate.character ?? "")\"")
        }
        return currentTrackedActors(at: sourceTime)
    }

    /// Analyzes a video frame against candidate cast members.
    func analyzeFrame(
        _ frame: SceneFrame,
        candidates: [SceneCastCandidate],
        sourceTime: Double,
        isPaused: Bool = false,
        activeSubtitleText: String? = nil
    ) async -> SceneActorStatus {
        guard !candidates.isEmpty else {
            return .unavailable(reason: "Cast candidates unavailable: no current cast members were supplied.")
        }
        guard let matcher = resolveMatcher() else {
            return .unavailable(reason: matcherUnavailableReason)
        }
        
        // Forward sampling gaps are expected; only a backward jump can indicate a seek.
        if Self.shouldResetTemporalTracking(lastSourceTime: lastShotTimestamp, newSourceTime: sourceTime) {
            resetTemporalTracking()
        }
        lastShotTimestamp = sourceTime
        let analysisEpoch = trackingEpoch
        
        #if DEBUG
        print("[ActorRecognition] analyzeFrame at \(sourceTime)s (candidates: \(candidates.count), isPaused: \(isPaused))")
        #endif
        
        // Active dialogue speakers from subtitles in this frame
        var matchedCandidateIDs = Set<String>()
        if let activeSubtitleText, !activeSubtitleText.isEmpty {
            let speakerActors = processSubtitleDialogue(
                text: activeSubtitleText,
                candidates: candidates,
                sourceTime: sourceTime
            )
            for speaker in speakerActors {
                matchedCandidateIDs.insert(speaker.id)
            }
        }
        
        // 1. Detect faces using YuNet when the bundled SFace matcher is active.
        let detections: [ServiceFaceDetection]
        do {
            detections = try await detectFaceCandidates(in: frame.image, isSceneFrame: true)
        } catch {
            guard trackingEpoch == analysisEpoch else { return .analyzing }
            return .unavailable(reason: inferenceFailureReason(stage: "face detection", error: error))
        }
        guard trackingEpoch == analysisEpoch else { return .analyzing }
        
        // 2. Filter out tiny, distorted, or edge-occluded faces (sufficient quality check)
        let imgW = CGFloat(frame.image.width)
        let imgH = CGFloat(frame.image.height)
        
        let validDetections = detections.filter { detection in
            let box = detection.boundingBox
            let pixelW = box.width * imgW
            let pixelH = box.height * imgH
            let pixelAspect = pixelH / max(1.0, pixelW)
            
            let isLargeEnough = (box.width >= Self.minFaceRelativeDimension || box.height >= Self.minFaceRelativeDimension) &&
                                min(pixelW, pixelH) >= 24 &&
                                max(pixelW, pixelH) >= 30
            let isWithinBounds = box.minX > 0.005 && box.maxX < 0.995 && box.minY > 0.005 && box.maxY < 0.995
            let isValidAspect = pixelAspect >= 0.55 && pixelAspect <= 2.2
            
            let isValid = isLargeEnough && isWithinBounds && isValidAspect
            #if DEBUG
            if !isValid {
                print("[ActorRecognition] Filtered candidate face: \(Int(pixelW))x\(Int(pixelH))px (pxAspect=\(String(format: "%.2f", pixelAspect)), relW=\(String(format: "%.3f", box.width)), relH=\(String(format: "%.3f", box.height))) -> size=\(isLargeEnough), bounds=\(isWithinBounds), aspect=\(isValidAspect)")
            }
            #endif
            return isValid
        }
        #if DEBUG
        print("[ActorRecognition] Detected \(detections.count) face(s), \(validDetections.count) valid for recognition")
        #endif

        if bundledPipeline != nil && detections.isEmpty {
            let activeTracked = currentTrackedActors(at: sourceTime)
            if !activeTracked.isEmpty {
                return .recognized(activeTracked)
            }
            return .noMatch
        }
        
        // If face is masked or occluded, check if an actor is continuously tracked in the current shot
        if validDetections.isEmpty {
            let activeTracked = currentTrackedActors(at: sourceTime)
            if !activeTracked.isEmpty {
                return .recognized(activeTracked)
            }
            return .noMatch
        }
        
        // 3. Ensure reference representations exist in store
        let candidatesByID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let candidateIDs = Set(candidatesByID.keys)

        await ensureReferencesPrepared(candidates: candidates, matcher: matcher)
        guard trackingEpoch == analysisEpoch else { return .analyzing }
        let storedReferencesGrouped = await referenceStore.allFeaturesGrouped(matcherIdentifier: matcher.matcherIdentifier)
        guard trackingEpoch == analysisEpoch else { return .analyzing }
        let referencesGrouped = filterReferencesGrouped(
            storedReferencesGrouped,
            candidateIDs: candidateIDs
        )
        calibrateThresholdsIfNeeded(referencesGrouped: referencesGrouped, matcher: matcher)
        guard !referencesGrouped.isEmpty else {
            return .unavailable(reason: "Cast reference images unavailable: no usable face references were prepared for the current candidates.")
        }
        
        let acceptanceDistance = calibratedAcceptanceDistance ?? matcher.defaultAcceptanceDistance
        let marginDistance = calibratedMarginDistance ?? matcher.defaultMarginDistance
        
        // 4. Crop, compute representation, and match each detected face
        for detection in validDetections {
            let box = detection.boundingBox
            let representation: SceneFaceRepresentation
            if let bundledPipeline, let landmarks = detection.landmarks {
                do {
                    let embedding = try await bundledPipeline.embedding(for: frame.image, landmarks: landmarks)
                    guard trackingEpoch == analysisEpoch else { return .analyzing }
                    representation = .coreMLEmbedding(embedding)
                } catch {
                    guard trackingEpoch == analysisEpoch else { return .analyzing }
                    return .unavailable(reason: inferenceFailureReason(stage: "face embedding", error: error))
                }
            } else {
                guard let cropped = cropFace(from: frame.image, normalizedRect: box) else { continue }
                do {
                    representation = try await matcher.computeFaceRepresentation(for: cropped)
                } catch {
                    guard trackingEpoch == analysisEpoch else { return .analyzing }
                    return .unavailable(reason: inferenceFailureReason(stage: "face embedding", error: error))
                }
                guard trackingEpoch == analysisEpoch else { return .analyzing }
            }
            
            if let match = matchFace(
                representation: representation,
                referencesGrouped: referencesGrouped,
                matcher: matcher,
                acceptanceDistance: acceptanceDistance,
                marginDistance: marginDistance
            ) {
                guard let candidate = candidatesByID[match.candidateId] else { continue }
                let candidateId = candidate.id
                let actor = SceneRecognizedActor(
                    id: candidate.id,
                    name: candidate.name,
                    character: candidate.character,
                    profileURL: candidate.profileURL,
                    confidence: match.confidence,
                    tmdbId: candidate.tmdbId ?? Int(candidate.id)
                )
                var tracked = trackedActors[candidateId] ?? TrackedActorInShot(
                    actor: actor,
                    boundingBox: box,
                    lastSeenTimestamp: sourceTime,
                    observationCount: 0,
                    isConfirmed: false
                )
                
                tracked.actor = actor
                _ = tracked.recordObservation(
                    at: sourceTime,
                    boundingBox: box,
                    maximumCount: Self.minRequiredFrameAgreement
                )
                matchedCandidateIDs.insert(candidateId)
                
                #if DEBUG
                print("[ActorRecognition] Face matched to \"\(match.name)\" (dist=\(String(format: "%.3f", match.distance)), conf=\(String(format: "%.2f", match.confidence)), obs=\(tracked.observationCount))")
                #endif
                
                // 2+ frame agreement rule (or instant confirmation on paused still with high confidence)
                let strictBundledMatch = Self.shouldConfirmBundledMatchOnSingleFrame(
                    distance: match.distance,
                    bundledPipelineActive: bundledPipeline != nil
                )
                if tracked.observationCount >= Self.minRequiredFrameAgreement || isPaused || strictBundledMatch {
                    tracked.isConfirmed = true
                }
                trackedActors[candidateId] = tracked
            }
        }
        
        // 5. Gather confirmed actors from current frame and continuous scene dialogue
        var confirmedActors: [SceneRecognizedActor] = []
        var seenActorIds = Set<String>()
        
        // Priority 1: Actors matched in the current frame
        for candidateId in matchedCandidateIDs {
            if let tracked = trackedActors[candidateId], tracked.isConfirmed {
                if seenActorIds.insert(tracked.actor.id).inserted {
                    confirmedActors.append(tracked.actor)
                }
            }
        }
        
        // Priority 2: Other conversation partners in the ongoing scene within scene retention window
        let scenePartners = trackedActors.values
            .filter { tracked in
                !seenActorIds.contains(tracked.actor.id) &&
                tracked.isConfirmed &&
                (sourceTime - tracked.lastSeenTimestamp) <= Self.sceneRetentionSeconds
            }
            .sorted { $0.lastSeenTimestamp > $1.lastSeenTimestamp }
            
        for partner in scenePartners {
            if seenActorIds.insert(partner.actor.id).inserted {
                confirmedActors.append(partner.actor)
            }
        }
        
        #if DEBUG
        print("[ActorRecognition] Confirmed actors in scene: \(confirmedActors.map(\.name))")
        #endif
        
        // Clean up ancient tracked entries (> sceneRetentionSeconds + 10 seconds)
        trackedActors = trackedActors.filter { (sourceTime - $0.value.lastSeenTimestamp) <= (Self.sceneRetentionSeconds + 10.0) }
        
        if confirmedActors.isEmpty {
            return matchedCandidateIDs.isEmpty ? .noMatch : .analyzing
        }
        return .recognized(confirmedActors)
    }
    
    // MARK: - Face Detection

    private func detectFaceCandidates(in image: CGImage, isSceneFrame: Bool = false) async throws -> [ServiceFaceDetection] {
        if let bundledPipeline {
            return try await bundledPipeline.detectFaces(in: image).map {
                ServiceFaceDetection(boundingBox: $0.boundingBox, landmarks: $0.landmarks)
            }
        }
        return await detectFaces(in: image, isSceneFrame: isSceneFrame).map {
            ServiceFaceDetection(boundingBox: $0, landmarks: nil)
        }
    }

    // MARK: - Legacy detector for explicitly injected matchers
    
    private func detectFaces(in image: CGImage, isSceneFrame: Bool = false) async -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var visionOutcome = "returned zero observations"
        do {
            try handler.perform([request])
            if let results = request.results, !results.isEmpty {
                return results.map { $0.boundingBox }
            }
        } catch {
            visionOutcome = "failed"
            let nsError = error as NSError
            print("[ActorRecognition] Vision face detection failed domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription); \(cgImageMetadata(image))")
        }

        let fallbackFaces = detectFacesWithCoreImage(in: image)
        if !fallbackFaces.isEmpty {
            print("[ActorRecognition] Core Image fallback found \(fallbackFaces.count) face(s) after Vision \(visionOutcome); \(cgImageMetadata(image))")
        } else if isSceneFrame && !didLogEmptyFaceFrame {
            print("[ActorRecognition] Both face detectors found 0 faces after Vision \(visionOutcome); \(cgImageMetadata(image))")
            didLogEmptyFaceFrame = true
        }
        return fallbackFaces
    }

    private func detectFacesWithCoreImage(in image: CGImage) -> [CGRect] {
        guard let fallbackFaceDetector else { return [] }

        let ciImage = CIImage(cgImage: image)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return [] }

        return fallbackFaceDetector.features(in: ciImage).compactMap { feature in
            guard let face = feature as? CIFaceFeature else { return nil }
            let bounds = face.bounds
            return CGRect(
                x: (bounds.minX - extent.minX) / extent.width,
                y: (bounds.minY - extent.minY) / extent.height,
                width: bounds.width / extent.width,
                height: bounds.height / extent.height
            )
        }
    }

    private func cgImageMetadata(_ image: CGImage) -> String {
        let colorModel = image.colorSpace?.model.rawValue ?? -1
        return "pixels=\(image.width)x\(image.height) bitsPerPixel=\(image.bitsPerPixel) bitsPerComponent=\(image.bitsPerComponent) bytesPerRow=\(image.bytesPerRow) colorModel=\(colorModel) alphaInfo=\(image.alphaInfo.rawValue)"
    }
    
    // MARK: - Crop & Align
    
    private func cropFace(from image: CGImage, normalizedRect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        
        // Vision coordinates have origin at bottom-left; CGImage coordinates have origin at top-left
        let x = normalizedRect.origin.x * width
        let y = (1.0 - normalizedRect.origin.y - normalizedRect.height) * height
        let w = normalizedRect.width * width
        let h = normalizedRect.height * height
        
        // Expand slightly with margin for hair and jaw
        let margin: CGFloat = 0.15
        let expandedX = max(0, x - w * margin)
        let expandedY = max(0, y - h * margin)
        let expandedW = min(width - expandedX, w * (1 + 2 * margin))
        let expandedH = min(height - expandedY, h * (1 + 2 * margin))
        
        let cropRect = CGRect(x: expandedX, y: expandedY, width: expandedW, height: expandedH)
        return image.cropping(to: cropRect)
    }
    
    // MARK: - Multi-Reference Matching

    func filterReferencesGrouped(
        _ referencesGrouped: [String: [CastReferenceFeature]],
        candidateIDs: Set<String>
    ) -> [String: [CastReferenceFeature]] {
        referencesGrouped.filter { candidateIDs.contains($0.key) }
    }
    
    struct MatchResult: Sendable {
        let candidateId: String
        let name: String
        let character: String?
        let profileURL: URL?
        let distance: Float
        let confidence: Float
    }
    
    func matchFace(
        representation: SceneFaceRepresentation,
        referencesGrouped: [String: [CastReferenceFeature]],
        matcher: any SceneIdentityMatching,
        acceptanceDistance: Float,
        marginDistance: Float
    ) -> MatchResult? {
        guard !referencesGrouped.isEmpty else { return nil }
        
        struct CandidateScore {
            let candidateId: String
            let bestFeature: CastReferenceFeature
            let minDistance: Float
        }
        
        var scoredCandidates: [CandidateScore] = []
        
        for (candidateId, features) in referencesGrouped {
            var candidateMinDist: Float = .infinity
            var bestFeature: CastReferenceFeature?
            
            for feature in features {
                guard let dist = try? matcher.computeDistance(between: representation, reference: feature.representation) else {
                    continue
                }
                if dist < candidateMinDist {
                    candidateMinDist = dist
                    bestFeature = feature
                }
            }
            
            if let bestFeature, candidateMinDist < .infinity {
                scoredCandidates.append(
                    CandidateScore(
                        candidateId: candidateId,
                        bestFeature: bestFeature,
                        minDistance: candidateMinDist
                    )
                )
            }
        }
        
        // Sort ascending by distance (lower distance = closer match)
        scoredCandidates.sort { $0.minDistance < $1.minDistance }
        guard let best = scoredCandidates.first else { return nil }
        
        // 1. Check acceptance distance threshold
        guard best.minDistance <= acceptanceDistance else {
            print("[ActorRecognition] Closest candidate \"\(best.bestFeature.name)\" dist=\(String(format: "%.3f", best.minDistance)) exceeded acceptance threshold \(String(format: "%.3f", acceptanceDistance))")
            return nil
        }
        
        // 2. Check margin distance against other candidate
        let otherCandidates = scoredCandidates.filter { $0.candidateId != best.candidateId }
        if let secondBest = otherCandidates.first {
            let margin = secondBest.minDistance - best.minDistance
            guard margin >= marginDistance else {
                print("[ActorRecognition] Ambiguous match between \"\(best.bestFeature.name)\" (\(String(format: "%.3f", best.minDistance))) and \"\(secondBest.bestFeature.name)\" (\(String(format: "%.3f", secondBest.minDistance))), margin \(String(format: "%.3f", margin)) < \(String(format: "%.3f", marginDistance))")
                return nil // Ambiguous match between two candidates
            }
        }
        
        let confidence = max(0.0, min(1.0, 1.0 - (best.minDistance / max(0.01, acceptanceDistance * 1.5))))
        
        return MatchResult(
            candidateId: best.candidateId,
            name: best.bestFeature.name,
            character: best.bestFeature.character,
            profileURL: best.bestFeature.profileURL,
            distance: best.minDistance,
            confidence: confidence
        )
    }
    
    // Kept for backward compatibility with tests
    func matchFace(
        embedding: [Float],
        references: [CastReferenceEmbedding],
        acceptanceThreshold: Float,
        marginThreshold: Float
    ) -> MatchResult? {
        guard !references.isEmpty else { return nil }
        var scored: [(reference: CastReferenceEmbedding, score: Float)] = []
        for ref in references {
            let sim = cosineSimilarity(embedding, ref.embedding)
            scored.append((reference: ref, score: sim))
        }
        scored.sort { $0.score > $1.score }
        guard let best = scored.first else { return nil }
        guard best.score >= acceptanceThreshold else { return nil }
        
        let otherCandidates = scored.filter { $0.reference.candidateId != best.reference.candidateId }
        if let secondBest = otherCandidates.first {
            guard (best.score - secondBest.score) >= marginThreshold else {
                return nil
            }
        }
        
        return MatchResult(
            candidateId: best.reference.candidateId,
            name: best.reference.name,
            character: best.reference.character,
            profileURL: best.reference.profileURL,
            distance: 1.0 - best.score,
            confidence: best.score
        )
    }
    
    nonisolated func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = (sqrt(normA) * sqrt(normB))
        return denom > 0 ? (dot / denom) : 0
    }
    
    // MARK: - Reference Preparation & Dynamic Calibration
    
    func cancelReferencePreparation() {
        cancelReferencePreparation(startedBefore: .distantFuture)
    }

    func cancelReferencePreparation(startedBefore cutoff: Date) {
        for (key, preparation) in Array(referencePreparationTasks) where preparation.startedAt <= cutoff {
            preparation.task.cancel()
            clearReferencePreparationTask(key: key, id: preparation.id)
        }
        for (key, enrichment) in Array(referenceEnrichmentTasks) where enrichment.startedAt <= cutoff {
            enrichment.task.cancel()
            clearReferenceEnrichmentTask(key: key, id: enrichment.id)
        }
    }

    func preloadReferences(candidates: [SceneCastCandidate]) async {
        guard let matcher = resolveMatcher() else {
            print("[ActorRecognition] \(matcherUnavailableReason)")
            return
        }
        await ensureReferencesPrepared(candidates: candidates, matcher: matcher)
    }

    private func ensureReferencesPrepared(
        candidates: [SceneCastCandidate],
        matcher: any SceneIdentityMatching
    ) async {
        let key = ReferencePreparationKey(
            matcherIdentifier: matcher.matcherIdentifier,
            candidateIDs: Array(Set(candidates.map(\.id))).sorted()
        )
        if let inFlight = referencePreparationTasks[key] {
            await inFlight.task.value
            clearReferencePreparationTask(key: key, id: inFlight.id)
            return
        }

        let taskID = UUID()
        let startedAt = Date()
        let task = Task {
            await self.performPrimaryReferencePreparation(candidates: candidates, matcher: matcher)
            self.startReferenceEnrichmentIfNeeded(
                key: key,
                candidates: candidates,
                matcher: matcher,
                startedAt: startedAt
            )
        }
        referencePreparationTasks[key] = InFlightReferencePreparation(id: taskID, startedAt: startedAt, task: task)
        await task.value
        clearReferencePreparationTask(key: key, id: taskID)
    }

    private func clearReferencePreparationTask(key: ReferencePreparationKey, id: UUID) {
        guard referencePreparationTasks[key]?.id == id else { return }
        referencePreparationTasks.removeValue(forKey: key)
    }

    private func clearReferenceEnrichmentTask(key: ReferencePreparationKey, id: UUID) {
        guard referenceEnrichmentTasks[key]?.id == id else { return }
        referenceEnrichmentTasks.removeValue(forKey: key)
    }

    private func startReferenceEnrichmentIfNeeded(
        key: ReferencePreparationKey,
        candidates: [SceneCastCandidate],
        matcher: any SceneIdentityMatching,
        startedAt: Date
    ) {
        guard !Task.isCancelled, referenceEnrichmentTasks[key] == nil else { return }
        guard candidates.prefix(24).contains(where: { $0.allImageURLs.count > 1 }) else { return }

        let taskID = UUID()
        let task = Task(priority: .utility) {
            await self.performReferenceEnrichment(candidates: candidates, matcher: matcher)
            self.clearReferenceEnrichmentTask(key: key, id: taskID)
        }
        referenceEnrichmentTasks[key] = InFlightReferencePreparation(id: taskID, startedAt: startedAt, task: task)
    }

    private func performPrimaryReferencePreparation(
        candidates: [SceneCastCandidate],
        matcher: any SceneIdentityMatching
    ) async {
        let prefixCandidates = Array(candidates.prefix(24))
        await withTaskGroup(of: CastReferenceFeature?.self) { group in
            var inFlight = 0
            let maxConcurrent = 6
            
            for candidate in prefixCandidates {
                if Task.isCancelled { break }
                guard let primaryURL = candidate.allImageURLs.first else { continue }

                let existingFeatures = await referenceStore.features(for: candidate.id, matcherIdentifier: matcher.matcherIdentifier)
                if Task.isCancelled { break }
                if existingFeatures.contains(where: { $0.imageHash == primaryURL.absoluteString }) {
                    continue
                }

                if inFlight >= maxConcurrent {
                    if let feature = await group.next(), let feature {
                        await referenceStore.store(features: [feature], for: feature.candidateId)
                        print("[ActorRecognition] Stored primary reference feature for \"\(feature.name)\"")
                    }
                    inFlight -= 1
                }

                group.addTask {
                    await self.prepareReferenceFeature(
                        for: candidate,
                        imageURL: primaryURL,
                        imageIndex: 0,
                        matcher: matcher
                    )
                }
                inFlight += 1
            }

            while let feature = await group.next() {
                if let feature {
                    await referenceStore.store(features: [feature], for: feature.candidateId)
                    print("[ActorRecognition] Stored primary reference feature for \"\(feature.name)\"")
                }
            }
        }
    }

    private func performReferenceEnrichment(
        candidates: [SceneCastCandidate],
        matcher: any SceneIdentityMatching
    ) async {
        for candidate in candidates.prefix(24) {
            guard !Task.isCancelled else { return }
            await Task.yield()
            let imageURLs = candidate.allImageURLs
            guard imageURLs.count > 1 else { continue }

            let existingFeatures = await referenceStore.features(for: candidate.id, matcherIdentifier: matcher.matcherIdentifier)
            guard !Task.isCancelled else { return }
            var existingImageHashes = Set(existingFeatures.map(\.imageHash))

            for (offset, imageURL) in imageURLs.dropFirst().prefix(3).enumerated() {
                guard !Task.isCancelled else { return }
                let imageIndex = offset + 1
                guard !existingImageHashes.contains(imageURL.absoluteString) else { continue }
                guard let feature = await prepareReferenceFeature(
                    for: candidate,
                    imageURL: imageURL,
                    imageIndex: imageIndex,
                    matcher: matcher
                ) else {
                    continue
                }
                guard !Task.isCancelled else { return }
                await referenceStore.store(features: [feature], for: candidate.id)
                existingImageHashes.insert(imageURL.absoluteString)
                print("[ActorRecognition] Enriched reference feature for \"\(candidate.name)\"")
            }
        }
    }

    private func prepareReferenceFeature(
        for candidate: SceneCastCandidate,
        imageURL: URL,
        imageIndex: Int,
        matcher: any SceneIdentityMatching
    ) async -> CastReferenceFeature? {
        guard !Task.isCancelled else { return nil }

        let data: Data
        do {
            let (downloadedData, _) = try await URLSession.shared.data(from: imageURL)
            data = downloadedData
        } catch {
            guard !Task.isCancelled else { return nil }
            logReferenceImageFailure(stage: "download", candidateID: candidate.id, imageIndex: imageIndex, error: error)
            return nil
        }

        guard !Task.isCancelled else { return nil }
        guard let dataProvider = CGDataProvider(data: data as CFData),
              let image = CGImage(jpegDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) ??
                          CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            logReferenceImageFailure(stage: "decode", candidateID: candidate.id, imageIndex: imageIndex)
            return nil
        }

        let representation: SceneFaceRepresentation
        if let bundledPipeline {
            guard !Task.isCancelled else { return nil }
            let detections: [ServiceFaceDetection]
            do {
                detections = try await detectFaceCandidates(in: image)
            } catch {
                guard !Task.isCancelled else { return nil }
                logReferenceImageFailure(stage: "face detection", candidateID: candidate.id, imageIndex: imageIndex, error: error)
                return nil
            }
            guard let face = detections.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }), let landmarks = face.landmarks else {
                logReferenceImageFailure(stage: "no face detected", candidateID: candidate.id, imageIndex: imageIndex)
                return nil
            }
            guard !Task.isCancelled else { return nil }
            do {
                let embedding = try await bundledPipeline.embedding(for: image, landmarks: landmarks)
                representation = .coreMLEmbedding(embedding)
            } catch {
                guard !Task.isCancelled else { return nil }
                logReferenceImageFailure(stage: "embedding", candidateID: candidate.id, imageIndex: imageIndex, error: error)
                return nil
            }
        } else {
            guard !Task.isCancelled else { return nil }
            let detections: [ServiceFaceDetection]
            do {
                detections = try await detectFaceCandidates(in: image)
            } catch {
                guard !Task.isCancelled else { return nil }
                logReferenceImageFailure(stage: "face detection", candidateID: candidate.id, imageIndex: imageIndex, error: error)
                return nil
            }
            let faceImage: CGImage
            if let face = detections.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }), let cropped = cropFace(from: image, normalizedRect: face.boundingBox) {
                faceImage = cropped
            } else {
                faceImage = image
            }
            guard !Task.isCancelled else { return nil }
            do {
                representation = try await matcher.computeFaceRepresentation(for: faceImage)
            } catch {
                guard !Task.isCancelled else { return nil }
                logReferenceImageFailure(stage: "embedding", candidateID: candidate.id, imageIndex: imageIndex, error: error)
                return nil
            }
        }

        guard !Task.isCancelled else { return nil }
        return CastReferenceFeature(
            candidateId: candidate.id,
            name: candidate.name,
            character: candidate.character,
            profileURL: candidate.profileURL ?? imageURL,
            representation: representation,
            imageHash: imageURL.absoluteString,
            matcherIdentifier: matcher.matcherIdentifier
        )
    }

    private func logReferenceImageFailure(stage: String, candidateID: String, imageIndex: Int, error: Error? = nil) {
        if let error {
            let nsError = error as NSError
            print("[ActorRecognition] Reference image \(stage) failed candidate=\(candidateID) image=\(imageIndex + 1) domain=\(nsError.domain) code=\(nsError.code)")
        } else {
            print("[ActorRecognition] Reference image \(stage) candidate=\(candidateID) image=\(imageIndex + 1)")
        }
    }
    
    private func calibrateThresholdsIfNeeded(
        referencesGrouped: [String: [CastReferenceFeature]],
        matcher: any SceneIdentityMatching
    ) {
        // Portrait-only distances do not calibrate the portrait-to-video gap of a face model.
        guard !(matcher is CoreMLFaceEmbeddingMatcher) else { return }
        guard calibratedAcceptanceDistance == nil else { return }
        
        var intraDistances: [Float] = []
        for (_, features) in referencesGrouped where features.count >= 2 {
            for i in 0..<(features.count - 1) {
                for j in (i + 1)..<features.count {
                    if let dist = try? matcher.computeDistance(between: features[i].representation, reference: features[j].representation) {
                        intraDistances.append(dist)
                    }
                }
            }
        }
        
        guard intraDistances.count >= 2 else { return }
        let avgIntra = intraDistances.reduce(0, +) / Float(intraDistances.count)
        
        var interDistances: [Float] = []
        let primaryFeatures = referencesGrouped.compactMap { $0.value.first }
        if primaryFeatures.count >= 2 {
            for i in 0..<(primaryFeatures.count - 1) {
                for j in (i + 1)..<primaryFeatures.count {
                    if let dist = try? matcher.computeDistance(between: primaryFeatures[i].representation, reference: primaryFeatures[j].representation) {
                        interDistances.append(dist)
                    }
                }
            }
        }
        
        let minInter = interDistances.min() ?? (avgIntra + 0.3)
        if minInter > avgIntra {
            let midPoint = (avgIntra + minInter) / 2.0
            let candidateAcceptance = min(matcher.defaultAcceptanceDistance, max(avgIntra + 0.08, midPoint * 0.95))
            self.calibratedAcceptanceDistance = candidateAcceptance
            self.calibratedMarginDistance = min(matcher.defaultMarginDistance, (minInter - avgIntra) * 0.25)
            print("[ActorRecognition] Calibrated thresholds: acceptance=\(String(format: "%.3f", candidateAcceptance)), margin=\(String(format: "%.3f", self.calibratedMarginDistance ?? matcher.defaultMarginDistance)) (avgIntra=\(String(format: "%.3f", avgIntra)), minInter=\(String(format: "%.3f", minInter)))")
        }
    }
}

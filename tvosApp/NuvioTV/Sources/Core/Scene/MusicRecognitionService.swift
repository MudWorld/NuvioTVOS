import Foundation
import AVFAudio
import ShazamKit
import AetherEngine

actor MusicRecognitionService: NSObject {
    private var session: SHSession?
    private var isSessionActive = false
    private var currentStatus: SceneMusicStatus = .disabled
    private var streamingTask: Task<Void, Never>?
    private var lastRecognizedSong: SceneRecognizedSong?
    private var onStatusChanged: (@Sendable (SceneMusicStatus) -> Void)?
    
    // Internal session delegate wrapper to bridge Objective-C delegate callbacks to actor
    private var delegateBridge: ShazamSessionDelegateBridge?
    
    private var signatureGenerator: SHSignatureGenerator = SHSignatureGenerator()
    private var isMatching: Bool = false
    private var hasEntitlementError: Bool = false
    private var bufferCounter: Int = 0
    private var currentSegmentSourceTime: Double = 0
    private let minMatchDuration: Double = 5.0
    private let maxMatchDuration: Double = 12.0
    
    private var lastMatchAttemptTime: Date = .distantPast
    private let matchCooldownInterval: TimeInterval = 4.0
    
    init(onStatusChanged: (@Sendable (SceneMusicStatus) -> Void)? = nil) {
        self.onStatusChanged = onStatusChanged
        super.init()
    }
    
    func setStatusCallback(_ callback: (@Sendable (SceneMusicStatus) -> Void)?) {
        self.onStatusChanged = callback
    }
    
    func startListening(
        stream: AsyncStream<AudioTapBuffer>,
        isPlaying: Bool,
        currentSourceTime: Double
    ) {
        stopListening()
        print("[MusicRecognition] Starting listening (isPlaying=\(isPlaying), sourceTime=\(String(format: "%.1f", currentSourceTime))s)")
        
        guard isPlaying else {
            updateStatus(.requiresPlayback)
            return
        }
        
        if hasEntitlementError {
            updateStatus(.unavailable(reason: "ShazamKit requires App Service enabled in Apple Developer Portal"))
            return
        }
        
        let bridge = ShazamSessionDelegateBridge { [weak self] match in
            Task { [weak self] in
                await self?.handleMatch(match)
            }
        } onNoMatch: { [weak self] signature, error in
            Task { [weak self] in
                await self?.handleNoMatch(error: error)
            }
        }
        
        self.delegateBridge = bridge
        let shSession = SHSession()
        shSession.delegate = bridge
        self.session = shSession
        self.isSessionActive = true
        self.currentSegmentSourceTime = currentSourceTime
        self.signatureGenerator = SHSignatureGenerator()
        self.bufferCounter = 0
        self.isMatching = false
        self.lastMatchAttemptTime = .distantPast
        updateStatus(.listening)
        
        streamingTask = Task { [weak self, stream] in
            for await tapBuffer in stream {
                guard !Task.isCancelled else { break }
                await self?.processAudioBuffer(tapBuffer)
            }
            await self?.handleStreamEnded()
        }
    }
    
    func stopListening() {
        print("[MusicRecognition] Stopping listening")
        streamingTask?.cancel()
        streamingTask = nil
        session = nil
        delegateBridge = nil
        isSessionActive = false
        isMatching = false
        signatureGenerator = SHSignatureGenerator()
        bufferCounter = 0
        currentSegmentSourceTime = 0
        if case .listening = currentStatus {
            updateStatus(.noMatch)
        }
    }
    
    func reportPlaybackPaused() {
        print("[MusicRecognition] Playback paused")
        if lastRecognizedSong == nil {
            updateStatus(.requiresPlayback)
        }
    }
    
    func reportSeek() {
        print("[MusicRecognition] Playback seek reported, resetting signature window")
        lastRecognizedSong = nil
        signatureGenerator = SHSignatureGenerator()
        bufferCounter = 0
        currentSegmentSourceTime = 0
        isMatching = false
        lastMatchAttemptTime = .distantPast
        if isSessionActive {
            updateStatus(.listening)
        }
    }
    
    func reset() {
        print("[MusicRecognition] Reset called")
        stopListening()
        lastRecognizedSong = nil
        signatureGenerator = SHSignatureGenerator()
        bufferCounter = 0
        currentSegmentSourceTime = 0
        isMatching = false
        hasEntitlementError = false
        lastMatchAttemptTime = .distantPast
        updateStatus(.disabled)
    }
    
    private func processAudioBuffer(_ tapBuffer: AudioTapBuffer) {
        guard isSessionActive, !hasEntitlementError else { return }
        
        bufferCounter += 1
        if currentSegmentSourceTime == 0 {
            currentSegmentSourceTime = tapBuffer.sourceTime
        }
        
        do {
            try signatureGenerator.append(tapBuffer.buffer, at: nil)
        } catch {
            print("[MusicRecognition] ⚠️ Failed to append buffer to signature generator: \(error.localizedDescription)")
            return
        }
        
        let signature = signatureGenerator.signature()
        let duration = signature.duration
        
        #if DEBUG
        if bufferCounter == 1 || bufferCounter % 25 == 0 {
            print("[MusicRecognition] Tap buffer #\(bufferCounter): sig duration=\(String(format: "%.1f", duration))s at sourceTime=\(String(format: "%.1f", tapBuffer.sourceTime))s (frames=\(tapBuffer.buffer.frameLength))")
        }
        #endif
        
        // When enough audio duration is accumulated and no match is currently running
        if duration >= minMatchDuration && !isMatching {
            guard Date().timeIntervalSince(lastMatchAttemptTime) >= matchCooldownInterval else { return }
            lastMatchAttemptTime = Date()
            isMatching = true
            let matchSignature = signature
            let time = currentSegmentSourceTime
            print("[MusicRecognition] 🔍 Querying ShazamKit for signature (duration=\(String(format: "%.1f", duration))s, sourceTime=\(String(format: "%.1f", time))s)...")
            session?.match(matchSignature)
        }
    }
    
    private func handleStreamEnded() {
        print("[MusicRecognition] Audio tap stream finished")
    }
    
    private func handleMatch(_ match: SHMatch) {
        isMatching = false
        signatureGenerator = SHSignatureGenerator()
        bufferCounter = 0
        currentSegmentSourceTime = 0
        
        guard let item = match.mediaItems.first else {
            print("[MusicRecognition] Match callback had no mediaItems")
            updateStatus(.noMatch)
            return
        }
        
        let song = SceneRecognizedSong(
            id: item.shazamID ?? item.appleMusicID ?? (item.title ?? UUID().uuidString),
            title: item.title ?? "Unknown Title",
            artist: item.artist ?? "Unknown Artist",
            artworkURL: item.artworkURL,
            appleMusicURL: item.appleMusicURL,
            shazamURL: item.videoURL ?? item.webURL,
            genres: item.genres,
            observedSourceTime: currentSegmentSourceTime
        )
        
        print("[MusicRecognition] 🎵 MATCH FOUND: \"\(song.title)\" by \"\(song.artist)\" (artwork: \(song.artworkURL != nil), appleMusic: \(song.appleMusicURL != nil))")
        self.lastRecognizedSong = song
        updateStatus(.matched(song))
    }
    
    func handleNoMatch(error: Error?) {
        isMatching = false
        
        if let error {
            let nsError = error as NSError
            print("[MusicRecognition] ⚠️ Shazam match error: \(error.localizedDescription) (domain: \(nsError.domain), code: \(nsError.code))")
            
            let errorString = "\(nsError) \(nsError.userInfo)"
            let isEntitlementOrDaemonIssue = (nsError.domain == "com.apple.ShazamKit" || nsError.domain == SHErrorDomain) &&
                (nsError.code == 202 ||
                 nsError.code == 200 ||
                 nsError.code == 201 ||
                 nsError.code == 203 ||
                 nsError.code == 204 ||
                 errorString.localizedCaseInsensitiveContains("entitlement") ||
                 errorString.contains("401") ||
                 errorString.localizedCaseInsensitiveContains("unauthorized"))
            
            if isEntitlementOrDaemonIssue {
                print("[MusicRecognition] ❌ ShazamKit requires App Service entitlement enabled for this App ID in Apple Developer Portal (or unavailable on simulator)")
                hasEntitlementError = true
                streamingTask?.cancel()
                streamingTask = nil
                session = nil
                delegateBridge = nil
                isSessionActive = false
                isMatching = false
                updateStatus(.unavailable(reason: "ShazamKit requires App Service enabled in Apple Developer Portal"))
                return
            }
            
            if let shError = error as? SHError,
               (shError.code == .signatureInvalid || shError.code == .signatureDurationInvalid) {
                signatureGenerator = SHSignatureGenerator()
                bufferCounter = 0
                currentSegmentSourceTime = 0
            }
        } else {
            print("[MusicRecognition] No song match in catalog for current audio window (sig duration: \(String(format: "%.1f", signatureGenerator.signature().duration))s)")
        }
        
        // If signature duration has reached max window without a match, reset for the next section
        if signatureGenerator.signature().duration >= maxMatchDuration {
            print("[MusicRecognition] Reached max match duration (\(maxMatchDuration)s), sliding to next audio window")
            signatureGenerator = SHSignatureGenerator()
            bufferCounter = 0
            currentSegmentSourceTime = 0
        }
        
        if let lastRecognizedSong {
            updateStatus(.matched(lastRecognizedSong))
        } else {
            updateStatus(.noMatch)
        }
    }
    
    private func updateStatus(_ status: SceneMusicStatus) {
        currentStatus = status
        onStatusChanged?(status)
    }
}

// MARK: - Delegate Bridge

private final class ShazamSessionDelegateBridge: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let onMatch: (SHMatch) -> Void
    private let onNoMatch: (SHSignature, Error?) -> Void
    
    init(
        onMatch: @escaping (SHMatch) -> Void,
        onNoMatch: @escaping (SHSignature, Error?) -> Void
    ) {
        self.onMatch = onMatch
        self.onNoMatch = onNoMatch
    }
    
    func session(_ session: SHSession, didFind match: SHMatch) {
        onMatch(match)
    }
    
    func session(_ session: SHSession, didNotFind match: SHMatch) {
        // Compatibility handler
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        onNoMatch(signature, error)
    }
}

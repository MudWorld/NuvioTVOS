import Foundation
import UIKit
import AVKit
import AVFoundation
import CoreMedia
import Combine
import AetherEngine

/// Context required to restore the full-screen player UI from a floating PiP window.
struct ActivePlaybackContext: Equatable {
    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let httpHeaders: [String: String]
    let cacheFileIdentity: PlaybackCacheFileIdentity?
    let sourceID: String?
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    let episodes: [NuvioVideo]
    let currentEpisode: NuvioVideo?
    let autoPlayNextEnabled: Bool
    let autoPlayNextCountdownSeconds: Int
    let playbackOrigin: PlaybackOrigin
    let filename: String?
    let videoSize: Int64?
    let videoHash: String?

    init(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String] = [:],
        cacheFileIdentity: PlaybackCacheFileIdentity? = nil,
        sourceID: String? = nil,
        externalSubtitles: [NuvioSubtitle] = [],
        resumeFrom: Double? = nil,
        episodes: [NuvioVideo] = [],
        currentEpisode: NuvioVideo? = nil,
        autoPlayNextEnabled: Bool = true,
        autoPlayNextCountdownSeconds: Int = 10,
        playbackOrigin: PlaybackOrigin = .main,
        filename: String? = nil,
        videoSize: Int64? = nil,
        videoHash: String? = nil
    ) {
        self.url = url
        self.meta = meta
        self.subtitle = subtitle
        self.httpHeaders = httpHeaders
        self.cacheFileIdentity = cacheFileIdentity
        self.sourceID = sourceID
        self.externalSubtitles = externalSubtitles
        self.resumeFrom = resumeFrom
        self.episodes = episodes
        self.currentEpisode = currentEpisode
        self.autoPlayNextEnabled = autoPlayNextEnabled
        self.autoPlayNextCountdownSeconds = autoPlayNextCountdownSeconds
        self.playbackOrigin = playbackOrigin
        self.filename = filename
        self.videoSize = videoSize
        self.videoHash = videoHash
    }
}

/// Central Picture-in-Picture manager for tvOS.
/// Bridges `AVPictureInPictureController` with `AetherEngine` (native AVPlayerLayer & sample-buffer paths).
@MainActor
final class PictureInPictureManager: NSObject, ObservableObject {
    static let shared = PictureInPictureManager()

    @Published private(set) var isPictureInPictureActive: Bool = false
    @Published private(set) var isPictureInPicturePossible: Bool = false

    var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private(set) var pipController: AVPictureInPictureController?
    private(set) var activeCoordinator: PlaybackSessionCoordinator?
    private(set) var activeAetherController: AetherPlaybackController?
    private(set) var activeContext: ActivePlaybackContext?

    private var possibleObservation: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    private var isRestoringUI = false
    private var pendingRestoreCompletion: ((Bool) -> Void)?
    private var pendingRestoreResult: Bool?
    private var restoreSurfaceReady = false
    private weak var configuredSoftwareDisplayLayer: CALayer?
    private let softwareSkipRequests = PlayerPiPRequests()
    private var sessionGeneration = UUID()
    private var lastSoftwarePaused: Bool?
    private var pipStartState = PlayerPiPStartState()

    var isRestoringUIInProgress: Bool { isRestoringUI }
    /// Startup retains the fullscreen surface; lifecycle owners may keep this exact
    /// coordinator alive until AVKit confirms or rejects the transition.
    var isPictureInPictureStarting: Bool { pipStartState.isStarting }

    /// Invoked when PiP begins so the active full-screen PlayerView can dismiss to the background.
    var onDidStartPiP: (() -> Void)?

    /// Invoked when PiP is closed by the user (via X button) without restoring full-screen UI.
    var onDidStopPiPWithoutRestoring: (() -> Void)?
    /// Eligibility/layer loss can discard AVKit with its delegate already detached.
    /// Root must close a retained Party model when no fullscreen surface remains.
    var onDidLoseWatchPartyPiP: ((PlaybackSessionCoordinator) -> Void)?

    /// Invoked when the user clicks the expand / restore button on the system PiP window.
    var onRestoreUI: ((ActivePlaybackContext, @escaping (Bool) -> Void) -> Void)?

    override private init() {
        super.init()
    }

    // MARK: - Session Registration

    /// Registers the currently active playback session with the PiP manager.
    func registerSession(
        coordinator: PlaybackSessionCoordinator,
        context: ActivePlaybackContext
    ) {
        let mark = UUID()
        sessionGeneration = mark
        if let previous = activeCoordinator, previous !== coordinator {
            clearController()
            guard sessionGeneration == mark else { return }
            previous.stopAll()
            guard sessionGeneration == mark else { return }
        }
        self.activeCoordinator = coordinator
        self.activeContext = context
        refreshController(for: coordinator)
    }

    /// A retry may replace the controller while preserving its registered
    /// session/context. Ignore notifications from unregistered player screens.
    func refreshController(for coordinator: PlaybackSessionCoordinator) {
        guard activeCoordinator === coordinator else { return }
        guard coordinator.activeBackend == .aether,
              let controller = coordinator.aetherController else {
            clearController()
            return
        }
        setupPipController(for: controller)
    }

    func refreshWatchPartyTimebase(for coordinator: PlaybackSessionCoordinator) {
        guard activeCoordinator === coordinator else { return }
        softwareSkipRequests.tick()
        guard activeCoordinator === coordinator, let controller = activeAetherController,
              controller.isWatchPartyControlled, let pip = pipController,
              let current = softwareController(for: pip) else { return }
        let paused = current.engine.softwarePiPSource?.isPaused ?? true
        if lastSoftwarePaused != paused { lastSoftwarePaused = paused; pip.invalidatePlaybackState() }
    }

    private func clearController() {
        discardPipController(clearingSource: true)
    }

    /// A blocked native/temporarily absent software path must keep source observers so it can
    /// become eligible later. Clear identity/state before any completion can re-enter.
    private func discardPipController(clearingSource: Bool = false) {
        let oldController = pipController
        let hadPendingOrActivePiP = pipStartState.isInProgress
        _ = pipStartState.stop()
        let completion = pendingRestoreCompletion
        pipController = nil
        oldController?.delegate = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        if hadPendingOrActivePiP { oldController?.stopPictureInPicture() }
        activeAetherController?.engine.pictureInPictureActive = false
        if clearingSource {
            cancellables.removeAll()
            activeAetherController = nil
        }
        isPictureInPictureActive = false
        isPictureInPicturePossible = false
        configuredSoftwareDisplayLayer = nil
        lastSoftwarePaused = nil
        pendingRestoreCompletion = nil
        pendingRestoreResult = nil
        isRestoringUI = false
        restoreSurfaceReady = false
        softwareSkipRequests.cancelAll()
        completion?(false)
    }

    /// Sets up or reconfigures the `AVPictureInPictureController` for the given Aether controller.
    func setupPipController(for aetherController: AetherPlaybackController) {
        let mark = sessionGeneration
        let controllerChanged = activeAetherController !== aetherController
        if controllerChanged { clearController() }
        guard sessionGeneration == mark else { return }
        self.activeAetherController = aetherController
        if controllerChanged {
            configuredSoftwareDisplayLayer = nil
        }
        guard isPictureInPictureSupported else { return }

        cancellables.removeAll()

        // Observe software PiP source changes (for software decode path)
        aetherController.engine.$softwarePiPSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildPipControllerIfNeeded()
            }
            .store(in: &cancellables)

        // Observe playback phase changes to rebuild when layer is mounted
        aetherController.engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildPipControllerIfNeeded()
            }
            .store(in: &cancellables)

        rebuildPipControllerIfNeeded()
    }

    private func rebuildPipControllerIfNeeded() {
        guard isPictureInPictureSupported, let controller = activeAetherController else { return }
        let mark = sessionGeneration
        if controller.isWatchPartyControlled, !controller.canUseWatchPartySoftwarePiP {
            let lost = (isPictureInPictureActive || isRestoringUI) ? activeCoordinator : nil
            discardPipController()
            if let lost { onDidLoseWatchPartyPiP?(lost) }
            return // Native Party PiP stays blocked; observe until an eligible software path exists.
        }
        if controller.isWatchPartyControlled, let layer = configuredSoftwareDisplayLayer,
           controller.engine.softwarePiPSource?.layer !== layer {
            let lost = (isPictureInPictureActive || isRestoringUI) ? activeCoordinator : nil
            discardPipController()
            if let lost { onDidLoseWatchPartyPiP?(lost) }
            guard sessionGeneration == mark, activeAetherController === controller else { return }
        }
        guard !pipStartState.isInProgress else { return } // Preserve the source during AVKit startup too.

        let engine = controller.engine

        if let nativeLayer = engine.nativePlayerLayer {
            configuredSoftwareDisplayLayer = nil
            if let existing = pipController, existing.playerLayer === nativeLayer {
                return
            }
            discardPipController()
            guard sessionGeneration == mark, activeAetherController === controller else { return }
            let pip = AVPictureInPictureController(playerLayer: nativeLayer)
            pip?.delegate = self
            #if os(iOS)
            if #available(iOS 14.2, *) {
                pip?.canStartPictureInPictureAutomaticallyFromInline = true
            }
            #endif
            self.pipController = pip
            bindPossibleObservation(pip)
        } else if #available(tvOS 15.0, *), let swSource = engine.softwarePiPSource {
            if configuredSoftwareDisplayLayer === swSource.layer, pipController != nil {
                return
            }
            discardPipController()
            guard sessionGeneration == mark, activeAetherController === controller,
                  controller.engine.softwarePiPSource?.layer === swSource.layer else { return }
            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: swSource.layer,
                playbackDelegate: self
            )
            let pip = AVPictureInPictureController(contentSource: contentSource)
            pip.delegate = self
            #if os(iOS)
            if #available(iOS 15.0, *) {
                pip.canStartPictureInPictureAutomaticallyFromInline = true
            }
            #endif
            self.pipController = pip
            configuredSoftwareDisplayLayer = swSource.layer
            bindPossibleObservation(pip)
        }
    }

    private func bindPossibleObservation(_ pip: AVPictureInPictureController?) {
        guard let pip else {
            isPictureInPicturePossible = false
            return
        }
        isPictureInPicturePossible = pip.isPictureInPicturePossible
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            Task { @MainActor [weak self] in
                guard let self, self.pipController === controller else { return }
                self.isPictureInPicturePossible = controller.isPictureInPicturePossible
            }
        }
    }

    // MARK: - Actions

    func startPictureInPicture() {
        guard isPictureInPictureSupported else { return }
        rebuildPipControllerIfNeeded()

        guard let pip = pipController else {
            print("[PictureInPicture] Cannot start: no AVPictureInPictureController instance")
            return
        }

        // AVKit may ignore a start while unavailable instead of sending a failure callback.
        guard pip.isPictureInPicturePossible, pipStartState.begin() else { return }
        let startingGeneration = sessionGeneration
        let startingAetherController = activeAetherController
        // Protect the source from lifecycle parking in the gap before willStart.
        startingAetherController?.engine.pictureInPictureActive = true
        guard sessionGeneration == startingGeneration, pipController === pip,
              activeAetherController === startingAetherController, pipStartState.isStarting else { return }

        print("[PictureInPicture] Requesting startPictureInPicture (isPossible=\(pip.isPictureInPicturePossible))")
        pip.startPictureInPicture()
    }

    func stopPictureInPicture() {
        guard pipStartState.isInProgress else { return }
        pipController?.stopPictureInPicture()
    }

    func togglePictureInPicture() {
        if pipStartState.isInProgress {
            stopPictureInPicture()
        } else {
            startPictureInPicture()
        }
    }

    /// Programmatically restores the fullscreen player interface from the app.
    /// If PiP is active, safely coordinates with AVKit so that PiP stops only after
    /// the fullscreen player surface has remounted.
    @discardableResult
    func restoreFullscreenFromApp() -> Bool {
        guard let context = activeContext, !isRestoringUI, let onRestoreUI else { return false }
        if isPictureInPictureActive, let pip = pipController {
            let restoringGeneration = sessionGeneration
            isRestoringUI = true
            pendingRestoreCompletion = { [weak self, weak pip] success in
                guard let self, self.sessionGeneration == restoringGeneration else { return }
                if success {
                    pip?.stopPictureInPicture()
                } else {
                    self.isRestoringUI = false
                }
            }
            pendingRestoreResult = nil
            restoreSurfaceReady = false
            onRestoreUI(context) { [weak self, weak pip] success in
                guard let self, let pip, self.sessionGeneration == restoringGeneration,
                      self.pipController === pip, self.pendingRestoreCompletion != nil else { return }
                self.pendingRestoreResult = success
                self.finishRestoreIfReady()
            }
            return true
        } else {
            onRestoreUI(context) { _ in }
            return true
        }
    }

    /// Stops playback and clears the active session state.
    func invalidateSession() {
        sessionGeneration = UUID()
        let retainedCoordinator = activeCoordinator
        activeCoordinator = nil
        activeContext = nil
        clearController()
        if activeCoordinator !== retainedCoordinator { retainedCoordinator?.stopAll() }
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PictureInPictureManager: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        print("[PictureInPicture] willStartPictureInPicture")
        // Also admits automatic AVKit startup. Keep fullscreen mounted until didStart.
        _ = pipStartState.begin()
        guard pipStartState.isStarting else { return }
        activeAetherController?.engine.pictureInPictureActive = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController, pipStartState.confirm() else { return }
        let startedGeneration = sessionGeneration
        print("[PictureInPicture] didStartPictureInPicture")
        activeAetherController?.engine.pictureInPictureActive = true
        guard sessionGeneration == startedGeneration, pipController === pictureInPictureController else { return }
        isPictureInPictureActive = true
        guard sessionGeneration == startedGeneration, pipController === pictureInPictureController else { return }
        onDidStartPiP?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard pipController === pictureInPictureController, pipStartState.fail() else { return }
        let failedGeneration = sessionGeneration
        let failedCoordinator = activeCoordinator
        let failedAetherController = activeAetherController
        print("[PictureInPicture] failedToStartPictureInPictureWithError: \(error.localizedDescription)")
        activeAetherController?.engine.pictureInPictureActive = false
        guard sessionGeneration == failedGeneration, pipController === pictureInPictureController else { return }
        activeAetherController?.rebindSurface()
        guard sessionGeneration == failedGeneration, pipController === pictureInPictureController,
              activeCoordinator === failedCoordinator, activeAetherController === failedAetherController else { return }
        if let failedCoordinator, failedAetherController?.isWatchPartyControlled == true,
           UIApplication.shared.applicationState != .active {
            onDidLoseWatchPartyPiP?(failedCoordinator)
        }
        // No fullscreen dismissal or lease transfer occurred, so there is nothing to restore.
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        print("[PictureInPicture] willStopPictureInPicture (isRestoringUI=\(isRestoringUI))")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard pipController === pictureInPictureController else { return }
        let stoppedGeneration = sessionGeneration
        let stoppedCoordinator = activeCoordinator
        let stoppedAetherController = activeAetherController
        let stoppedPendingPiP = pipStartState.isStarting
        let stoppedConfirmedPiP = pipStartState.stop()
        print("[PictureInPicture] didStopPictureInPicture (isRestoringUI=\(isRestoringUI))")
        isPictureInPictureActive = false
        guard sessionGeneration == stoppedGeneration, pipController === pictureInPictureController else { return }
        activeAetherController?.engine.pictureInPictureActive = false
        guard sessionGeneration == stoppedGeneration, pipController === pictureInPictureController else { return }
        activeAetherController?.rebindSurface()

        guard sessionGeneration == stoppedGeneration, pipController === pictureInPictureController,
              activeCoordinator === stoppedCoordinator,
              activeAetherController === stoppedAetherController else { return }
        guard stoppedConfirmedPiP else {
            // Cancellation may arrive as didStop instead of failedToStart, after
            // the only background notification has already passed.
            if stoppedPendingPiP, let stoppedCoordinator, stoppedAetherController?.isWatchPartyControlled == true,
               UIApplication.shared.applicationState != .active {
                onDidLoseWatchPartyPiP?(stoppedCoordinator)
            }
            return
        }

        if !isRestoringUI {
            onDidStopPiPWithoutRestoring?()
            guard sessionGeneration == stoppedGeneration else { return }
            invalidateSession()
            return
        }
        if sessionGeneration == stoppedGeneration { isRestoringUI = false }
    }

    /// Called by the mounted full-screen Aether surface. AVKit's restore
    /// completion must wait until this rebind has happened; acknowledging it
    /// as soon as `activeScreen` changes can let AVKit tear down PiP while the
    /// new SwiftUI hierarchy still owns an empty surface.
    func fullscreenSurfaceDidRebind() {
        guard isRestoringUI else { return }
        restoreSurfaceReady = true
        activeAetherController?.rebindSurface()
        finishRestoreIfReady()
    }

    private func finishRestoreIfReady() {
        guard let result = pendingRestoreResult,
              let completion = pendingRestoreCompletion,
              !result || restoreSurfaceReady else { return }
        pendingRestoreResult = nil
        pendingRestoreCompletion = nil
        completion(result)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard pipController === pictureInPictureController else {
            completionHandler(false)
            return
        }
        print("[PictureInPicture] restoreUserInterfaceForPictureInPictureStop")
        let restoringGeneration = sessionGeneration
        isRestoringUI = true
        pendingRestoreCompletion = completionHandler
        pendingRestoreResult = nil
        restoreSurfaceReady = false

        guard let context = activeContext else {
            pendingRestoreResult = false
            fullscreenSurfaceDidRebind()
            return
        }

        if let onRestoreUI {
            onRestoreUI(context) { [weak self, weak pictureInPictureController] success in
                guard let self, let pip = pictureInPictureController,
                      self.sessionGeneration == restoringGeneration,
                      self.pipController === pip, self.pendingRestoreCompletion != nil else { return }
                self.pendingRestoreResult = success
                self.finishRestoreIfReady()
            }
        } else {
            pendingRestoreResult = false
            finishRestoreIfReady()
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(tvOS 15.0, *)
extension PictureInPictureManager: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    private func softwareController(for pip: AVPictureInPictureController) -> AetherPlaybackController? {
        guard pipController === pip, let controller = activeAetherController,
              activeCoordinator?.aetherController === controller, activeCoordinator?.activeBackend == .aether,
              controller.engine.nativePlayerLayer == nil, let source = controller.engine.softwarePiPSource,
              configuredSoftwareDisplayLayer === source.layer else { return nil }
        return controller
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard let controller = softwareController(for: pictureInPictureController) else { return }
        if controller.isWatchPartyControlled {
            controller.performWatchPartyPiPIntent(playing ? .play : .pause, completion: { [weak self, weak pictureInPictureController] in
                guard let self, let pip = pictureInPictureController, self.pipController === pip else { return }
                pip.invalidatePlaybackState()
            })
        } else { controller.engine.softwarePiPSource?.setPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        softwareController(for: pictureInPictureController)?.engine.softwarePiPSource?.timeRange()
            ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        softwareController(for: pictureInPictureController)?.engine.softwarePiPSource?.isPaused ?? true
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // Render size update
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        guard let controller = softwareController(for: pictureInPictureController), skipInterval.seconds.isFinite else {
            completionHandler()
            return
        }
        if controller.isWatchPartyControlled {
            let generation = sessionGeneration
            let request = softwareSkipRequests.begin({ [weak self, weak pictureInPictureController] in
                if let self, let pip = pictureInPictureController, self.pipController === pip { pip.invalidatePlaybackState() }
                completionHandler()
            }, check: { [weak self, weak controller, weak pictureInPictureController] in
                guard let self, let controller, let pip = pictureInPictureController,
                      self.sessionGeneration == generation, self.softwareController(for: pip) === controller else { return nil }
                guard let base = controller.engine.softwarePiPSource?.layer.controlTimebase else { return false }
                let seconds = CMTimebaseGetTime(base).seconds
                let rate = CMTimebaseGetRate(base)
                let expected = controller.isTransportPlaying ? Double(controller.currentSpeed) : 0
                return seconds.isFinite && rate.isFinite
                    && abs(seconds - Double(controller.positionMs) / 1000) <= 0.5 && abs(rate - expected) <= 0.01
            })
            controller.performWatchPartyPiPIntent(.skip(skipInterval.seconds), onApplied: request.applied, completion: request.finished)
        } else {
            controller.engine.softwarePiPSource?.skip(by: skipInterval.seconds)
            completionHandler() // Preserve the existing non-Party path; not a seek receipt.
        }
    }
}

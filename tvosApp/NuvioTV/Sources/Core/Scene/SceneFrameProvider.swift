import Foundation
import CoreGraphics
import AetherEngine

@MainActor
protocol SceneFrameProviding: AnyObject {
    var isSupported: Bool { get }
    var capabilityMessage: String? { get }
    func captureCurrentFrame(maxWidth: Int, context: SceneContext) async -> SceneFrame?
}

@MainActor
final class AetherSceneFrameProvider: SceneFrameProviding {
    private weak var aetherController: AetherPlaybackController?
    
    init(controller: AetherPlaybackController?) {
        self.aetherController = controller
    }
    
    var isSupported: Bool {
        aetherController != nil
    }
    
    var capabilityMessage: String? {
        if aetherController == nil {
            return "Aether engine not active"
        }
        return nil
    }
    
    func captureCurrentFrame(maxWidth: Int = 960, context: SceneContext) async -> SceneFrame? {
        guard let controller = aetherController else { return nil }
        let engine = controller.engine
        let capture = await controller.captureSceneFrameForAnalysis(maxWidth: maxWidth)
        guard !Task.isCancelled,
              aetherController === controller,
              controller.engine === engine else { return nil }
        guard let image = capture.image else {
            print("[Scene] Capture unavailable: \(capture.diagnostics)")
            return nil
        }
        return SceneFrame(
            image: image,
            sourceTime: capture.sourceTime,
            sessionID: context.sessionID,
            generation: context.timelineGeneration,
            captureDiagnostics: capture.diagnostics
        )
    }
}

@MainActor
final class UnsupportedSceneFrameProvider: SceneFrameProviding {
    private let reason: String
    
    init(reason: String = "Current playback backend does not support direct display pipeline frame capture.") {
        self.reason = reason
    }
    
    var isSupported: Bool { false }
    var capabilityMessage: String? { reason }
    
    func captureCurrentFrame(maxWidth: Int, context: SceneContext) async -> SceneFrame? {
        return nil
    }
}

@MainActor
final class DynamicPlayerSceneFrameProvider: SceneFrameProviding {
    private let activeEngineKindProvider: () -> PlayerBackendKind
    private let aetherControllerProvider: () -> AetherPlaybackController?
    
    init(
        activeEngineKindProvider: @escaping () -> PlayerBackendKind,
        aetherControllerProvider: @escaping () -> AetherPlaybackController?
    ) {
        self.activeEngineKindProvider = activeEngineKindProvider
        self.aetherControllerProvider = aetherControllerProvider
    }
    
    var isSupported: Bool {
        activeEngineKindProvider() == .aether && aetherControllerProvider() != nil
    }
    
    var capabilityMessage: String? {
        if activeEngineKindProvider() == .mpv {
            return "MPV backend does not support direct display pipeline frame capture."
        }
        if aetherControllerProvider() == nil {
            return "Aether engine not active"
        }
        return nil
    }
    
    func captureCurrentFrame(maxWidth: Int = 960, context: SceneContext) async -> SceneFrame? {
        guard activeEngineKindProvider() == .aether,
              let controller = aetherControllerProvider() else {
            return nil
        }
        let engine = controller.engine
        let capture = await controller.captureSceneFrameForAnalysis(maxWidth: maxWidth)
        guard !Task.isCancelled,
              activeEngineKindProvider() == .aether,
              aetherControllerProvider() === controller,
              controller.engine === engine else { return nil }
        guard let image = capture.image else {
            print("[Scene] Capture unavailable: \(capture.diagnostics)")
            return nil
        }
        return SceneFrame(
            image: image,
            sourceTime: capture.sourceTime,
            sessionID: context.sessionID,
            generation: context.timelineGeneration,
            captureDiagnostics: capture.diagnostics
        )
    }
}

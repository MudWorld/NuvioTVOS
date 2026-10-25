import Foundation

extension AetherEngine {
    /// Applies dialogue and loudness processing to the app-owned FFmpeg PCM routes.
    /// AVPlayer-owned routes intentionally ignore this request because the engine cannot process their audio.
    public func setAudioProcessing(
        dialogue: AudioDialogueEnhancement,
        reduceLoudSounds: Bool
    ) {
        guard supportsAudioProcessing else { return }
        let settings = AudioProcessingSettings(
            dialogue: dialogue,
            reduceLoudSounds: reduceLoudSounds
        )
        guard audioProcessingSettings != settings else { return }
        audioProcessingSettings = settings
        softwareHost?.setAudioProcessing(settings)
        audioHost?.setAudioProcessing(settings)
    }
}

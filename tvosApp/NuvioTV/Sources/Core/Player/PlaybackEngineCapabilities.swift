import Foundation

/// Feature surface advertised by a backend so the coordinator can force MPV when needed.
struct PlaybackEngineCapabilities: Equatable {
    var supportsSeparateAudioURL: Bool
    var supportsAudioDelay: Bool
    var supportsAudioAmplification: Bool
    var supportsAuthoredASS: Bool
    var supportsHostSubtitleOverlay: Bool
    var supportsHTTPHeaders: Bool
    var supportsDirectHTTPS: Bool
    var supportsRemoteHLS: Bool

    static let aether = PlaybackEngineCapabilities(
        supportsSeparateAudioURL: false,
        supportsAudioDelay: true,
        supportsAudioAmplification: false,
        supportsAuthoredASS: false,
        supportsHostSubtitleOverlay: true,
        supportsHTTPHeaders: true,
        supportsDirectHTTPS: true,
        supportsRemoteHLS: true
    )

    static let mpv = PlaybackEngineCapabilities(
        supportsSeparateAudioURL: true,
        supportsAudioDelay: true,
        supportsAudioAmplification: true,
        supportsAuthoredASS: true,
        supportsHostSubtitleOverlay: false,
        supportsHTTPHeaders: true,
        // URLSession bridges top-level HTTPS media. FFmpeg's HLS demuxer opens
        // child playlists/segments itself, outside that bridge, without TLS support.
        supportsDirectHTTPS: true,
        supportsRemoteHLS: false
    )
}

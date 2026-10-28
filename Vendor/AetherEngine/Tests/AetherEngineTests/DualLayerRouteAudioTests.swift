import Testing
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// FEL uses the software audio-producer path. The upstream route policy decides whether each track
/// remains PCM, streams JOC compressed, or uses APAC; runtime failures recover without mixing formats.
@Suite("Dual-layer route audio producer and recovery")
struct DualLayerRouteAudioTests {

    @Test("a Profile 7 FEL source with the preference on takes the software host; without it, it stays native")
    func felRouteIsTheSoftwareHost() {
        func requiresSoftware(prefer: Bool) -> Bool {
            VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
                dvProfile: 7, dolbyVisionHandling: .automatic,
                preferDualLayerDolbyVision: prefer, canHardwareDecode: { true }, elType: "FEL")
        }
        #expect(requiresSoftware(prefer: true) == DualLayerRouteDecision.isBuiltIn)
        #expect(!requiresSoftware(prefer: false))
    }

    @Test("AVPlayer can decode E-AC-3 natively")
    func eac3IsNativeToAVPlayer() {
        #expect(AetherEngine.avPlayerCanDecodeAudio(AV_CODEC_ID_EAC3))
    }

    @Test("the PCM producer opens an E-AC-3 stream")
    func softwareHostOpensEAC3PCMDecode() throws {
        let formatContext = avformat_alloc_context()
        defer { avformat_free_context(formatContext) }
        let stream = try #require(avformat_new_stream(formatContext, nil))
        let codecpar = try #require(stream.pointee.codecpar)
        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = AV_CODEC_ID_EAC3
        codecpar.pointee.sample_rate = 48_000
        av_channel_layout_default(&codecpar.pointee.ch_layout, 6)
        stream.pointee.time_base = AVRational(num: 1, den: 48_000)

        let decoder = AudioDecoder()
        defer { decoder.close() }
        try decoder.open(stream: stream)
        #expect(decoder.sampleRate == 48_000)
        #expect(decoder.channels == 6)
        #expect(SoftwarePlaybackHost.audioDelivery(
            resolvedAudioIndex: stream.pointee.index, decoderOpened: true, sourceCarriesAudio: true) == .decoded)
    }

    @Test("software delivery classification follows the selected producer")
    func deliveryTracksProducerRoute() {
        let index: Int32 = 1
        #expect(SoftwarePlaybackHost.audioDelivery(
            resolvedAudioIndex: index, decoderOpened: true, sourceCarriesAudio: true, route: .pcm) == .decoded)
        #expect(SoftwarePlaybackHost.audioDelivery(
            resolvedAudioIndex: index, decoderOpened: true, sourceCarriesAudio: true,
            route: .compressedEAC3JOC) == .streamCopy)
        #expect(SoftwarePlaybackHost.audioDelivery(
            resolvedAudioIndex: index, decoderOpened: true, sourceCarriesAudio: true,
            route: .apac(.l714)) == .bridged)
    }

    @Test("APAC runtime failure is one-shot per output epoch and rejects stale host/load/seek events")
    func spatialAudioFailureRecoveryIsEpochAndIdentityGated() {
        let token = SoftwareSpatialAudioFailureToken(seekGeneration: 7, audioEpoch: 4)
        #expect(SoftwareSpatialAudioFailureRecoveryGate.accepts(
            token: token,
            failureLoadGeneration: 10,
            currentLoadGeneration: 10,
            hostIsCurrent: true,
            currentSeekGeneration: 7,
            currentAudioEpoch: 4
        ))
        #expect(!SoftwareSpatialAudioFailureRecoveryGate.accepts(
            token: token,
            failureLoadGeneration: 10,
            currentLoadGeneration: 11,
            hostIsCurrent: true,
            currentSeekGeneration: 7,
            currentAudioEpoch: 4
        ))
        #expect(!SoftwareSpatialAudioFailureRecoveryGate.accepts(
            token: token,
            failureLoadGeneration: 10,
            currentLoadGeneration: 10,
            hostIsCurrent: false,
            currentSeekGeneration: 7,
            currentAudioEpoch: 4
        ))
        #expect(!SoftwareSpatialAudioFailureRecoveryGate.accepts(
            token: token,
            failureLoadGeneration: 10,
            currentLoadGeneration: 10,
            hostIsCurrent: true,
            currentSeekGeneration: 8,
            currentAudioEpoch: 5
        ))

        var epochGate = SoftwareSpatialAudioFailureEpochGate()
        let firstClaim = epochGate.claim(epoch: 4)
        let duplicateClaim = epochGate.claim(epoch: 4)
        let nextEpochClaim = epochGate.claim(epoch: 5)
        #expect(firstClaim)
        #expect(!duplicateClaim, "one failure reports once for an output epoch")
        #expect(nextEpochClaim, "a post-seek output epoch can report its own failure")

        var terminal = SoftwareTerminalGeneration()
        let terminalRecorded = terminal.record(7)
        #expect(terminalRecorded, "stop reading the failed position while PCM recovery is pending")
        #expect(terminal.shouldPark(generation: 7))
        #expect(!terminal.shouldPark(generation: 8), "a seek superseding the recovery releases the consumer")
    }
}

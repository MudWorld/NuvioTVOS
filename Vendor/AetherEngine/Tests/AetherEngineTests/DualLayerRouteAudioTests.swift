import Testing
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AudioToolbox
@testable import AetherEngine

/// The documented audio behavior of the Profile 7 FEL dual-layer route (`LoadOptions.preferDualLayerDolbyVision`):
/// the route runs on `SoftwarePlaybackHost`, whose audio is engine-owned CoreMedia output. Only opt-in 48 kHz
/// TrueHD Atmos can use experimental APAC there; ordinary TrueHD, E-AC-3 JOC and DTS:X keep the software PCM
/// path. Native spatial rendering is selected independently by the native host.
///
/// There is no pure "audio route" function to test: the software host does not choose per codec, it opens
/// `AudioDecoder` for whatever stream it resolved. So the claim is pinned in three pieces: the FEL route is the
/// software host, the native route would hand E-AC-3 to AVPlayer, and the software host's decoder accepts E-AC-3.
@Suite("Dual-layer route audio: TrueHD Atmos APAC eligibility and PCM fallback")
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

    @Test("E-AC-3 is an AVPlayer-native codec, so only the software host's own decode path explains the core-only audio")
    func eac3IsNativeToAVPlayer() {
        #expect(AetherEngine.avPlayerCanDecodeAudio(AV_CODEC_ID_EAC3))
    }

    @Test("the software host's AudioDecoder opens an E-AC-3 stream and the delivery is the host's own decode")
    func softwareHostDecodesEAC3Itself() throws {
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
        #expect(!decoder.hasSoftwareSpatialAudioRoute)

        #expect(SoftwarePlaybackHost.audioDelivery(
            resolvedAudioIndex: stream.pointee.index, decoderOpened: true, sourceCarriesAudio: true) == .decoded)
    }

    @Test("only supported opt-in TrueHD Atmos on a VOD FEL route can use APAC")
    func softwareFELSpatialAudioEligibilityIsTrueHDOnly() {
        let rendering = ObjectAudioRendering.apac(.l916)
        let atmosLayout = SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: false, rendering: rendering,
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS,
            sampleRate: 0, supportsAPAC: true
        )
        #expect(atmosLayout == (AetherEngine.linksTrueHDObjectDecoder ? .l916 : nil))

        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: false, isLive: false, rendering: rendering,
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS,
            sampleRate: 48_000, supportsAPAC: true
        ) == nil, "non-FEL software playback remains PCM")
        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: true, rendering: rendering,
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS,
            sampleRate: 48_000, supportsAPAC: true
        ) == nil, "live playback remains on its existing path")
        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: false, rendering: rendering,
            codecID: AV_CODEC_ID_EAC3, profile: 0,
            sampleRate: 48_000, supportsAPAC: true
        ) == nil, "E-AC-3 JOC stays on PCM for FEL")
        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: false, rendering: rendering,
            codecID: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA_X,
            sampleRate: 48_000, supportsAPAC: true
        ) == nil, "DTS:X spatial routing remains native-only")
        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: false, rendering: rendering,
            codecID: AV_CODEC_ID_TRUEHD, profile: 0,
            sampleRate: 48_000, supportsAPAC: true
        ) == nil, "TrueHD without an Atmos profile stays lossless PCM")
        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: false, rendering: rendering,
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS,
            sampleRate: 96_000, supportsAPAC: true
        ) == nil, "the spatial decoder accepts 48 kHz only")
        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: false, rendering: rendering,
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS,
            sampleRate: 48_000, supportsAPAC: false
        ) == nil, "older OS versions stay on PCM")
        #expect(SoftwarePlaybackHost.softwareSpatialAudioLayout(
            decodesDualLayer: true, isLive: false, rendering: .off,
            codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS,
            sampleRate: 48_000, supportsAPAC: true
        ) == nil, "the setting is opt-in")
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

    @Test("only PCM sample buffers reach the transcription tap")
    func audioTapExcludesCompressedAPAC() {
        #expect(SoftwarePlaybackHost.shouldMirrorAudioTap(mediaSubtype: kAudioFormatLinearPCM))
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            #expect(!SoftwarePlaybackHost.shouldMirrorAudioTap(mediaSubtype: kAudioFormatAPAC))
        }
    }
}

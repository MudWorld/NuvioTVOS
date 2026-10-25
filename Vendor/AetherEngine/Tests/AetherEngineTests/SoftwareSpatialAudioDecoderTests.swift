#if TrueHDObjectAudio
import AudioToolbox
import CoreMedia
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// Exercises the software-host APAC adapter's compressed-sample contract without TrueHD media or
/// a hardware audio route. The bridge and APAC output are synthetic; CoreMedia builds real buffers.
@Suite("Software spatial audio decoder")
struct SoftwareSpatialAudioDecoderTests {
    private enum SetupError: Error { case formatDescription, packetAllocation }

    private static let channelCount = SpatialSpeakerLayout.l714.channelCount
    private static let packetBytes: [UInt8] = [0xA1, 0xB2, 0xC3, 0xD4]

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func makeFormatDescription() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatAPAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(APACEncoder.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var layout = AudioChannelLayout(
            mChannelLayoutTag: SpatialSpeakerLayout.l714.channelLayoutTag,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )
        // A well-sized dapa atom is sufficient for CoreMedia's packet-buffer contract tests.
        let cookie: [UInt8] = [0, 0, 0, 12, 0x64, 0x61, 0x70, 0x61, 0, 0, 0, 0]
        var description: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size,
                layout: &layout,
                magicCookieSize: cookie.count,
                magicCookie: raw.baseAddress,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else { throw SetupError.formatDescription }
        return description
    }

    private static func makePacket(
        bytes: [UInt8] = packetBytes,
        pts: Int64 = 4_800,
        dts: Int64 = 4_560
    ) throws -> UnsafeMutablePointer<AVPacket> {
        guard let packet = av_packet_alloc() else { throw SetupError.packetAllocation }
        guard av_new_packet(packet, Int32(bytes.count)) >= 0 else {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
            throw SetupError.packetAllocation
        }
        bytes.withUnsafeBufferPointer { source in
            packet.pointee.data.update(from: source.baseAddress!, count: bytes.count)
        }
        packet.pointee.pts = pts
        packet.pointee.dts = dts
        return packet
    }

    /// One synthetic 2048-frame bed block per pushed packet, enough to exercise a bridge encode.
    private final class OneChunkDecoder: ObjectAudioDecoding {
        private let plane = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
        private var nextOffset: Int64 = 0
        private var pendingOffsets: [Int64] = []

        init() { plane.initialize(repeating: 0, count: 2048) }
        deinit {
            plane.deinitialize(count: 2048)
            plane.deallocate()
        }

        func push(_ bytes: UnsafeRawBufferPointer) {
            guard !bytes.isEmpty else { return }
            pendingOffsets.append(nextOffset)
            nextOffset += 2048
        }

        func nextBlock() -> ObjectAudioDecodedBlock? {
            guard !pendingOffsets.isEmpty else { return nil }
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000,
                frameCount: 2048,
                inputFrameOffset: pendingOffsets.removeFirst(),
                configurationGeneration: 0,
                roles: [.bed(.left)],
                planes: [UnsafePointer(plane)],
                updates: []
            )
        }

        func reset() {
            nextOffset = 0
            pendingOffsets.removeAll(keepingCapacity: true)
        }
    }

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private final class PacketEncoder: APACEncoding {
        let magicCookie = Data([0, 0, 0, 12, 0x64, 0x61, 0x70, 0x61, 0, 0, 0, 0])
        let leadingFrames = 0
        let sampleBufferFormatDescription: CMAudioFormatDescription?

        init(formatDescription: CMAudioFormatDescription) {
            sampleBufferFormatDescription = formatDescription
        }

        func encode(planes: [UnsafePointer<Float>], frameCount: Int) -> [APACEncoder.Packet] {
            [APACEncoder.Packet(data: Data([0xA1, 0xB2, 0xC3, 0xD4]), isSync: true)]
        }

        func flush() -> [APACEncoder.Packet] { [] }
        func reset() {}
    }

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private static func makeAdapter() throws -> SoftwareSpatialAudioDecoder {
        let formatDescription = try makeFormatDescription()
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 48_000),
            layout: .l714,
            decoder: OneChunkDecoder(),
            encoderFactory: { _, _, _ in PacketEncoder(formatDescription: formatDescription) }
        )
        return SoftwareSpatialAudioDecoder(
            bridge: bridge,
            formatDescription: formatDescription,
            layout: .l714
        )
    }

    @Test("one compressed APAC packet retains frames, time, and owned bytes")
    func sampleBufferContract() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let formatDescription = try Self.makeFormatDescription()
        let packet = try Self.makePacket()
        defer {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
        }

        let sampleBuffer = try SoftwareSpatialAudioDecoder.makeSampleBuffer(
            packet: packet,
            formatDescription: formatDescription
        )
        #expect(CMSampleBufferGetNumSamples(sampleBuffer) == 1)
        #expect(CMTimeCompare(
            CMSampleBufferGetDuration(sampleBuffer),
            CMTime(value: 1024, timescale: 48_000)
        ) == 0)
        #expect(CMTimeCompare(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            CMTime(value: 4_800, timescale: 48_000)
        ) == 0)
        #expect(CMTimeCompare(
            CMSampleBufferGetDecodeTimeStamp(sampleBuffer),
            CMTime(value: 4_560, timescale: 48_000)
        ) == 0)

        var packetDescriptions: UnsafePointer<AudioStreamPacketDescription>?
        var descriptionBytes = 0
        #expect(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
            sampleBuffer,
            packetDescriptionsPointerOut: &packetDescriptions,
            sizeOut: &descriptionBytes
        ) == noErr)
        let packetDescription = try #require(packetDescriptions?.pointee)
        #expect(descriptionBytes == MemoryLayout<AudioStreamPacketDescription>.size)
        #expect(packetDescription.mVariableFramesInPacket == 1024)
        #expect(packetDescription.mDataByteSize == UInt32(Self.packetBytes.count))

        packet.pointee.data.update(repeating: 0x00, count: Self.packetBytes.count)
        let blockBuffer = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
        var copiedBytes = [UInt8](repeating: 0, count: Self.packetBytes.count)
        let copyStatus = copiedBytes.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: Self.packetBytes.count,
                destination: destination.baseAddress!
            )
        }
        #expect(copyStatus == kCMBlockBufferNoErr)
        #expect(copiedBytes == Self.packetBytes, "CoreMedia owns a copy of the compressed packet")
    }

    @Test("drain, segment reset, and close update adapter state")
    func adapterLifecycle() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let adapter = try Self.makeAdapter()
        defer { adapter.close() }
        let firstPacket = try Self.makePacket(pts: 9_600, dts: 9_600)
        defer {
            var owned: UnsafeMutablePointer<AVPacket>? = firstPacket
            av_packet_free(&owned)
        }

        #expect(adapter.isActive)
        _ = try adapter.decode(packet: firstPacket)
        #expect(!(try adapter.drain()).isEmpty)
        #expect(!adapter.isActive)
        #expect(adapter.isRouteEligible, "the output route remains eligible while drained APAC tail audio plays")
        #expect(try adapter.drain().isEmpty)
        #expect(throws: SoftwareSpatialAudioDecoder.AdapterError.self) {
            try adapter.decode(packet: firstPacket)
        }

        adapter.startSegment()
        #expect(adapter.isActive)
        let secondPacket = try Self.makePacket(pts: 48_000, dts: 48_000)
        defer {
            var owned: UnsafeMutablePointer<AVPacket>? = secondPacket
            av_packet_free(&owned)
        }
        _ = try adapter.decode(packet: secondPacket)
        #expect(!(try adapter.drain()).isEmpty)
        #expect(!adapter.isActive)
        #expect(adapter.isRouteEligible, "draining a reset segment does not stop output-route eligibility")

        adapter.close()
        #expect(!adapter.isActive)
        #expect(!adapter.isRouteEligible)
        #expect(try adapter.drain().isEmpty)
        #expect(throws: SoftwareSpatialAudioDecoder.AdapterError.self) {
            try adapter.decode(packet: secondPacket)
        }
    }

    @Test("bridge encoder setup errors are propagated")
    func setupFailurePropagates() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        #expect(throws: SetupError.self) {
            try SpatialAudioBridge(
                srcTimeBase: AVRational(num: 1, den: 48_000),
                layout: .l714,
                decoder: OneChunkDecoder(),
                encoderFactory: { _, _, _ in throw SetupError.formatDescription }
            )
        }
    }
}
#endif

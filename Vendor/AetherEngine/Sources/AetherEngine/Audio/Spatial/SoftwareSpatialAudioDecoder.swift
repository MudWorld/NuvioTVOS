#if TrueHDObjectAudio
import CoreMedia
import AudioToolbox
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation

/// Direct TrueHD Atmos to APAC adapter for the software video host. It preserves the bridge's
/// packet timestamps and leading APAC packets; sample buffers stay on AudioOutput's shared clock.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class SoftwareSpatialAudioDecoder: @unchecked Sendable {
    enum AdapterError: Error, CustomStringConvertible {
        case noFormatDescription
        case invalidPacket
        case blockBuffer(OSStatus)
        case copyPacket(OSStatus)
        case sampleBuffer(OSStatus)
        case bridge(String)
        case alreadyFailed

        var description: String {
            switch self {
            case .noFormatDescription: return "APAC encoder supplied no CoreMedia format description"
            case .invalidPacket: return "APAC bridge emitted a packet without valid data or timestamps"
            case .blockBuffer(let status): return "APAC CMBlockBuffer creation failed (\(status))"
            case .copyPacket(let status): return "APAC packet copy failed (\(status))"
            case .sampleBuffer(let status): return "APAC CMSampleBuffer creation failed (\(status))"
            case .bridge(let message): return message
            case .alreadyFailed: return "APAC adapter is stopped after a runtime failure"
            }
        }
    }

    static let initializationPacketThreshold = SpatialAudioBridge.silentFeedPacketThreshold

    let layout: SpatialSpeakerLayout
    let formatDescription: CMAudioFormatDescription
    var pipelineName: String { "TrueHD Atmos → APAC \(layout.rawValue)" }
    var isActive: Bool { !failed && !drained && !closed }
    var isRouteEligible: Bool { !failed && !closed }
    var objectAudioActivity: ObjectAudioActivity? { isRouteEligible ? bridge.objectAudioActivity : nil }

    private let bridge: SpatialAudioBridge
    private var failed = false
    private var drained = false
    private var closed = false

    convenience init(stream: UnsafeMutablePointer<AVStream>, layout: SpatialSpeakerLayout) throws {
        let decoder = try TrueHDObjectAudioDecoder(splitsBed: !TrueHDReferenceRender.isOn)
        let bridge = try SpatialAudioBridge(
            srcTimeBase: stream.pointee.time_base,
            layout: layout,
            decoder: decoder
        )
        guard let formatDescription = bridge.sampleBufferFormatDescription else {
            bridge.close()
            throw AdapterError.noFormatDescription
        }
        self.init(bridge: bridge, formatDescription: formatDescription, layout: layout)
    }

    init(
        bridge: SpatialAudioBridge,
        formatDescription: CMAudioFormatDescription,
        layout: SpatialSpeakerLayout
    ) {
        self.bridge = bridge
        self.formatDescription = formatDescription
        self.layout = layout
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) throws -> [CMSampleBuffer] {
        guard !closed, !drained else { throw AdapterError.alreadyFailed }
        guard !failed else { throw AdapterError.alreadyFailed }

        let packets = try bridge.feed(packet: packet)
        if let failure = bridge.runtimeFailureDescription {
            failed = true
            packets.forEach(free)
            throw AdapterError.bridge(failure)
        }
        do {
            return try sampleBuffers(from: packets)
        } catch {
            failed = true
            throw error
        }
    }

    func drain() throws -> [CMSampleBuffer] {
        guard !closed, !drained else { return [] }
        drained = true
        let packets = bridge.flush()
        if let failure = bridge.runtimeFailureDescription {
            failed = true
            packets.forEach(free)
            throw AdapterError.bridge(failure)
        }
        do {
            return try sampleBuffers(from: packets)
        } catch {
            failed = true
            throw error
        }
    }

    func startSegment() {
        guard !closed else { return }
        bridge.startSegment()
        failed = false
        drained = false
    }

    func stopAfterFailure() {
        failed = true
    }

    func close() {
        guard !closed else { return }
        closed = true
        bridge.close()
    }

    private func sampleBuffers(from packets: [UnsafeMutablePointer<AVPacket>]) throws -> [CMSampleBuffer] {
        defer { packets.forEach(free) }
        var result: [CMSampleBuffer] = []
        for packet in packets {
            result.append(try Self.makeSampleBuffer(packet: packet, formatDescription: formatDescription))
        }
        return result
    }

    private func free(_ packet: UnsafeMutablePointer<AVPacket>) {
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&owned)
    }

    static func makeSampleBuffer(
        packet: UnsafeMutablePointer<AVPacket>,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        guard let bytes = packet.pointee.data,
              packet.pointee.size > 0,
              packet.pointee.pts != Int64.min,
              packet.pointee.size <= Int32.max else {
            throw AdapterError.invalidPacket
        }

        let byteCount = Int(packet.pointee.size)
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw AdapterError.blockBuffer(blockStatus)
        }
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard copyStatus == kCMBlockBufferNoErr else { throw AdapterError.copyPacket(copyStatus) }

        let pts = CMTime(value: packet.pointee.pts, timescale: Int32(SpatialAudioBridge.sampleRate))
        let dtsTicks = packet.pointee.dts == Int64.min ? packet.pointee.pts : packet.pointee.dts
        let dts = CMTime(value: dtsTicks, timescale: Int32(SpatialAudioBridge.sampleRate))
        var description = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: UInt32(APACEncoder.framesPerPacket),
            mDataByteSize: UInt32(byteCount)
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            presentationTimeStamp: pts,
            packetDescriptions: &description,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw AdapterError.sampleBuffer(sampleStatus)
        }

        // The convenience API accepts PTS only. Preserve the bridge's DTS on the shared timeline.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(APACEncoder.framesPerPacket), timescale: Int32(SpatialAudioBridge.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: dts
        )
        var timedSampleBuffer: CMSampleBuffer?
        let timingStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &timedSampleBuffer
        )
        guard timingStatus == noErr, let timedSampleBuffer else {
            throw AdapterError.sampleBuffer(timingStatus)
        }
        return timedSampleBuffer
    }
}
#endif

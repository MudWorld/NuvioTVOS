import Testing
import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// A packet read or EOF captured before a seek must not enter the producer after its flush.
@Suite("Software audio producer feed epochs")
struct SoftwareProducerEpochTests {
    private enum SetupError: Error { case allocationFailed }

    private static let sampleRate: Int32 = 48_000
    private static let jocBox = Data([0, 0, 0, 0x0f, 0x64, 0x65, 0x63, 0x33, 0x0e, 0, 0x20, 0x0f, 0, 0x01, 0x0c])

    private func withPCMDecoder(_ body: (AudioDecoder) throws -> Void) throws {
        let context = try #require(avformat_alloc_context())
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        let parameters = try #require(stream.pointee.codecpar)
        parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        parameters.pointee.codec_id = AV_CODEC_ID_PCM_F32LE
        parameters.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
        parameters.pointee.sample_rate = Self.sampleRate
        parameters.pointee.bits_per_coded_sample = 32
        parameters.pointee.block_align = 8
        av_channel_layout_default(&parameters.pointee.ch_layout, 2)
        stream.pointee.time_base = AVRational(num: 1, den: Self.sampleRate)

        let decoder = AudioDecoder()
        defer { decoder.close() }
        try decoder.open(stream: stream)
        try body(decoder)
    }

    private func withJOCProducer(_ body: (SoftwareEAC3Passthrough) throws -> Void) throws {
        let context = try #require(avformat_alloc_context())
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        stream.pointee.time_base = AVRational(num: 1, den: Self.sampleRate)
        let format = try #require(SoftwareEAC3Passthrough.formatDescription(dec3Box: Self.jocBox))
        let producer = try SoftwareEAC3Passthrough(stream: stream, formatDescription: format)
        defer { producer.close() }
        try body(producer)
    }

    /// Zero bytes form valid silent interleaved float32 PCM, or opaque payload for the JOC packet wrapper.
    private func packet(byteCount: Int, pts: Int64, dts: Int64? = nil) throws -> UnsafeMutablePointer<AVPacket> {
        guard let packet = av_packet_alloc() else { throw SetupError.allocationFailed }
        guard av_new_packet(packet, Int32(byteCount)) >= 0 else {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
            throw SetupError.allocationFailed
        }
        packet.pointee.data.update(repeating: 0, count: byteCount)
        packet.pointee.pts = pts
        packet.pointee.dts = dts ?? pts
        return packet
    }

    private func free(_ packet: UnsafeMutablePointer<AVPacket>) {
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&owned)
    }

    @Test("a packet captured before flush cannot join the next PCM tail")
    func stalePCMDecodeCannotContaminateFreshTail() throws {
        try withPCMDecoder { decoder in
            let capturedEpoch = decoder.feedEpoch
            let bufferedBeforeSeek = try packet(byteCount: 128 * 8, pts: 2_400)
            defer { free(bufferedBeforeSeek) }
            #expect(decoder.decode(packet: bufferedBeforeSeek, epoch: capturedEpoch).isEmpty)

            decoder.flush()
            let freshEpoch = decoder.feedEpoch
            #expect(freshEpoch == capturedEpoch + 1)

            let stalePacket = try packet(byteCount: 128 * 8, pts: 48_000)
            defer { free(stalePacket) }
            #expect(decoder.decode(packet: stalePacket, epoch: capturedEpoch).isEmpty)

            let freshFrames = 256
            let freshPTS: Int64 = 9_600
            let freshPacket = try packet(byteCount: freshFrames * 8, pts: freshPTS)
            defer { free(freshPacket) }
            #expect(decoder.decode(packet: freshPacket, epoch: freshEpoch).isEmpty)

            let tail = decoder.endOfStream(epoch: freshEpoch)
            let sample = try #require(tail.first)
            #expect(tail.count == 1)
            #expect(CMSampleBufferGetNumSamples(sample) == freshFrames)
            let sampleData = try #require(CMSampleBufferGetDataBuffer(sample))
            #expect(CMBlockBufferGetDataLength(sampleData) == freshFrames * 8)
            #expect(CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp(sample),
                CMTime(value: freshPTS, timescale: Self.sampleRate)
            ) == 0)
        }
    }

    @Test("stale PCM EOF cannot drain or poison the post-seek decoder")
    func stalePCMEndOfStreamCannotDrainFreshTail() throws {
        try withPCMDecoder { decoder in
            let capturedEpoch = decoder.feedEpoch
            decoder.flush()
            let freshEpoch = decoder.feedEpoch

            #expect(decoder.endOfStream(epoch: capturedEpoch).isEmpty)

            let freshFrames = 320
            let freshPacket = try packet(byteCount: freshFrames * 8, pts: 24_000)
            defer { free(freshPacket) }
            #expect(decoder.decode(packet: freshPacket, epoch: freshEpoch).isEmpty)

            // A second stale EOF after new PCM is pending must leave that tail for the current epoch.
            #expect(decoder.endOfStream(epoch: capturedEpoch).isEmpty)
            let tail = decoder.endOfStream(epoch: freshEpoch)
            let sample = try #require(tail.first)
            #expect(tail.count == 1)
            #expect(CMSampleBufferGetNumSamples(sample) == freshFrames)
            let sampleData = try #require(CMSampleBufferGetDataBuffer(sample))
            #expect(CMBlockBufferGetDataLength(sampleData) == freshFrames * 8)
        }
    }

    @Test("PCM close retires its current feed epoch")
    func pcmCloseRetiresEpoch() throws {
        try withPCMDecoder { decoder in
            let epoch = decoder.feedEpoch
            decoder.close()
            #expect(decoder.feedEpoch == epoch + 1)
            #expect(decoder.endOfStream(epoch: epoch).isEmpty)
        }
    }

    @Test("stale JOC timestamps cannot anchor an unstamped leading packet")
    func staleJOCDecodeAndUnstampedLeadAreSkipped() throws {
        try withJOCProducer { producer in
            let capturedEpoch = producer.feedEpoch
            producer.flush()
            let freshEpoch = producer.feedEpoch
            #expect(freshEpoch == capturedEpoch + 1)

            let stalePacket = try packet(byteCount: 32, pts: 480_000)
            defer { free(stalePacket) }
            #expect(producer.decode(packet: stalePacket, epoch: capturedEpoch).isEmpty)

            let unstampedLead = try packet(byteCount: 32, pts: Int64.min, dts: Int64.min)
            defer { free(unstampedLead) }
            #expect(producer.decode(packet: unstampedLead, epoch: freshEpoch).isEmpty)
            #expect(producer.takeRuntimeFailure() == nil)

            let validPTS: Int64 = 96_000 // 2 s on the stream's 1/48000 axis.
            let validPacket = try packet(byteCount: 32, pts: validPTS)
            defer { free(validPacket) }
            let sample = try #require(producer.decode(packet: validPacket, epoch: freshEpoch).first)
            #expect(CMSampleBufferGetNumSamples(sample) == 1)
            #expect(CMTimeCompare(
                CMSampleBufferGetPresentationTimeStamp(sample),
                CMTime(value: 180_000, timescale: 90_000)
            ) == 0)
            #expect(producer.takeRuntimeFailure() == nil)

            producer.close()
            #expect(producer.feedEpoch == freshEpoch + 1)
            #expect(producer.decode(packet: validPacket, epoch: freshEpoch).isEmpty)
            #expect(producer.endOfStream(epoch: freshEpoch).isEmpty)
        }
    }
}

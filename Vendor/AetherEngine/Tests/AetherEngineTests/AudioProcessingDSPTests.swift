import Foundation
import XCTest
@testable import AetherEngine

final class AudioProcessingDSPTests: XCTestCase {
    private let sampleRate = 48_000

    func testQuietEnhanceDoesNotAttenuateOrMute() {
        let input = [Float](repeating: 0.002, count: sampleRate)
        let output = render(
            input,
            channelCount: 1,
            settings: AudioProcessingSettings(dialogue: .enhance),
            chunkFrames: 40
        )
        let steadyMean = output.suffix(sampleRate / 2).map(abs).reduce(0, +) / Float(sampleRate / 2)

        XCTAssertGreaterThan(steadyMean, 0.01)
        XCTAssertLessThan(steadyMean, 0.05)
    }

    func testMonoDialogueMatchesCenterOnlyInSevenPointOne() {
        let input = (0..<(sampleRate / 2)).map { frame in
            Float(0.02 * sin(2 * Double.pi * 440 * Double(frame) / Double(sampleRate)))
        }
        var surround = [Float](repeating: 0, count: input.count * 8)
        for frame in input.indices {
            surround[frame * 8 + 2] = input[frame] // center channel
        }
        let settings = AudioProcessingSettings(dialogue: .enhance)
        let monoOutput = render(input, channelCount: 1, settings: settings, chunkFrames: 40)
        let surroundOutput = render(surround, channelCount: 8, settings: settings, chunkFrames: 40)

        for frame in input.indices {
            XCTAssertEqual(surroundOutput[frame * 8 + 2], monoOutput[frame], accuracy: 0.000001)
        }
    }

    func testOutputDoesNotDependOnDecoderFramePartition() {
        let input = (0..<28_480).map { frame in
            let amplitude: Double = frame < 4_800 ? 0.004 : 0.06
            return Float(amplitude * sin(2 * Double.pi * 1_500 * Double(frame) / Double(sampleRate)))
        }
        let settings = AudioProcessingSettings(dialogue: .boost, reduceLoudSounds: true)
        let output40 = render(input, channelCount: 1, settings: settings, chunkFrames: 40)
        let output1536 = render(input, channelCount: 1, settings: settings, chunkFrames: 1_536)

        XCTAssertEqual(output40.count, output1536.count)
        for index in output40.indices {
            XCTAssertEqual(output40[index], output1536[index], accuracy: 0.000001)
        }
    }

    func testUnprocessedPCMIsBitExact() {
        let input: [Float] = [0.1234, -0.987, 0, 0.5, -0.25, 0.001]
        let output = render(input, channelCount: 1, settings: AudioProcessingSettings(), chunkFrames: 40)
        XCTAssertEqual(output, input)
    }

    func testReduceLoudSoundsUsesFourToOneSteadyStateCurve() {
        let input = [Float](repeating: 0.8, count: sampleRate)
        let output = render(
            input,
            channelCount: 1,
            settings: AudioProcessingSettings(reduceLoudSounds: true),
            chunkFrames: 40
        )
        let steady = output.suffix(sampleRate / 10).reduce(0, +) / Float(sampleRate / 10)
        let expected = Float(0.1 * pow(0.8 / 0.1, 0.25))

        XCTAssertEqual(steady, expected, accuracy: 0.005)
    }

    func testResetClearsFilterHistoryAndPreservesSettings() {
        var processor = AudioProcessingDSP()
        let settings = AudioProcessingSettings(dialogue: .boost)
        processor.setSettings(settings)
        var tone = (0..<1_024).map { frame in
            Float(0.4 * sin(2 * Double.pi * 1_500 * Double(frame) / Double(sampleRate)))
        }
        let toneCount = tone.count
        tone.withUnsafeMutableBufferPointer { buffer in
            processor.process(
                interleavedSamples: buffer.baseAddress!, frameCount: toneCount,
                channelCount: 1, sampleRate: sampleRate
            )
        }

        processor.reset()
        var silence = [Float](repeating: 0, count: 1_024)
        let silenceCount = silence.count
        silence.withUnsafeMutableBufferPointer { buffer in
            processor.process(
                interleavedSamples: buffer.baseAddress!, frameCount: silenceCount,
                channelCount: 1, sampleRate: sampleRate
            )
        }
        XCTAssertEqual(silence, [Float](repeating: 0, count: silence.count))

        var quiet = [Float](repeating: 0.002, count: sampleRate / 2)
        var firstFrame = 0
        while firstFrame < quiet.count {
            let frameCount = min(40, quiet.count - firstFrame)
            quiet.withUnsafeMutableBufferPointer { buffer in
                processor.process(
                    interleavedSamples: buffer.baseAddress!.advanced(by: firstFrame),
                    frameCount: frameCount,
                    channelCount: 1,
                    sampleRate: sampleRate
                )
            }
            firstFrame += frameCount
        }
        let mean = quiet.suffix(sampleRate / 4).map(abs).reduce(0, +) / Float(sampleRate / 4)
        XCTAssertGreaterThan(mean, 0.01)
    }

    func testBoostIsFinitePeakLimitedAndUsesLinkedChannelGain() {
        let frames = sampleRate * 2
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let sample = Float(0.8 * sin(2 * Double.pi * 1_500 * Double(frame) / Double(sampleRate)))
            input[frame * 2] = sample
            input[frame * 2 + 1] = sample * 0.5
        }
        let output = render(
            input,
            channelCount: 2,
            settings: AudioProcessingSettings(dialogue: .boost),
            chunkFrames: 40
        )
        let peak = output.map(abs).max() ?? 0
        let leftRMS = sqrt(output.enumerated().reduce(0.0) { sum, element in
            guard element.offset % 2 == 0 else { return sum }
            return sum + Double(element.element * element.element)
        } / Double(frames))
        let rightRMS = sqrt(output.enumerated().reduce(0.0) { sum, element in
            guard element.offset % 2 == 1 else { return sum }
            return sum + Double(element.element * element.element)
        } / Double(frames))

        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(peak, 0.980001)
        XCTAssertEqual(leftRMS / rightRMS, 2, accuracy: 0.001)
    }

    private func render(
        _ input: [Float],
        channelCount: Int,
        settings: AudioProcessingSettings,
        chunkFrames: Int
    ) -> [Float] {
        var output = input
        var processor = AudioProcessingDSP()
        processor.setSettings(settings)
        let totalFrames = input.count / channelCount
        var firstFrame = 0
        while firstFrame < totalFrames {
            let frameCount = min(chunkFrames, totalFrames - firstFrame)
            output.withUnsafeMutableBufferPointer { buffer in
                processor.process(
                    interleavedSamples: buffer.baseAddress!.advanced(by: firstFrame * channelCount),
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sampleRate: sampleRate
                )
            }
            firstFrame += frameCount
        }
        return output
    }
}

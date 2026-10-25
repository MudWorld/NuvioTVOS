import AVFoundation
import CoreImage
import Testing
@testable import AetherEngine

@MainActor
@Suite
struct NativeVideoFrameCaptureTests {
    private let tenBitVideoRange = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    private let tenBitFullRange = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

    nonisolated private static var explicitToneMappingAvailable: Bool {
        if #available(iOS 18, tvOS 18, macOS 15, visionOS 2, *) { return true }
        return false
    }

    private struct RGBA8Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int

        var luma: Double {
            0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)
        }
    }

    private func hasVideoFrameOutput(_ item: AVPlayerItem) -> Bool {
        item.outputs.contains { $0 is AVPlayerItemVideoOutput }
    }

    private func rgbaPixel(_ image: CGImage, x: Int, y: Int) throws -> RGBA8Pixel {
        let data = try #require(image.dataProvider?.data as Data?)
        let offset = y * image.bytesPerRow + x * 4
        return RGBA8Pixel(
            red: Int(data[offset]),
            green: Int(data[offset + 1]),
            blue: Int(data[offset + 2]),
            alpha: Int(data[offset + 3])
        )
    }

    private func pixelDescription(_ pixels: [RGBA8Pixel]) -> String {
        pixels.map { "(\($0.red),\($0.green),\($0.blue);Y=\(Int($0.luma)))" }.joined(separator: " ")
    }

    private func contentHeadroomDescription(_ image: CIImage) -> String {
        if #available(tvOS 18, macOS 15, iOS 18, visionOS 2, *) {
            return String(image.contentHeadroom)
        }
        return "unavailable"
    }

    private func attachmentDescription(_ key: CFString, from buffer: CVPixelBuffer) -> String {
        String(describing: CVBufferGetAttachment(buffer, key, nil))
    }

    private func makeTenBitHDRPatchBuffer(
        pixelFormat: OSType,
        width: Int = 24,
        height: Int = 8
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                         attributes as CFDictionary, &pixelBuffer)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        try #require(CVPixelBufferGetPlaneCount(buffer) == 2)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let yPlane = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let uvPlane = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let isVideoRange = pixelFormat == tenBitVideoRange
        let lumaCodes: [UInt16] = isVideoRange ? [64, 512, 900] : [0, 512, 900]
        let encodedChroma = UInt16(512 << 6)
        for row in 0..<height {
            let samples = yPlane.advanced(by: row * yStride).assumingMemoryBound(to: UInt16.self)
            for column in 0..<width {
                let patch = min(2, column * 3 / width)
                samples[column] = lumaCodes[patch] << 6
            }
        }
        for row in 0..<(height / 2) {
            let samples = uvPlane.advanced(by: row * uvStride).assumingMemoryBound(to: UInt16.self)
            for column in 0..<width { samples[column] = encodedChroma }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }

    private func makeHalfFloatPQBuffer(width: Int = 40, height: Int = 8) throws -> CVPixelBuffer {
        let pixelFormat = kCVPixelFormatType_64RGBAHalf
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                         attributes as CFDictionary, &pixelBuffer)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let baseAddress = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let patches: [[Float16]] = [
            [0, 0, 0, 1],
            [0.56, 0.52, 0.48, 1],
            [0.50, 0.50, 0.50, 1],
            [0.65, 0.65, 0.65, 1],
            [0.75, 0.75, 0.75, 1]
        ]
        for row in 0..<height {
            let pixels = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for column in 0..<width {
                let patch = min(4, column * 5 / width)
                for channel in 0..<4 {
                    pixels[column * 4 + channel] = patches[patch][channel].bitPattern
                }
            }
        }

        let hdrColorSpace = try #require(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, hdrColorSpace, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return buffer
    }

    private func renderWithoutToneMapping(from pixelBuffer: CVPixelBuffer, maxWidth: Int) throws -> CGImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, CGFloat(maxWidth) / image.extent.width)
        let scaledImage = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try #require(CIContext().createCGImage(
            scaledImage,
            from: scaledImage.extent,
            format: .RGBA8,
            colorSpace: sRGB
        ))
    }

    private func makeSDRColorPatchBuffer(width: Int = 12, height: Int = 8) throws -> CVPixelBuffer {
        let pixelFormat = kCVPixelFormatType_32BGRA
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(pixelFormat),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                         attributes as CFDictionary, &pixelBuffer)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let baseAddress = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bgraPatches: [[UInt8]] = [
            [20, 40, 220, 255],
            [30, 190, 20, 255],
            [210, 40, 30, 255]
        ]
        for row in 0..<height {
            let pixels = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let patch = min(2, column * 3 / width)
                for channel in 0..<4 {
                    pixels[column * 4 + channel] = bgraPatches[patch][channel]
                }
            }
        }
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }

    @Test("analysis chooses source DV route before effective display format")
    func analysisRouteUsesSourceFormatAndProfile() {
        #expect(AetherEngine.videoFrameAnalysisRoute(
            sourceVideoFormat: .dolbyVision, sourceDVProfile: 5, sourceDVBLCompatID: 0,
            effectiveVideoFormat: .hdr10, hasSoftwareHost: false) == "resident-dovi-rpu")
        #expect(AetherEngine.videoFrameAnalysisRoute(
            sourceVideoFormat: .dolbyVision, sourceDVProfile: 8, sourceDVBLCompatID: 1,
            effectiveVideoFormat: .hdr10, hasSoftwareHost: false) == "native-output")
        #expect(AetherEngine.videoFrameAnalysisRoute(
            sourceVideoFormat: .hdr10, sourceDVProfile: nil, sourceDVBLCompatID: nil,
            effectiveVideoFormat: .sdr, hasSoftwareHost: false) == "native-output")
        #expect(AetherEngine.videoFrameAnalysisRoute(
            sourceVideoFormat: .dolbyVision, sourceDVProfile: 10, sourceDVBLCompatID: 1,
            effectiveVideoFormat: .hdr10, hasSoftwareHost: false) == "native-output")
        #expect(AetherEngine.videoFrameAnalysisRoute(
            sourceVideoFormat: .dolbyVision, sourceDVProfile: 10, sourceDVBLCompatID: nil,
            effectiveVideoFormat: .hdr10, hasSoftwareHost: false) == "resident-dovi-rpu")
        #expect(AetherEngine.videoFrameAnalysisRoute(
            sourceVideoFormat: .dolbyVision, sourceDVProfile: 5, sourceDVBLCompatID: 0,
            effectiveVideoFormat: .hdr10, hasSoftwareHost: true) == "software")
        #expect(AetherEngine.videoFrameAnalysisRoute(
            sourceVideoFormat: .dolbyVision, sourceDVProfile: 10, sourceDVBLCompatID: 0,
            effectiveVideoFormat: .hdr10, hasSoftwareHost: false) == "resident-dovi-rpu")
        #expect(NativeVideoOutputPolicy.allowsNativeVideoOutput(
            sourceVideoFormat: .dolbyVision, dolbyVisionProfile: 8, baseLayerCompatibilityID: nil))
        #expect(!NativeVideoOutputPolicy.allowsNativeVideoOutput(
            sourceVideoFormat: .dolbyVision, dolbyVisionProfile: nil, baseLayerCompatibilityID: nil))
        #expect(!NativeVideoOutputPolicy.allowsNativeVideoOutput(
            sourceVideoFormat: .dolbyVision, dolbyVisionProfile: 5, baseLayerCompatibilityID: 1))
        #expect(!NativeVideoOutputPolicy.allowsNativeVideoOutput(
            sourceVideoFormat: .dolbyVision, dolbyVisionProfile: 10, baseLayerCompatibilityID: nil))
        #expect(!NativeVideoOutputPolicy.allowsNativeVideoOutput(
            sourceVideoFormat: .dolbyVision, dolbyVisionProfile: 10, baseLayerCompatibilityID: 0))
        #expect(NativeVideoOutputPolicy.allowsNativeVideoOutput(
            sourceVideoFormat: .dolbyVision, dolbyVisionProfile: 10, baseLayerCompatibilityID: 1))
        #expect(NativeVideoOutputPolicy.allowsNativeVideoOutput(
            sourceVideoFormat: .hdr10, dolbyVisionProfile: nil, baseLayerCompatibilityID: nil))
    }

    @Test("source-known P5 analysis fails closed without a resident decoder source")
    func profile5AnalysisDoesNotFallBackToNativeOutput() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        engine.sourceVideoFormat = .dolbyVision
        engine.sourceDVProfile = 5
        engine.sourceDVBLCompatID = 0
        engine.effectiveVideoFormat = .hdr10

        let capture = await engine.captureVideoFrameForAnalysis()
        #expect(capture.image == nil)
        #expect(capture.diagnostics.contains("route=resident-dovi-rpu"))
        let expectedReason = AetherEngine.OptionalComponent.dolbyVisionStillReshaping.isBuiltIn
            ? "reason=native-session-unavailable"
            : "reason=dv-reshaping-unavailable"
        #expect(capture.diagnostics.contains(expectedReason))
    }

    @Test("disabled frame capture stays disabled across an item swap")
    func disabledCaptureSurvivesSwap() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil, contract: .init(
            allowsVideoFrameCapture: false,
            videoFrameCapturePixelFormat: tenBitVideoRange))
        let firstItem = try #require(host.avPlayer.currentItem)
        #expect(!hasVideoFrameOutput(firstItem))

        host.swapItem(url: url, startPosition: nil)
        let swappedItem = try #require(host.avPlayer.currentItem)
        #expect(!hasVideoFrameOutput(swappedItem))
        #expect(!host.sessionContract.allowsVideoFrameCapture)
        #expect(host.sessionContract.videoFrameCapturePixelFormat == tenBitVideoRange)
        #expect(host.videoFrameCaptureDebugSummary == "VIDTAP enabled=no requested=x420 actual=pending")
    }

    @Test("protected session attaches no persistent output on load or swap")
    func protectedSessionDisablesPersistentOutput() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil, contract: .init(allowsNativeVideoOutput: false))
        let firstItem = try #require(host.avPlayer.currentItem)
        #expect(!hasVideoFrameOutput(firstItem))
        #expect(host.sessionContract.allowsVideoFrameCapture)
        #expect(!host.sessionContract.allowsNativeVideoOutput)
        #expect(host.videoFrameCaptureDebugSummary == "VIDTAP enabled=no requested=BGRA actual=pending")

        host.swapItem(url: url, startPosition: nil)
        let swappedItem = try #require(host.avPlayer.currentItem)
        #expect(!hasVideoFrameOutput(swappedItem))
        #expect(!host.sessionContract.allowsNativeVideoOutput)
        #expect(host.videoFrameCaptureDebugSummary == "VIDTAP enabled=no requested=BGRA actual=pending")
    }

    @Test("a new session enables frame capture by default")
    func newSessionUsesDefaultCapturePolicy() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil, contract: .init(allowsVideoFrameCapture: false))
        host.load(url: url, startPosition: nil, contract: .init())

        let item = try #require(host.avPlayer.currentItem)
        #expect(host.sessionContract.allowsVideoFrameCapture)
        #expect(host.sessionContract.videoFrameCapturePixelFormat == kCVPixelFormatType_32BGRA)
        #expect(hasVideoFrameOutput(item))
        #expect(host.videoFrameCaptureDebugSummary == "VIDTAP enabled=yes requested=BGRA actual=pending")
    }

    @Test("x420 capture policy survives swaps and a new session resets to BGRA")
    func x420CapturePolicySurvivesSwapAndResets() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil,
                  contract: .init(videoFrameCapturePixelFormat: tenBitVideoRange))
        let firstItem = try #require(host.avPlayer.currentItem)
        #expect(hasVideoFrameOutput(firstItem))
        #expect(host.sessionContract.videoFrameCapturePixelFormat == tenBitVideoRange)

        host.swapItem(url: url, startPosition: nil)
        let swappedItem = try #require(host.avPlayer.currentItem)
        #expect(hasVideoFrameOutput(swappedItem))
        #expect(host.sessionContract.videoFrameCapturePixelFormat == tenBitVideoRange)

        host.load(url: url, startPosition: nil, contract: .init())
        let newSessionItem = try #require(host.avPlayer.currentItem)
        #expect(host.sessionContract.videoFrameCapturePixelFormat == kCVPixelFormatType_32BGRA)
        #expect(hasVideoFrameOutput(newSessionItem))
    }

    @Test("a transient displayed-frame output detaches on cancellation and item swap")
    func transientOutputDetachesOnCancellationAndSwap() async throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil, contract: .init(allowsVideoFrameCapture: false))
        let outgoingItem = try #require(host.avPlayer.currentItem)
        let cancelledCapture = Task {
            let frame = await host.captureDisplayedFrame(timeout: .seconds(10))
            return frame != nil
        }
        for _ in 0..<50 {
            if hasVideoFrameOutput(outgoingItem) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(hasVideoFrameOutput(outgoingItem))
        cancelledCapture.cancel()
        let cancelledCaptureProducedFrame = await cancelledCapture.value
        #expect(!cancelledCaptureProducedFrame)
        #expect(!hasVideoFrameOutput(outgoingItem))

        let swappedCapture = Task {
            let frame = await host.captureDisplayedFrame(timeout: .seconds(10))
            return frame != nil
        }
        for _ in 0..<50 {
            if hasVideoFrameOutput(outgoingItem) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(hasVideoFrameOutput(outgoingItem))
        host.swapItem(url: url, startPosition: nil)
        let swappedCaptureProducedFrame = await swappedCapture.value
        #expect(!swappedCaptureProducedFrame)
        #expect(!hasVideoFrameOutput(outgoingItem))
        let currentItem = try #require(host.avPlayer.currentItem)
        #expect(!hasVideoFrameOutput(currentItem))
    }

    @Test("protected session refuses transient capture without attaching output")
    func protectedSessionRefusesTransientCapture() async throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let url = URL(string: "http://127.0.0.1:1/capture-test.m3u8")!

        host.load(url: url, startPosition: nil, contract: .init(allowsNativeVideoOutput: false))
        let item = try #require(host.avPlayer.currentItem)
        let clock = ContinuousClock()
        let start = clock.now
        let frame = await host.captureDisplayedFrame(timeout: .seconds(10))
        let elapsed = start.duration(to: clock.now)

        #expect(frame == nil)
        #expect(elapsed < .seconds(1))
        #expect(!hasVideoFrameOutput(item))
    }

    @Test("PQ x420 and xf20 frames tone map with retained contrast")
    func tenBitHDRRangesRenderAsSDRThumbnails() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }

        for format in [tenBitVideoRange, tenBitFullRange] {
            let buffer = try makeTenBitHDRPatchBuffer(pixelFormat: format)
            let thumbnail = try #require(host.renderThumbnail(from: buffer, maxWidth: 12))
            #expect(thumbnail.width == 12)
            #expect(thumbnail.height == 4)
            #expect(thumbnail.bitsPerComponent == 8)
            #expect(thumbnail.bitsPerPixel == 32)
            #expect(thumbnail.colorSpace?.name == CGColorSpace.sRGB)

            let black = try rgbaPixel(thumbnail, x: 1, y: 2)
            let midtone = try rgbaPixel(thumbnail, x: 6, y: 2)
            let highlight = try rgbaPixel(thumbnail, x: 10, y: 2)
            #expect(black.luma < midtone.luma)
            #expect(midtone.luma < highlight.luma)
            #expect(highlight.luma - black.luma > 32, "tone mapping should preserve visible range contrast")
            #expect(midtone.red > 8 && midtone.red < 245)
            #expect(midtone.green > 8 && midtone.green < 245)
            #expect(midtone.blue > 8 && midtone.blue < 245)
        }
    }

    @Test("half-float PQ headroom maps to SDR without clipping highlight distinction",
          .enabled(if: Self.explicitToneMappingAvailable))
    func halfFloatPQFramesToneMapToSDR() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let buffer = try makeHalfFloatPQBuffer()
        var callbackHeadroom: String?
        let thumbnail = try #require(host.renderThumbnail(from: buffer, maxWidth: 10, sourceImageCreated: {
            callbackHeadroom = contentHeadroomDescription($0)
        }))
        let legacyThumbnail = try renderWithoutToneMapping(from: buffer, maxWidth: 10)

        #expect(thumbnail.width == 10)
        #expect(thumbnail.height == 2)
        #expect(thumbnail.bitsPerComponent == 8)
        #expect(thumbnail.bitsPerPixel == 32)
        #expect(thumbnail.colorSpace?.name == CGColorSpace.sRGB)
        let black = try rgbaPixel(thumbnail, x: 0, y: 1)
        let midtone = try rgbaPixel(thumbnail, x: 2, y: 1)
        let neutralMid = try rgbaPixel(thumbnail, x: 4, y: 1)
        let firstHighlight = try rgbaPixel(thumbnail, x: 6, y: 1)
        let secondHighlight = try rgbaPixel(thumbnail, x: 8, y: 1)
        #expect(black.luma < neutralMid.luma)
        #expect(neutralMid.luma < firstHighlight.luma)
        #expect(firstHighlight.luma < secondHighlight.luma)
        #expect(secondHighlight.luma - firstHighlight.luma > 8,
                "tone mapping should retain distinction between HDR highlights")
        #expect(midtone.red > midtone.green && midtone.green > midtone.blue,
                "the HDR color patch should retain distinct channels")
        #expect(midtone.red > 8 && midtone.red < 245)
        #expect(midtone.green > 8 && midtone.green < 245)
        #expect(midtone.blue > 8 && midtone.blue < 245)

        let legacyFirstHighlight = try rgbaPixel(legacyThumbnail, x: 6, y: 1)
        let legacySecondHighlight = try rgbaPixel(legacyThumbnail, x: 8, y: 1)
        let source = CIImage(cvPixelBuffer: buffer)
        let initializerOptionSource = CIImage(cvPixelBuffer: buffer, options: [.toneMapHDRtoSDR: true])
        if #available(tvOS 18, macOS 15, iOS 18, visionOS 2, *) {
            #expect(source.contentHeadroom.isFinite && source.contentHeadroom > 1)
            #expect(initializerOptionSource.contentHeadroom <= 1)
            #expect(callbackHeadroom == contentHeadroomDescription(source))
        }
        print("[HDR half-float fixture] pixelFormat=\(CVPixelBufferGetPixelFormatType(buffer)); rawRGBA16F patches=[[0,0,0],[0.56,0.52,0.48],[0.50,0.50,0.50],[0.65,0.65,0.65],[0.75,0.75,0.75]]; sourceColorSpace=\(String(describing: source.colorSpace?.name)); sourceHeadroom=\(contentHeadroomDescription(source)); initializerColorSpace=\(String(describing: initializerOptionSource.colorSpace?.name)); initializerHeadroom=\(contentHeadroomDescription(initializerOptionSource)); primaries=\(attachmentDescription(kCVImageBufferColorPrimariesKey, from: buffer)); transfer=\(attachmentDescription(kCVImageBufferTransferFunctionKey, from: buffer)); matrix=\(attachmentDescription(kCVImageBufferYCbCrMatrixKey, from: buffer)); attachedColorSpace=\(attachmentDescription(kCVImageBufferCGColorSpaceKey, from: buffer))")
        print("[HDR half-float render] explicit black/color/neutral50/neutral65/neutral75=\(pixelDescription([black, midtone, neutralMid, firstHighlight, secondHighlight])); legacy black/color/neutral50/neutral65/neutral75=\(pixelDescription([try rgbaPixel(legacyThumbnail, x: 0, y: 1), try rgbaPixel(legacyThumbnail, x: 2, y: 1), try rgbaPixel(legacyThumbnail, x: 4, y: 1), legacyFirstHighlight, legacySecondHighlight]))")
        #expect(legacyFirstHighlight.luma > firstHighlight.luma + 15)
        #expect(legacySecondHighlight.luma >= 250)
        #expect(secondHighlight.luma - firstHighlight.luma >
                    (legacySecondHighlight.luma - legacyFirstHighlight.luma) + 15,
                "explicit mapping should preserve more highlight separation; legacy \(legacyFirstHighlight.luma) -> \(legacySecondHighlight.luma), mapped \(firstHighlight.luma) -> \(secondHighlight.luma)")
    }

    @Test("SDR BGRA color patches remain close after sRGB rendering")
    func sdrBGRAColorPatchesRemainStable() throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        let buffer = try makeSDRColorPatchBuffer()
        let thumbnail = try #require(host.renderThumbnail(from: buffer, maxWidth: 12))

        #expect(thumbnail.width == 12)
        #expect(thumbnail.height == 8)
        #expect(thumbnail.bitsPerComponent == 8)
        #expect(thumbnail.bitsPerPixel == 32)
        #expect(thumbnail.colorSpace?.name == CGColorSpace.sRGB)
        let red = try rgbaPixel(thumbnail, x: 1, y: 4)
        let green = try rgbaPixel(thumbnail, x: 6, y: 4)
        let blue = try rgbaPixel(thumbnail, x: 10, y: 4)
        #expect(abs(red.red - 220) <= 20 && abs(red.green - 40) <= 20 && abs(red.blue - 20) <= 20)
        #expect(abs(green.red - 20) <= 20 && abs(green.green - 190) <= 20 && abs(green.blue - 30) <= 20)
        #expect(abs(blue.red - 30) <= 20 && abs(blue.green - 40) <= 20 && abs(blue.blue - 210) <= 20)
    }
}

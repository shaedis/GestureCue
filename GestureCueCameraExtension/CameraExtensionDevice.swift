import CoreGraphics
import CoreMediaIO
import CoreText
import Foundation
import os

/// Fixed virtual-camera format (v1): 720p BGRA at 30 fps. The host app
/// scales its composited feed to this size before sending.
enum VirtualCameraFormat {
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let frameRate: Int32 = 30
}

private let cameraExtensionLogger = Logger(subsystem: "com.gesturecue.app.cameraextension", category: "Device")

/// The virtual device: renders a slate while idle, forwards sink frames to
/// the source stream while the host app streams. Mutable state is either
/// set-once in `init` or guarded by `lock`.
final class CameraExtensionDevice: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var streamSource: CameraExtensionStreamSource!
    private var streamSink: CameraExtensionStreamSink!
    private var videoDescription: CMFormatDescription!
    private var bufferPool: CVPixelBufferPool!

    private let lock = NSLock()
    private var streamingCount: UInt32 = 0
    private var sinkStreamingCount: UInt32 = 0
    private var sinkStarted = false
    private var forwardedCount = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "GestureCueCamera.timer", qos: .userInteractive)

    init(localizedName: String) {
        super.init()
        // Stable IDs: Zoom and the host match the same device across restarts.
        let deviceID = UUID(uuidString: "3F9A4C2E-7B1D-4E8A-A5C6-9D2E4F6A8B0C")!
        device = CMIOExtensionDevice(
            localizedName: localizedName, deviceID: deviceID,
            legacyDeviceID: "3F9A4C2E-7B1D-4E8A-A5C6-9D2E4F6A8B0C", source: self
        )
        var videoDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: VirtualCameraFormat.width, height: VirtualCameraFormat.height,
            extensions: nil, formatDescriptionOut: &videoDescription
        )
        guard let videoDescription else { fatalError("Failed to create format description") }
        self.videoDescription = videoDescription
        let poolAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: VirtualCameraFormat.width,
            kCVPixelBufferHeightKey: VirtualCameraFormat.height,
            kCVPixelBufferPixelFormatTypeKey: videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttributes, &pool)
        guard let pool else { fatalError("Failed to create buffer pool") }
        bufferPool = pool
        let frameDuration = CMTime(value: 1, timescale: VirtualCameraFormat.frameRate)
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDescription, maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration, validFrameDurations: nil
        )
        streamSource = CameraExtensionStreamSource(
            localizedName: "GestureCueCamera.Video", streamID: UUID(uuidString: "8B4D2E9A-3F7C-4A1E-B6D5-2C8E4F6A0B1D")!,
            streamFormat: streamFormat, device: device
        )
        streamSink = CameraExtensionStreamSink(
            localizedName: "GestureCueCamera.Video.Sink", streamID: UUID(uuidString: "5C7E1F3A-9D2B-4C8E-A1F4-6B3D5E7C9A0F")!,
            streamFormat: streamFormat, device: device
        )
        do {
            try device.addStream(streamSource.stream)
            try device.addStream(streamSink.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt' = kIOAudioDeviceTransportTypeVirtual (IOKit/audio/IOAudioTypes.h, stable ABI).
            deviceProperties.transportType = 0x76697274
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "GestureCue Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        cameraExtensionLogger.info("source stream start requested")
        lock.withLock {
            streamingCount += 1
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now(), repeating: 1 / Double(VirtualCameraFormat.frameRate))
            timer.setEventHandler { [weak self] in self?.renderSlateFrame() }
            self.timer = timer
            timer.resume()
        }
    }

    func stopStreaming() {
        lock.withLock {
            if streamingCount > 0 { streamingCount -= 1 }
            if streamingCount == 0 {
                timer?.cancel()
                timer = nil
            }
        }
    }

    func startStreamingSink(client: CMIOExtensionClient) {
        cameraExtensionLogger.info("sink stream start requested")
        lock.withLock {
            sinkStreamingCount += 1
            sinkStarted = true
        }
        consumeBuffer(client)
    }

    func stopStreamingSink() {
        lock.withLock {
            sinkStarted = false
            if sinkStreamingCount > 0 { sinkStreamingCount -= 1 }
        }
    }

    private func renderSlateFrame() {
        let sinkLive = lock.withLock { sinkStarted }
        guard !sinkLive else { return }
        var pixelBuffer: CVPixelBuffer?
        let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5] as NSDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, bufferPool, auxAttributes, &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return }
        drawSlate(into: pixelBuffer)
        send(pixelBuffer)
    }

    private func send(_ pixelBuffer: CVPixelBuffer) {
        var timing = CMSampleTimingInfo()
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: videoDescription,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        let streaming = lock.withLock { streamingCount > 0 }
        guard streaming else { return }
        streamSource.stream.send(
            sample, discontinuity: [],
            hostTimeInNanoseconds: UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        )
    }

    private func consumeBuffer(_ client: CMIOExtensionClient) {
        let live = lock.withLock { sinkStarted }
        guard live else { return }
        streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sample, sequence, _, _, _ in
            guard let self else { return }
            if let sample {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequence,
                    hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC))
                )
                let streaming = self.lock.withLock { self.streamingCount > 0 }
                if streaming {
                    self.streamSource.stream.send(
                        sample, discontinuity: [],
                        hostTimeInNanoseconds: UInt64(sample.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
                    )
                    let count = self.lock.withLock {
                        self.forwardedCount += 1
                        return self.forwardedCount
                    }
                    if count == 1 {
                        cameraExtensionLogger.info("first host frame forwarded to source stream")
                    } else if count % 300 == 0 {
                        cameraExtensionLogger.debug("forwarded \(count) host frames")
                    }
                }
                self.streamSink.stream.notifyScheduledOutputChanged(output)
            }
            self.consumeBuffer(client)
        }
    }

    private func drawSlate(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return }
        ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawCenteredText(ctx: ctx, text: "GestureCue Camera", fontSize: 72, yFromTop: CGFloat(height) / 2 - 20, width: width, height: height)
        drawCenteredText(ctx: ctx, text: "Enable the virtual camera in GestureCue", fontSize: 30, yFromTop: CGFloat(height) / 2 + 70, width: width, height: height)
    }

    private func drawCenteredText(ctx: CGContext, text: String, fontSize: CGFloat, yFromTop: CGFloat, width: Int, height: Int) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        // Raw CoreText keys: NSAttributedString.Key.font/.foregroundColor are AppKit-only.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Default (non-flipped) context: textPosition is the baseline origin,
        // glyphs extend upward. yFromTop counts from the top edge.
        ctx.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: CGFloat(height) - yFromTop)
        CTLineDraw(line, ctx)
    }
}

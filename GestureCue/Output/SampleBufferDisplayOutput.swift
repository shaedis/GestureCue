import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// In-app program monitor: a `VideoOutputService` displaying the composited
/// feed on an `AVSampleBufferDisplayLayer`. Proves the composite→output path
/// end to end; a future `VirtualCameraService` replaces this destination.
final class SampleBufferDisplayOutput: VideoOutputService, @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer

    private let lock = NSLock()
    private var running = false
    private var formatDescription: CMVideoFormatDescription?
    private var formatSize: (width: Int32, height: Int32)?

    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    func start() {
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock { running = false }
        layer.flush()
    }

    func publish(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        lock.lock()
        guard running else { lock.unlock(); return }
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if formatDescription == nil || formatSize?.width != width || formatSize?.height != height {
            var fresh: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fresh
            ) == noErr, let fresh else { lock.unlock(); return }
            formatDescription = fresh
            formatSize = (width, height)
        }
        guard let formatDescription else { lock.unlock(); return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: presentationTimeStamp, decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer,
            formatDescription: formatDescription, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        lock.unlock()

        guard status == noErr, let sampleBuffer else { return }
        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }
}

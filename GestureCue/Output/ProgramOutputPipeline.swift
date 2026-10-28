import CoreMedia
import CoreVideo
import Foundation

/// Program-output branch of the shared pipeline: a `VideoFrameConsumer` that
/// runs every camera frame through the `VideoCompositor` and hands the result
/// to its `VideoOutputService`. Can be disabled without disturbing capture or
/// gesture detection.
final class ProgramOutputPipeline: VideoFrameConsumer, @unchecked Sendable {
    private let compositor: any VideoCompositor
    private let output: any VideoOutputService
    private let lock = NSLock()
    private var enabled: Bool
    private var recorder: VideoRecorder?

    init(compositor: any VideoCompositor, output: any VideoOutputService, enabled: Bool = true) {
        self.compositor = compositor
        self.output = output
        self.enabled = enabled
        if enabled {
            output.start()
        }
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
        if enabled {
            output.start()
        } else {
            output.stop()
        }
    }

    /// Permanent tap: the recorder drops frames while idle, so attaching
    /// once costs one nil check per frame and needs no detach races.
    func setRecorder(_ recorder: VideoRecorder?) {
        lock.withLock { self.recorder = recorder }
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        guard isEnabled else { return }
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let composited = compositor.composite(cameraFrame: source, presentationTimeStamp: timestamp) else { return }
        output.publish(composited, presentationTimeStamp: timestamp)
        if let recorder = lock.withLock({ recorder }) {
            recorder.append(composited, presentationTimeStamp: timestamp)
        }
    }
}

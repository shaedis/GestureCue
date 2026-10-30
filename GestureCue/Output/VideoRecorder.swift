import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum RecorderError: Error, Sendable {
    case alreadyRecording
}

/// An AVAssetWriter handed to exactly one `finishWriting` completion:
/// after handoff nothing else touches that instance (the recorder's own
/// slot is already nil), so the Sendable hole is safe by construction.
private struct FinishingWriter: @unchecked Sendable {
    let writer: AVAssetWriter
}

/// Records composited program frames to a video-only MP4 (no audio: the
/// app never touches the mic). Fed from the video queue; appends are
/// serialized on an internal queue and lock-guarded against `stop` from
/// any thread. The first frame fixes the encoding size; later frames of a
/// different size are dropped and counted. `onFinish` fires exactly once
/// per recording, on an arbitrary queue.
final class VideoRecorder: @unchecked Sendable {
    enum FinishResult: Sendable {
        case saved(URL, droppedFrames: Int)
        /// Stopped before any frame arrived (nothing written).
        case cancelled
        case failed(String)
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "GestureCue.VideoRecorder")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var url: URL?
    private var frameSize: (Int, Int)?
    private var frameCount = 0
    private var droppedCount = 0
    private var sessionStarted = false
    private var finishing = false
    var onFinish: ((FinishResult) -> Void)?

    var isRecording: Bool {
        lock.withLock { writer != nil && !finishing }
    }

    func start(url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil else { throw RecorderError.alreadyRecording }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        self.writer = writer
        self.url = url
        frameSize = nil
        frameCount = 0
        droppedCount = 0
        sessionStarted = false
        finishing = false
    }

    /// Ends recording; the result arrives via `onFinish`. No-op when idle.
    func stop() {
        lock.lock()
        guard writer != nil, !finishing else { lock.unlock(); return }
        finishing = true
        lock.unlock()
        // Serial queue: runs after all previously appended frames.
        queue.async { [weak self] in self?.finishOnQueue() }
    }

    /// Synchronous so callers know the frame was accepted or counted before
    /// `stop` can cut the tail (async appends raced `stop` and vanished).
    /// Fast: only queues into the encoder; never call from `onFinish`.
    func append(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp ts: CMTime) {
        queue.sync { [weak self] in self?.appendOnQueue(pixelBuffer, presentationTimeStamp: ts) }
    }

    // MARK: - Private (serial queue)

    private func appendOnQueue(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp ts: CMTime) {
        lock.lock()
        guard let writer, !finishing else { lock.unlock(); return }
        guard ts.isValid else { droppedCount += 1; lock.unlock(); return }
        if writer.status == .failed {
            abortLocked(writer: writer, url: url)
            return
        }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        if frameSize == nil {
            guard configureLocked(writer: writer, width: w, height: h) else {
                abortLocked(writer: writer, url: url)
                return
            }
            frameSize = (w, h)
        } else if frameSize?.0 != w || frameSize?.1 != h {
            droppedCount += 1
            lock.unlock()
            return
        }
        guard let input, let adaptor else { lock.unlock(); return }
        if !sessionStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: ts)
            sessionStarted = true
            if writer.status == .failed {
                abortLocked(writer: writer, url: url)
                return
            }
        }
        guard input.isReadyForMoreMediaData else { droppedCount += 1; lock.unlock(); return }
        if adaptor.append(pixelBuffer, withPresentationTime: ts) {
            frameCount += 1
        } else {
            droppedCount += 1
        }
        lock.unlock()
    }

    /// Creates the H.264 input for the first frame's size. Lock held.
    private func configureLocked(writer: AVAssetWriter, width: Int, height: Int) -> Bool {
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 8],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        return true
    }

    /// Abandons a failed recording. Lock held; reports off-lock.
    private func abortLocked(writer: AVAssetWriter, url: URL?) {
        let result = FinishResult.failed(writer.error?.localizedDescription ?? "unknown encoding error")
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        cleanupLocked()
        lock.unlock()
        finish(result)
    }

    private func finishOnQueue() {
        lock.lock()
        guard let writer, let url else { lock.unlock(); return }
        let frames = frameCount
        let dropped = droppedCount
        if frames == 0 || input == nil {
            cleanupLocked()
            lock.unlock()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            finish(.cancelled)
            return
        }
        input?.markAsFinished()
        cleanupLocked()
        lock.unlock()
        let pending = FinishingWriter(writer: writer)
        writer.finishWriting { [weak self] in
            guard let self else { return }
            if pending.writer.status == .completed {
                self.finish(.saved(url, droppedFrames: dropped))
            } else {
                try? FileManager.default.removeItem(at: url)
                self.finish(.failed(pending.writer.error?.localizedDescription ?? "unknown encoding error"))
            }
        }
    }

    /// Resets for the next recording. Lock held.
    private func cleanupLocked() {
        writer = nil
        input = nil
        adaptor = nil
        url = nil
        frameSize = nil
        frameCount = 0
        droppedCount = 0
        sessionStarted = false
        finishing = false
    }

    private func finish(_ result: FinishResult) {
        let handler = lock.withLock { onFinish }
        handler?(result)
    }
}

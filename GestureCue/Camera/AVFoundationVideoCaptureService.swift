import AVFoundation
import CoreMedia
import Foundation

/// `VideoCaptureService` built on AVFoundation. Selectable 720p/1080p capture
/// fanning every frame out to its consumers (gesture detection, program output)
/// on a dedicated video queue. All session state is confined to `sessionQueue`;
/// the class is `@unchecked Sendable` by that discipline plus immutable members.
final class AVFoundationVideoCaptureService: NSObject, VideoCaptureService, @unchecked Sendable {
    let session = AVCaptureSession()
    let events: AsyncStream<CaptureEvent>

    private let consumers: [any VideoFrameConsumer]
    private let eventsContinuation: AsyncStream<CaptureEvent>.Continuation
    private let sessionQueue = DispatchQueue(label: "com.gesturecue.capture.session")
    private let videoQueue = DispatchQueue(label: "com.gesturecue.capture.video", qos: .userInitiated)
    private let sink: VideoSink

    // MARK: - sessionQueue-confined state
    private var videoOutput: AVCaptureVideoDataOutput?
    private var pendingDeviceID: String?
    private var resolution: CaptureResolution = .hd720
    private var isConfigured = false
    private var notificationObservers: [NSObjectProtocol] = []

    init(consumers: [any VideoFrameConsumer]) {
        self.consumers = consumers
        (events, eventsContinuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        sink = VideoSink(consumers: consumers)
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start(deviceID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pendingDeviceID = deviceID
            do {
                let mirrored = try self.configureLocked()
                self.observeSessionLocked()
                self.session.startRunning()
                self.eventsContinuation.yield(.started(isPreviewMirrored: mirrored))
            } catch {
                self.eventsContinuation.yield(.failed(message: error.localizedDescription))
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.teardownLocked()
            self.eventsContinuation.yield(.stopped)
        }
    }

    func selectDevice(deviceID: String?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pendingDeviceID = deviceID
            guard self.isConfigured else { return } // Takes effect on next start().
            do {
                let mirrored = try self.configureLocked()
                self.eventsContinuation.yield(.started(isPreviewMirrored: mirrored))
            } catch {
                self.eventsContinuation.yield(.failed(message: error.localizedDescription))
            }
        }
    }

    func selectResolution(_ resolution: CaptureResolution) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.resolution = resolution
            guard self.isConfigured else { return } // Takes effect on next start().
            do {
                let mirrored = try self.configureLocked()
                self.eventsContinuation.yield(.started(isPreviewMirrored: mirrored))
            } catch {
                self.eventsContinuation.yield(.failed(message: error.localizedDescription))
            }
        }
    }

    // MARK: - Configuration (sessionQueue only)

    @discardableResult
    private func configureLocked() throws -> Bool {
        assertQueue()
        let device = resolveDeviceLocked()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let preset = resolution.sessionPreset
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        for input in session.inputs {
            session.removeInput(input)
        }
        guard let device else {
            throw CaptureError.noCamera("No camera is available. Connect a camera and try again.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CaptureError.noCamera("The selected camera could not be used.")
        }
        session.addInput(input)

        if videoOutput == nil {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(sink, queue: videoQueue)
            guard session.canAddOutput(output) else {
                throw CaptureError.noCamera("Camera frames could not be configured.")
            }
            session.addOutput(output)
            videoOutput = output
        }

        isConfigured = true
        // Front cameras are preview-mirrored by default; the overlay must match.
        return device.position == .front
    }

    private func teardownLocked() {
        assertQueue()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        videoOutput = nil
        isConfigured = false
    }

    private func resolveDeviceLocked() -> AVCaptureDevice? {
        assertQueue()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        if let pendingDeviceID, let match = discovery.devices.first(where: { $0.uniqueID == pendingDeviceID }) {
            return match
        }
        return discovery.devices.first
    }

    private func observeSessionLocked() {
        assertQueue()
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
                guard let self else { return }
                let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                    ?? "The camera stopped unexpectedly."
                self.sessionQueue.async { self.eventsContinuation.yield(.failed(message: message)) }
            },
            center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.eventsContinuation.yield(.interrupted(message: "Camera was interrupted.")) }
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.eventsContinuation.yield(.interruptionEnded) }
            },
        ]
    }

    private func assertQueue() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
    }
}

enum CaptureError: LocalizedError {
    case noCamera(String)

    var errorDescription: String? {
        if case let .noCamera(message) = self { return message }
        return nil
    }
}

/// Forwards frames to every consumer on the video queue. Stateless apart from
/// the immutable consumer list, so genuinely safe to share across threads.
private final class VideoSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let consumers: [any VideoFrameConsumer]

    init(consumers: [any VideoFrameConsumer]) {
        self.consumers = consumers
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        for consumer in consumers {
            consumer.consume(sampleBuffer)
        }
    }
}

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Lifecycle events from the shared camera capture pipeline.
enum CaptureEvent: Sendable, Equatable {
    case started(isPreviewMirrored: Bool)
    case stopped
    case failed(message: String)
    case interrupted(message: String)
    case interruptionEnded
}

/// Receives camera frames on the video queue. Consumers must be fast and
/// non-blocking; use `alwaysDiscardsLateVideoFrames` semantics downstream by
/// dropping work (not queueing) when busy.
protocol VideoFrameConsumer: Sendable {
    func consume(_ sampleBuffer: CMSampleBuffer)
}

/// The single shared camera capture pipeline feeding gesture recognition and
/// video output. Implementations own an `AVCaptureSession`, fan frames out to
/// consumers on a background video queue, and report lifecycle via `events`.
protocol VideoCaptureService: Sendable {
    /// Session driving the raw camera preview layer (zero-copy; not the program feed).
    var session: AVCaptureSession { get }
    var events: AsyncStream<CaptureEvent> { get }
    /// Starts capture on `deviceID` (or the default camera when nil).
    func start(deviceID: String?)
    /// Stops capture and releases camera resources.
    func stop()
    /// Switches input device; takes effect immediately, even mid-capture.
    func selectDevice(deviceID: String?)
    /// Switches capture resolution; takes effect immediately, even mid-capture.
    func selectResolution(_ resolution: CaptureResolution)
}

/// Capture/output resolution. 1080p is the default: on high-resolution
/// sensors (e.g. Center Stage cameras) it uses a wider window than 720p,
/// which keeps signing hands in frame, and downscales cleanly to the
/// 720p virtual camera. The compositor follows frame size, and gesture
/// geometry is resolution-independent, so no consumer reconfigures.
enum CaptureResolution: String, CaseIterable, Sendable {
    case hd720
    case hd1080

    static let defaultResolution: CaptureResolution = .hd1080

    var displayName: String {
        switch self {
        case .hd720: "720p"
        case .hd1080: "1080p"
        }
    }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .hd720: .hd1280x720
        case .hd1080: .hd1920x1080
        }
    }

    /// Nominal frame size (both presets are 16:9; the mouse-brush
    /// mapping only depends on the aspect).
    var pixelSize: CGSize {
        switch self {
        case .hd720: CGSize(width: 1280, height: 720)
        case .hd1080: CGSize(width: 1920, height: 1080)
        }
    }
}

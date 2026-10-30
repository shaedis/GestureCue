import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// In-video card placement. Seed of the Phase 2 layout model: fixed
/// position presets only, no drag/resize yet.
enum CardOverlayPosition: String, CaseIterable, Codable, Sendable, Hashable {
    case bottom
    case left
    case right
    /// Video + Card: the whole camera frame aspect-fit into its own tile
    /// beside the card panel — nothing is ever covered.
    case sideBySide

    var displayName: String {
        switch self {
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        case .sideBySide: "Video + Card"
        }
    }
}

/// Card panel placement inside Video + Card mode: the video tile takes
/// the opposite side (top half for a bottom panel). Only `.sideBySide`
/// reads it; other positions ignore it.
enum CardPanelPosition: String, CaseIterable, Codable, Sendable, Hashable {
    case left
    case right
    case bottom

    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .bottom: "Bottom"
        }
    }
}

/// Finger-paint marker color. Shared by paint strokes, the paint pointer,
/// and the color picker; matches the future Phase 3 annotation colors.
enum HighlightColor: String, CaseIterable, Codable, Sendable, Hashable {
    case yellow
    case red

    var displayName: String {
        switch self {
        case .yellow: "Yellow"
        case .red: "Red"
        }
    }

    var markerColor: CGColor {
        switch self {
        case .yellow: CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)
        case .red: CGColor(red: 1, green: 0.3, blue: 0.25, alpha: 1)
        }
    }
}

/// Program-output mirroring: follow the camera (front cameras mirror like
/// the preview) or force one presentation for the outgoing feed.
enum OutputMirrorMode: String, CaseIterable, Sendable {
    case auto
    case mirrored
    case original

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .mirrored: "Mirrored"
        case .original: "Original"
        }
    }

    static func resolve(mode: OutputMirrorMode, cameraMirrored: Bool) -> Bool {
        switch mode {
        case .auto: cameraMirrored
        case .mirrored: true
        case .original: false
        }
    }
}

/// Card content the compositor burns into the program feed.
struct ProgramOverlay: Sendable, Equatable {
    var card: PresentationCard?
    var isVisible: Bool
    var position: CardOverlayPosition = .bottom
    /// Card panel placement in Video + Card mode (ignored otherwise).
    /// Default right = video left, the original Video + Card layout.
    var cardPanel: CardPanelPosition = .right
    /// Fullscreen card; collapsing restores `position`.
    var isExpanded: Bool = false
    /// Picture zoom (1.0 = aspect-fit, up to 4× centered on the picture box).
    var zoomScale: CGFloat = 1.0
    /// Idle seconds left before listening ends (nil = signing/paused).
    /// Burned into the feed as a corner dot so the presenter sees
    /// listening state in the output window: green, amber in the last
    /// minute.
    var commandWindowRemaining: TimeInterval? = nil
    /// 1-based position of the shown card in its deck (nil = unknown):
    /// burned into the feed as an "N/M" corner badge so the presenter
    /// sees where they are.
    var cardNumber: Int? = nil
    var cardCount: Int = 0
}

/// Freehand stroke in normalized video coordinates (origin lower-left).
struct PaintStroke: Sendable, Equatable {
    var color: HighlightColor
    var points: [CGPoint]
}

/// Two-finger brush stroke: drawn while the fingers move, then fades away
/// instead of persisting. The fade clock starts at `endedAt` (nil while
/// still drawing); each stroke carries its own duration so the compositor
/// needs no shared clock.
struct BrushStroke: Sendable, Equatable {
    var stroke: PaintStroke
    var endedAt: Date? = nil
    var fadeDuration: TimeInterval = 1.5
}

/// Paint layer composited over the card: committed + active strokes plus the
/// live fingertip pointer. Coordinates are normalized video space.
struct PaintLayer: Sendable, Equatable {
    var strokes: [PaintStroke] = []
    var brushStrokes: [BrushStroke] = []
    var pointer: CGPoint? = nil
    var pointerColor: HighlightColor = .yellow
}

/// Renders camera frames plus overlays (cards now; images and prerecorded clips
/// later) into reusable pixel buffers. Runs on the video queue; `updateOverlay`
/// may be called from any thread.
protocol VideoCompositor: Sendable {
    func updateOverlay(_ overlay: ProgramOverlay)
    func updatePaint(_ layer: PaintLayer)
    /// Matches a mirrored front-camera preview: the camera frame (and paint
    /// coordinates) flip horizontally; card layout stays in screen space.
    func setMirrored(_ mirrored: Bool)
    func composite(cameraFrame: CVPixelBuffer, presentationTimeStamp: CMTime) -> CVPixelBuffer?
}

/// A destination for composited program frames, isolated behind a protocol so
/// outputs stay interchangeable. Milestone 1 ships the in-app program monitor
/// (`SampleBufferDisplayOutput`); a future `VirtualCameraService` (CoreMediaIO
/// camera extension feeding Zoom/Teams) plugs into this same seam.
protocol VideoOutputService: Sendable {
    var isRunning: Bool { get }
    func start()
    func stop()
    func publish(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime)
}

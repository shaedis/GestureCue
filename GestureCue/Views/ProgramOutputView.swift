import AppKit
import AVFoundation
import SwiftUI

/// Mouse-brush gesture on the program monitor: press-drag-release draws a
/// fading brush stroke, the mouse alternative to the two-finger brush.
/// Points are normalized paint coordinates (origin lower-left).
enum MouseBrushEvent {
    case down(CGPoint)
    case moved(CGPoint)
    case up
}

/// Hosts the program monitor's `AVSampleBufferDisplayLayer`: the composited
/// camera-plus-overlay feed that a future virtual camera will send to Zoom/Teams.
/// Press-dragging the mouse paints fading brush strokes under the cursor.
struct ProgramOutputView: NSViewRepresentable {
    var layer: AVSampleBufferDisplayLayer
    var videoSize: CGSize
    var mirrored: Bool
    var onBrush: ((MouseBrushEvent) -> Void)?

    func makeNSView(context _: Context) -> MouseBrushMonitorView {
        let view = MouseBrushMonitorView()
        view.wantsLayer = true
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: MouseBrushMonitorView, context _: Context) {
        nsView.videoSize = videoSize
        nsView.mirrored = mirrored
        nsView.onBrush = onBrush
    }
}

/// Layer-hosting monitor view with press-drag-release brush tracking and a
/// crosshair cursor. Mouse coordinates map through the same aspect-fill the
/// display layer uses, so strokes land exactly under the cursor.
final class MouseBrushMonitorView: NSView {
    var videoSize = CGSize(width: 1280, height: 720)
    var mirrored = false
    var onBrush: ((MouseBrushEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBrush?(.down(Self.normalizedPaintPoint(
            viewPoint: convert(event.locationInWindow, from: nil),
            viewSize: bounds.size, videoSize: videoSize, mirrored: mirrored
        )))
    }

    override func mouseDragged(with event: NSEvent) {
        onBrush?(.moved(Self.normalizedPaintPoint(
            viewPoint: convert(event.locationInWindow, from: nil),
            viewSize: bounds.size, videoSize: videoSize, mirrored: mirrored
        )))
    }

    override func mouseUp(with _: NSEvent) {
        onBrush?(.up)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    /// Maps an AppKit view point (origin lower-left) to normalized paint
    /// coordinates through aspect-fill geometry (`.resizeAspectFill` crops
    /// the long dimension; drags outside the view clamp onto the frame).
    /// Pure for testing.
    static func normalizedPaintPoint(
        viewPoint: CGPoint, viewSize: CGSize, videoSize: CGSize, mirrored: Bool
    ) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, videoSize.width > 0, videoSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let scale = max(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let shownWidth = videoSize.width * scale
        let shownHeight = videoSize.height * scale
        let cropX = (shownWidth - viewSize.width) / 2
        let cropY = (shownHeight - viewSize.height) / 2
        let xDown = viewPoint.x
        let yDown = viewSize.height - viewPoint.y
        let fx = min(1, max(0, (xDown + cropX) / shownWidth))
        let fy = min(1, max(0, (yDown + cropY) / shownHeight))
        return CGPoint(x: mirrored ? 1 - fx : fx, y: 1 - fy)
    }
}

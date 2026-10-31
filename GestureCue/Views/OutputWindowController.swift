import AppKit
import AVFoundation

/// Chromeless fullscreen capture window: borderless, video-only, titled
/// for OBS's window list. Draggable by its background (there is no title
/// bar to grab); shown and hidden exclusively through Open/Close Window
/// so the output branch and the window can never desync.
@MainActor
final class OutputWindowController {
    /// OBS window-capture lists this title; keep it stable.
    static let windowTitle = "GestureCue Output"
    static let contentSize = NSSize(width: 1280, height: 720)

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the capture window (created on first use) displaying `layer`.
    func show(layer: AVSampleBufferDisplayLayer) {
        if let window {
            window.orderFrontRegardless()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle
        window.backgroundColor = .black
        window.isMovable = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        let content = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        content.wantsLayer = true
        content.layer = layer
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        window.center()
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
    }
}

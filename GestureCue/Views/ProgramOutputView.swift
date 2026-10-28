import AVFoundation
import SwiftUI

/// Hosts the program monitor's `AVSampleBufferDisplayLayer`: the composited
/// camera-plus-overlay feed that a future virtual camera will send to Zoom/Teams.
struct ProgramOutputView: NSViewRepresentable {
    var layer: AVSampleBufferDisplayLayer

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

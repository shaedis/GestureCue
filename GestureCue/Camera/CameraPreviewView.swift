import AVFoundation
import SwiftUI

/// Live raw-camera preview. This is the zero-copy capture preview, not the
/// composited program feed (see `ProgramOutputView`).
struct CameraPreviewView: NSViewRepresentable {
    var session: AVCaptureSession

    func makeNSView(context _: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: PreviewNSView, context _: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }

    final class PreviewNSView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }

        override func makeBackingLayer() -> CALayer {
            AVCaptureVideoPreviewLayer()
        }
    }
}

import SwiftUI

/// Draws detected hand landmarks over the camera preview. Points arrive in
/// normalized Vision coordinates (origin lower-left) and are flipped to view
/// space, mirroring horizontally when the preview is mirrored.
struct LandmarkOverlayView: View {
    var points: [CGPoint]
    var mirrored: Bool

    var body: some View {
        Canvas { context, size in
            for point in points {
                let x = (mirrored ? 1 - point.x : point.x) * size.width
                let y = (1 - point.y) * size.height
                let radius: CGFloat = 4
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.green))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

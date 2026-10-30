import CoreGraphics
import Foundation

/// Shape recognized in a finished two-finger brush stroke, in normalized
/// video coordinates: a snapped axis-aligned line or a clean ellipse.
/// Diagonals, scribbles, and dots stay freehand (nil).
enum BrushShape: Sendable, Equatable {
    case line(from: CGPoint, to: CGPoint)
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat)
}

/// Recognizes horizontal/vertical lines and closed loops in finished
/// brush strokes so the brush draws clean shapes instead of wobble.
/// Geometry runs in aspect-uniform space (x scaled by the frame aspect:
/// a screen circle is an ellipse in normalized coordinates), with all
/// thresholds as resolution-independent ratios. Pure for testing.
struct BrushShapeClassifier: Sendable {
    struct Config: Sendable, Equatable {
        /// Frame width / height (16:9 pipeline).
        var frameAspect: CGFloat = 16 / 9
        /// Shortest classifiable stroke, uniform units.
        var minLength: CGFloat = 0.06
        /// First-to-last gap below this fraction of the bbox diagonal
        /// counts as closed. Generous: fingertip smoothing lags the true
        /// tip, so real loops end with a visible gap (~0.25 in practice);
        /// open C-shapes sit near 0.5 and still fail.
        var closureFraction: CGFloat = 0.30
        /// Smallest loop bbox side, uniform units (kills out-and-back
        /// retraces, which have one thin dimension).
        var minLoopSpan: CGFloat = 0.05
        /// Max perpendicular wobble as a fraction of chord length.
        var straightTolerance: CGFloat = 0.07
        /// Axis snap: |minor| / |major| below tan(~15°).
        var snapTangent: CGFloat = 0.27
    }

    /// Classifies finished stroke points, or nil when the stroke stays
    /// freehand. Needs 2+ points for lines, 8+ for loops.
    static func classify(_ points: [CGPoint], config: Config = Config()) -> BrushShape? {
        guard points.count >= 2 else { return nil }
        let uniform = points.map { CGPoint(x: $0.x * config.frameAspect, y: $0.y) }
        let xs = uniform.map(\.x), ys = uniform.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let spanX = maxX - minX, spanY = maxY - minY
        let diagonal = hypot(spanX, spanY)
        guard diagonal >= config.minLength else { return nil }
        if points.count >= 8, let loop = fitLoop(uniform: uniform, spanX: spanX, spanY: spanY, diagonal: diagonal, config: config) {
            return loop
        }
        return fitAxisLine(points: points, uniform: uniform, config: config)
    }

    /// Samples a shape back into stroke points: lines become their two
    /// endpoints, ellipses 48 perimeter points. The compositor needs no
    /// shape support — snapped strokes render (and fade) as ordinary
    /// point strokes.
    static func sampledPoints(for shape: BrushShape) -> [CGPoint] {
        switch shape {
        case let .line(from, to):
            return [from, to]
        case let .ellipse(center, rx, ry):
            return (0 ..< 48).map { index in
                let angle = CGFloat(index) * 2 * CGFloat.pi / 48
                return CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
            }
        }
    }

    // MARK: - Private

    private static func fitLoop(uniform: [CGPoint], spanX: CGFloat, spanY: CGFloat, diagonal: CGFloat, config: Config) -> BrushShape? {
        guard let first = uniform.first, let last = uniform.last else { return nil }
        let gap = hypot(last.x - first.x, last.y - first.y)
        guard gap < diagonal * config.closureFraction,
              spanX >= config.minLoopSpan, spanY >= config.minLoopSpan
        else { return nil }
        // A loop travels far for its span; short paths are hooks, not loops.
        var length: CGFloat = 0
        for index in uniform.indices.dropFirst() {
            length += hypot(uniform[index].x - uniform[index - 1].x, uniform[index].y - uniform[index - 1].y)
        }
        guard length > diagonal else { return nil }
        let minX = uniform.map(\.x).min() ?? 0
        let minY = uniform.map(\.y).min() ?? 0
        return .ellipse(
            center: CGPoint(x: (minX + spanX / 2) / config.frameAspect, y: minY + spanY / 2),
            rx: spanX / 2 / config.frameAspect,
            ry: spanY / 2
        )
    }

    private static func fitAxisLine(points: [CGPoint], uniform: [CGPoint], config: Config) -> BrushShape? {
        guard let first = uniform.first, let last = uniform.last else { return nil }
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard chord >= config.minLength else { return nil }
        // Max perpendicular deviation from the first-to-last chord.
        var worst: CGFloat = 0
        for point in uniform {
            let t = ((point.x - first.x) * (last.x - first.x) + (point.y - first.y) * (last.y - first.y)) / (chord * chord)
            let projection = CGPoint(x: first.x + t * (last.x - first.x), y: first.y + t * (last.y - first.y))
            worst = max(worst, hypot(point.x - projection.x, point.y - projection.y))
        }
        guard worst < chord * config.straightTolerance else { return nil }
        let dx = abs(last.x - first.x), dy = abs(last.y - first.y)
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        if dy < dx * config.snapTangent {
            let midY = ys.reduce(0, +) / CGFloat(ys.count)
            return .line(from: CGPoint(x: minX, y: midY), to: CGPoint(x: maxX, y: midY))
        }
        if dx < dy * config.snapTangent {
            let midX = xs.reduce(0, +) / CGFloat(xs.count)
            return .line(from: CGPoint(x: midX, y: minY), to: CGPoint(x: midX, y: maxY))
        }
        return nil
    }
}

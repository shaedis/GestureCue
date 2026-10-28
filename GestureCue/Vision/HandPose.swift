import CoreGraphics
import Foundation

/// The 21 hand joints tracked by Apple Vision, in normalized image coordinates
/// (origin lower-left, 0...1). Named after `VNHumanHandPoseObservation.JointName`
/// (`little*` is exposed here as `pinky*`).
enum Joint: String, CaseIterable, Sendable, Hashable, Codable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case pinkyMCP, pinkyPIP, pinkyDIP, pinkyTip
}

/// A single detected hand: normalized landmark positions plus per-joint confidence.
/// Pure value type with no Vision dependency so classification is unit-testable.
struct HandPose: Sendable, Equatable {
    /// Normalized landmark positions. Joints Vision did not recognize are absent.
    var points: [Joint: SIMD2<Float>]
    /// Per-joint recognition confidence (0...1). Absent joints read as 0.
    var confidences: [Joint: Float]

    init(points: [Joint: SIMD2<Float>] = [:], confidences: [Joint: Float] = [:]) {
        self.points = points
        self.confidences = confidences
    }

    func point(_ joint: Joint) -> SIMD2<Float>? {
        points[joint]
    }

    func confidence(_ joint: Joint) -> Float {
        confidences[joint, default: 0]
    }
}

/// Euclidean distance in normalized-coordinate space.
func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    hypot(a.x - b.x, a.y - b.y)
}

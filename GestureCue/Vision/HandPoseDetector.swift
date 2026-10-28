import CoreMedia
import Foundation
import Vision

/// Runs Apple Vision hand-pose detection on a single camera frame and converts
/// the best observation into a testable `HandPose`. Reuses one
/// `VNSequenceRequestHandler` plus a single request (Apple's recommended video
/// pattern): temporal tracking across frames, much faster than rebuilding both
/// per frame. Call `detect(in:)` serially — the capture pipeline uses one
/// video queue — concurrent use of one instance is not supported.
struct HandPoseDetector: Sendable {
    /// Vision joint for each `Joint` (`little*` maps to `pinky*`).
    static let jointNames: [(Joint, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.pinkyMCP, .littleMCP), (.pinkyPIP, .littlePIP), (.pinkyDIP, .littleDIP), (.pinkyTip, .littleTip),
    ]

    /// Reusable Vision request state (one per detector instance).
    private final class Cache: @unchecked Sendable {
        let handler = VNSequenceRequestHandler()
        let request: VNDetectHumanHandPoseRequest = {
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            return request
        }()
    }

    private let cache = Cache()

    var maximumHandCount: Int = 1

    /// Returns the highest-confidence hand in the frame, or nil when no hand is detected.
    func detect(in sampleBuffer: CMSampleBuffer) -> HandPose? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        cache.request.maximumHandCount = maximumHandCount
        guard (try? cache.handler.perform([cache.request], on: pixelBuffer)) != nil else { return nil }
        guard let observation = cache.request.results?.first else { return nil }
        return Self.handPose(from: observation)
    }

    static func handPose(from observation: VNHumanHandPoseObservation) -> HandPose? {
        guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
        var points: [Joint: SIMD2<Float>] = [:]
        var confidences: [Joint: Float] = [:]
        for (joint, name) in jointNames {
            guard let point = recognized[name] else { continue }
            points[joint] = SIMD2(Float(point.location.x), Float(point.location.y))
            confidences[joint] = point.confidence
        }
        guard points[.wrist] != nil else { return nil }
        return HandPose(points: points, confidences: confidences)
    }
}

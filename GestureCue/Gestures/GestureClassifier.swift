import Foundation

/// One frame of gesture classification: the recognized gesture, confidence
/// (0...1), and the wrist anchor for stillness tracking (nil on `.unknown`).
struct Classification: Sendable, Equatable {
    var gesture: HandGesture
    var confidence: Float
    var anchor: SIMD2<Float>? = nil
    /// Fingertip points in index..pinky order for EXTENDED fingers only
    /// (nil when a tip was unseen or the finger is curled). Only genuinely
    /// tracked tips gate the hold; tucked-tip estimates wobble too much.
    var tips: [SIMD2<Float>?] = []

    static let unknown = Classification(gesture: .unknown, confidence: 0)
}

/// Classifies a `HandPose` into a `HandGesture`. Pure and synchronous so it can
/// run on the video queue and be unit-tested without a camera.
protocol GestureClassifier: Sendable {
    func analyze(_ hand: HandPose) -> GeometricGestureClassifier.Analysis
}

extension GestureClassifier {
    func classify(_ hand: HandPose) -> Classification {
        analyze(hand).result
    }
}

/// Geometric classifier using resolution-independent ratios in normalized
/// landmark space (no pixel thresholds).
///
/// Finger verdicts:
/// - A finger whose tip Vision sees clearly is scored geometrically: it
///   counts as extended only if BOTH hold — the tip reaches clearly past
///   the PIP joint from the wrist, AND far from its own MCP. Either curl
///   test firing means curled.
/// - A finger whose tip Vision cannot see (missing or low-confidence) counts
///   as curled: an extended fingertip is visible, so an unseen tip is tucked
///   into the palm. Tucked joints are inherently low-confidence, and
///   requiring them would veto every real fist. Occlusion-inferred curl
///   carries a fixed moderate margin — weaker than geometric evidence.
/// - The wrist, knuckles, and middle joints (the palm skeleton) must always
///   be seen clearly; without them the frame is `.unknown`, so distant or
///   noisy hands cannot false-positive through the occlusion rule.
///
/// Rules: open palm = all fingers seen extended + thumb spread; fist = four
/// fingers curled with the thumb not raised (across, alongside, or occluded
/// thumbs are all still fists); thumbs-up = four fingers curled with the
/// thumb clearly raised past the knuckles; thumb-left/right = curled
/// fingers with the thumb clearly out to the user's left/right; index-up
/// / two-fingers-up / three-fingers-up
/// = exactly those fingers extended. Confidence is mean(deciding margins) ×
/// mean(used-joint confidences): one weak joint lowers confidence instead of
/// vetoing.
struct GeometricGestureClassifier: GestureClassifier {
    struct Config: Sendable, Equatable {
        /// tip-to-wrist / PIP-to-wrist ratio above which a finger is extended.
        var fingerExtensionThreshold: Float = 1.15
        /// Ratio span mapping a finger margin to 0...1 confidence.
        var fingerMarginScale: Float = 0.35
        /// tip-to-MCP / PIP-to-MCP reach above which a finger reads extended.
        var tipReachThreshold: Float = 1.4
        var tipReachMarginScale: Float = 0.4
        /// thumbTip-to-pinkyMCP / palm-width ratio above which the thumb is extended.
        var thumbSpreadThreshold: Float = 0.9
        var thumbMarginScale: Float = 0.5
        /// Thumb-tip reach past the knuckles, in hand-size units along the
        /// wrist→knuckle axis, to read as thumbs-up. Tucked thumbs stay low.
        var thumbAxialThreshold: Float = 0.45
        /// Sideways thumb-tip reach (same units) to read as thumb-left/right.
        var thumbLateralThreshold: Float = 0.45
        /// Minimum per-joint Vision confidence to use a joint geometrically.
        var minLandmarkConfidence: Float = 0.3
        /// Curl margin credited when a fingertip is unseen (occluded ⇒ tucked).
        var occludedCurlMargin: Float = 0.5
    }

    /// Per-finger verdict, in index..pinky order inside `Analysis.fingers`.
    struct FingerVerdict: Sendable, Equatable {
        var extended: Bool
        var extendedMargin: Float
        var curledMargin: Float
        /// True when the tip was unseen and curl was inferred from occlusion.
        var occluded: Bool
    }

    /// Why a frame was rejected (nil when a gesture was recognized).
    enum Rejection: String, Sendable {
        case noWrist
        case weakSkeleton
        case degenerate
        case noRule
    }

    /// Full per-frame analysis: finger verdicts, thumb state, evidence
    /// quality, and the resulting classification.
    struct Analysis: Sendable, Equatable {
        /// Verdicts in index..pinky order (may be partial on early rejection).
        var fingers: [FingerVerdict] = []
        /// Thumb spread in palm widths, nil when the thumb was unassessable.
        var thumbSpread: Float?
        /// Thumb-tip reach past the knuckles in hand-size units: axial along
        /// the hand, lateral sideways. Nil when unassessable.
        var thumbAxial: Float?
        var thumbLateral: Float?
        /// Mean confidence over the joints that participated.
        var quality: Float = 0
        var rejection: Rejection?
        var result: Classification = .unknown
    }

    private static let fingers: [(tip: Joint, pip: Joint, mcp: Joint)] = [
        (.indexTip, .indexPIP, .indexMCP),
        (.middleTip, .middlePIP, .middleMCP),
        (.ringTip, .ringPIP, .ringMCP),
        (.pinkyTip, .pinkyPIP, .pinkyMCP),
    ]

    var config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    func analyze(_ hand: HandPose) -> Analysis {
        guard let wrist = hand.point(.wrist),
              hand.confidence(.wrist) >= config.minLandmarkConfidence
        else { return Analysis(rejection: .noWrist) }

        var verdicts: [FingerVerdict] = []
        var tipPoints: [SIMD2<Float>?] = []
        var scoredConfidences: [Float] = [hand.confidence(.wrist)]
        for finger in Self.fingers {
            guard let pip = hand.point(finger.pip),
                  let mcp = hand.point(finger.mcp),
                  hand.confidence(finger.pip) >= config.minLandmarkConfidence,
                  hand.confidence(finger.mcp) >= config.minLandmarkConfidence
            else { return Analysis(fingers: verdicts, rejection: .weakSkeleton) }
            scoredConfidences += [hand.confidence(finger.pip), hand.confidence(finger.mcp)]
            if let tip = hand.point(finger.tip),
               hand.confidence(finger.tip) >= config.minLandmarkConfidence
            {
                guard let score = fingerScore(tip: tip, pip: pip, mcp: mcp, wrist: wrist) else {
                    return Analysis(fingers: verdicts, rejection: .degenerate)
                }
                tipPoints.append(score.extended ? tip : nil)
                scoredConfidences.append(hand.confidence(finger.tip))
                verdicts.append(FingerVerdict(
                    extended: score.extended,
                    extendedMargin: score.extendedMargin,
                    curledMargin: score.curledMargin,
                    occluded: false
                ))
            } else {
                // Unseen tip ⇒ tucked into the palm.
                tipPoints.append(nil)
                verdicts.append(FingerVerdict(
                    extended: false,
                    extendedMargin: 0,
                    curledMargin: config.occludedCurlMargin,
                    occluded: true
                ))
            }
        }
        let quality = scoredConfidences.reduce(0, +) / Float(scoredConfidences.count)

        // Skeleton joints passed above, so these points exist.
        guard let indexMCP = hand.point(.indexMCP), let pinkyMCP = hand.point(.pinkyMCP) else {
            return Analysis(fingers: verdicts, quality: quality, rejection: .weakSkeleton)
        }
        let spread = thumbSpread(hand: hand, indexMCP: indexMCP, pinkyMCP: pinkyMCP)
        let axes = thumbAxes(hand: hand)
        var analysis = Analysis(fingers: verdicts, thumbSpread: spread, thumbAxial: axes?.axial, thumbLateral: axes?.lateral, quality: quality)

        let extended = verdicts.map(\.extended)
        if extended.allSatisfy({ $0 }), let spread, spread > config.thumbSpreadThreshold {
            var margins = verdicts.map(\.extendedMargin)
            margins.append(margin(value: spread, threshold: config.thumbSpreadThreshold, scale: config.thumbMarginScale))
            analysis.result = Classification(gesture: .openPalm, confidence: mean(margins) * quality, anchor: wrist, tips: tipPoints)
            return analysis
        }
        if extended.allSatisfy({ !$0 }) {
            if let axes, axes.axial >= config.thumbAxialThreshold, axes.axial >= abs(axes.lateral) {
                // Thumbs-up: the thumb rises past the knuckles. Rare in
                // sign language, so it carries commands the fist cannot.
                var margins = verdicts.map(\.curledMargin)
                margins.append(margin(value: axes.axial, threshold: config.thumbAxialThreshold, scale: config.thumbMarginScale))
                analysis.result = Classification(gesture: .thumbsUp, confidence: mean(margins) * quality, anchor: wrist, tips: tipPoints)
                return analysis
            }
            if let axes, abs(axes.lateral) >= config.thumbLateralThreshold, abs(axes.lateral) > axes.axial {
                // Sideways thumb: positive lateral is image-right, which in
                // the unmirrored camera view is the user's own LEFT.
                let gesture: HandGesture = axes.lateral > 0 ? .thumbLeft : .thumbRight
                var margins = verdicts.map(\.curledMargin)
                margins.append(margin(value: abs(axes.lateral), threshold: config.thumbLateralThreshold, scale: config.thumbMarginScale))
                analysis.result = Classification(gesture: gesture, confidence: mean(margins) * quality, anchor: wrist, tips: tipPoints)
                return analysis
            }
            analysis.result = Classification(
                gesture: .fist, confidence: mean(verdicts.map(\.curledMargin)) * quality, anchor: wrist, tips: tipPoints
            )
            return analysis
        }
        if extended == [true, false, false, false] {
            let margins = [verdicts[0].extendedMargin, verdicts[1].curledMargin, verdicts[2].curledMargin, verdicts[3].curledMargin]
            analysis.result = Classification(gesture: .indexUp, confidence: mean(margins) * quality, anchor: wrist, tips: tipPoints)
            return analysis
        }
        if extended == [true, true, false, false] {
            let margins = [verdicts[0].extendedMargin, verdicts[1].extendedMargin, verdicts[2].curledMargin, verdicts[3].curledMargin]
            analysis.result = Classification(gesture: .twoFingersUp, confidence: mean(margins) * quality, anchor: wrist, tips: tipPoints)
            return analysis
        }
        if extended == [true, true, true, false] {
            let margins = [verdicts[0].extendedMargin, verdicts[1].extendedMargin, verdicts[2].extendedMargin, verdicts[3].curledMargin]
            analysis.result = Classification(gesture: .threeFingersUp, confidence: mean(margins) * quality, anchor: wrist, tips: tipPoints)
            return analysis
        }
        analysis.rejection = .noRule
        return analysis
    }

    /// One-line live explanation of a frame for on-screen debugging, e.g.
    /// `I:curl(.99) M:ext(.93) R:occluded P:curl(.88) T:.36(.62/-.05) Q:.71 → fist .62`
    /// (thumb spread, then axial/lateral reach in parentheses).
    /// `?` plus a reason marks rejection (`noWrist`, `weakSkeleton`,
    /// `degenerate`, `noRule`).
    func diagnose(_ hand: HandPose) -> String {
        let analysis = analyze(hand)
        let names = ["I", "M", "R", "P"]
        var parts: [String] = []
        for (index, verdict) in analysis.fingers.enumerated() where index < names.count {
            if verdict.occluded {
                parts.append("\(names[index]):occluded")
            } else if verdict.extended {
                parts.append("\(names[index]):ext(\(short(verdict.extendedMargin)))")
            } else {
                parts.append("\(names[index]):curl(\(short(verdict.curledMargin)))")
            }
        }
        if let spread = analysis.thumbSpread {
            var thumb = "T:\(short(spread))"
            if let axial = analysis.thumbAxial, let lateral = analysis.thumbLateral {
                thumb += "(\(short(axial))/\(short(lateral)))"
            }
            parts.append(thumb)
        } else {
            parts.append("T:?")
        }
        parts.append("Q:\(short(analysis.quality))")
        if let rejection = analysis.rejection {
            parts.append("→ ?\(rejection.rawValue)")
        } else {
            parts.append("→ \(analysis.result.gesture) \(short(analysis.result.confidence))")
        }
        return parts.joined(separator: " ")
    }

    /// Thumb spread in palm widths, or nil when the thumb cannot be assessed.
    private func thumbSpread(hand: HandPose, indexMCP: SIMD2<Float>, pinkyMCP: SIMD2<Float>) -> Float? {
        guard let thumbTip = hand.point(.thumbTip),
              hand.confidence(.thumbTip) >= config.minLandmarkConfidence
        else { return nil }
        let palmWidth = distance(indexMCP, pinkyMCP)
        guard palmWidth > 1e-6 else { return nil }
        return distance(thumbTip, pinkyMCP) / palmWidth
    }

    /// Thumb-tip position past the knuckles in hand-size units: axial along
    /// the wrist→knuckle axis (up past the fist), lateral perpendicular.
    /// Nil when the thumb tip is unseen or the hand is degenerate.
    private func thumbAxes(hand: HandPose) -> (axial: Float, lateral: Float)? {
        guard let tip = hand.point(.thumbTip),
              hand.confidence(.thumbTip) >= config.minLandmarkConfidence,
              let wrist = hand.point(.wrist),
              let middleMCP = hand.point(.middleMCP)
        else { return nil }
        let handSize = distance(wrist, middleMCP)
        guard handSize > 1e-6 else { return nil }
        let axis = (middleMCP - wrist) / handSize
        let v = (tip - middleMCP) / handSize
        let axial = v.x * axis.x + v.y * axis.y
        // Lateral against the clockwise-perpendicular: positive is
        // image-right (the user's own left in the unmirrored view).
        let lateral = v.x * axis.y - v.y * axis.x
        return (axial, lateral)
    }

    /// Extension score for one finger from two independent curl tests.
    private func fingerScore(tip: SIMD2<Float>, pip: SIMD2<Float>, mcp: SIMD2<Float>, wrist: SIMD2<Float>) -> (extended: Bool, extendedMargin: Float, curledMargin: Float)? {
        let pipDistance = distance(pip, wrist)
        let reachBase = distance(pip, mcp)
        guard pipDistance > 1e-6, reachBase > 1e-6 else { return nil }
        // Test 1: extended fingertips reach far past the PIP joint from the wrist.
        let s1 = (distance(tip, wrist) / pipDistance - config.fingerExtensionThreshold) / config.fingerMarginScale
        // Test 2: curled fingertips stay near their own MCP. Deep palm-facing
        // curls defeat test 1 when the knuckle folds back toward the wrist.
        let s2 = (distance(tip, mcp) / reachBase - config.tipReachThreshold) / config.tipReachMarginScale
        return (s1 > 0 && s2 > 0, clamp01(min(s1, s2)), clamp01(max(-s1, -s2)))
    }

    private func mean(_ values: [Float]) -> Float {
        values.reduce(0, +) / Float(values.count)
    }

    private func clamp01(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    /// 0...1 confidence from how far `value` clears `threshold`.
    private func margin(value: Float, threshold: Float, scale: Float) -> Float {
        min(max((value - threshold) / scale, 0), 1)
    }

    /// Compact 0...1 formatting for diagnosis (`0.71` → `.71`).
    private func short(_ value: Float) -> String {
        let formatted = String(format: "%.2f", value)
        return formatted.hasPrefix("0.") ? String(formatted.dropFirst()) : formatted
    }
}

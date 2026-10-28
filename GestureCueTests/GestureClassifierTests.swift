import XCTest
@testable import GestureCue

final class GestureClassifierTests: XCTestCase {
    private let classifier = GeometricGestureClassifier()

    // MARK: - Synthetic poses (normalized Vision coordinates)

    private static let wrist = SIMD2<Float>(0.5, 0.1)
    private static let indexMCP = SIMD2<Float>(0.38, 0.45)
    private static let pinkyMCP = SIMD2<Float>(0.62, 0.45)
    private static let fingerX: [Float] = [0.38, 0.46, 0.54, 0.62] // index..pinky

    private func pose(_ points: [Joint: SIMD2<Float>], confidence: Float = 0.95) -> HandPose {
        HandPose(
            points: points,
            confidences: Dictionary(uniqueKeysWithValues: points.keys.map { ($0, confidence) })
        )
    }

    private func extendedFinger(_ pip: Joint, tip tipJoint: Joint, x: Float, into points: inout [Joint: SIMD2<Float>]) {
        points[pip] = SIMD2(x, 0.60)
        points[tipJoint] = SIMD2(x, 0.85)
    }

    private func curledFinger(_ pip: Joint, tip tipJoint: Joint, x: Float, into points: inout [Joint: SIMD2<Float>]) {
        points[pip] = SIMD2(x, 0.55)
        points[tipJoint] = SIMD2(x, 0.42)
    }

    private func openPalmPoints() -> [Joint: SIMD2<Float>] {
        var points: [Joint: SIMD2<Float>] = [
            .wrist: Self.wrist,
            .indexMCP: Self.indexMCP,
            .middleMCP: SIMD2(0.46, 0.45),
            .ringMCP: SIMD2(0.54, 0.45),
            .pinkyMCP: Self.pinkyMCP,
            .thumbTip: SIMD2(0.18, 0.45), // spread wide of the palm
        ]
        let joints: [(Joint, Joint)] = [(.indexPIP, .indexTip), (.middlePIP, .middleTip), (.ringPIP, .ringTip), (.pinkyPIP, .pinkyTip)]
        for (i, (pip, tip)) in joints.enumerated() {
            extendedFinger(pip, tip: tip, x: Self.fingerX[i], into: &points)
        }
        return points
    }

    private func fistPoints() -> [Joint: SIMD2<Float>] {
        var points: [Joint: SIMD2<Float>] = [
            .wrist: Self.wrist,
            .indexMCP: Self.indexMCP,
            .middleMCP: SIMD2(0.46, 0.45),
            .ringMCP: SIMD2(0.54, 0.45),
            .pinkyMCP: Self.pinkyMCP,
            .thumbTip: SIMD2(0.55, 0.40), // tucked across the fingers
        ]
        let joints: [(Joint, Joint)] = [(.indexPIP, .indexTip), (.middlePIP, .middleTip), (.ringPIP, .ringTip), (.pinkyPIP, .pinkyTip)]
        for (i, (pip, tip)) in joints.enumerated() {
            curledFinger(pip, tip: tip, x: Self.fingerX[i], into: &points)
        }
        return points
    }

    private func indexUpPoints() -> [Joint: SIMD2<Float>] {
        var points: [Joint: SIMD2<Float>] = [
            .wrist: Self.wrist,
            .indexMCP: Self.indexMCP,
            .middleMCP: SIMD2(0.46, 0.45),
            .ringMCP: SIMD2(0.54, 0.45),
            .pinkyMCP: Self.pinkyMCP,
            .thumbTip: SIMD2(0.55, 0.40),
        ]
        extendedFinger(.indexPIP, tip: .indexTip, x: Self.fingerX[0], into: &points)
        let curled: [(Joint, Joint)] = [(.middlePIP, .middleTip), (.ringPIP, .ringTip), (.pinkyPIP, .pinkyTip)]
        for (i, (pip, tip)) in curled.enumerated() {
            curledFinger(pip, tip: tip, x: Self.fingerX[i + 1], into: &points)
        }
        return points
    }

    private func twoFingersUpPoints() -> [Joint: SIMD2<Float>] {
        var points: [Joint: SIMD2<Float>] = [
            .wrist: Self.wrist,
            .indexMCP: Self.indexMCP,
            .middleMCP: SIMD2(0.46, 0.45),
            .ringMCP: SIMD2(0.54, 0.45),
            .pinkyMCP: Self.pinkyMCP,
            .thumbTip: SIMD2(0.55, 0.40),
        ]
        extendedFinger(.indexPIP, tip: .indexTip, x: Self.fingerX[0], into: &points)
        extendedFinger(.middlePIP, tip: .middleTip, x: Self.fingerX[1], into: &points)
        curledFinger(.ringPIP, tip: .ringTip, x: Self.fingerX[2], into: &points)
        curledFinger(.pinkyPIP, tip: .pinkyTip, x: Self.fingerX[3], into: &points)
        return points
    }

    /// Palm-facing fist: knuckles fold toward the wrist so tips project
    /// beyond PIPs (defeating the wrist-ratio test); the MCP-reach test
    /// must still read every finger as curled.
    private func deepCurlFistPoints() -> [Joint: SIMD2<Float>] {
        var points: [Joint: SIMD2<Float>] = [
            .wrist: Self.wrist,
            .thumbTip: SIMD2(0.55, 0.40),
        ]
        let mcps: [Joint] = [.indexMCP, .middleMCP, .ringMCP, .pinkyMCP]
        let pips: [Joint] = [.indexPIP, .middlePIP, .ringPIP, .pinkyPIP]
        let tips: [Joint] = [.indexTip, .middleTip, .ringTip, .pinkyTip]
        for (i, x) in Self.fingerX.enumerated() {
            points[mcps[i]] = SIMD2(x, 0.45)
            points[pips[i]] = SIMD2(x, 0.58) // knuckle folded back toward the wrist
            points[tips[i]] = SIMD2(x + 0.12, 0.52) // tucked into the palm, past the PIP
        }
        return points
    }

    // MARK: - The eight gestures

    func testOpenPalm() {
        let result = classifier.classify(pose(openPalmPoints()))
        XCTAssertEqual(result.gesture, .openPalm)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testFist() {
        let result = classifier.classify(pose(fistPoints()))
        XCTAssertEqual(result.gesture, .fist)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testIndexUp() {
        let result = classifier.classify(pose(indexUpPoints()))
        XCTAssertEqual(result.gesture, .indexUp)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testTwoFingersUp() {
        let result = classifier.classify(pose(twoFingersUpPoints()))
        XCTAssertEqual(result.gesture, .twoFingersUp)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testTwoFingersUpIgnoresThumb() {
        var points = twoFingersUpPoints()
        points[.thumbTip] = SIMD2(0.18, 0.45) // thumb out: still two fingers up
        XCTAssertEqual(classifier.classify(pose(points)).gesture, .twoFingersUp)
    }

    func testThreeFingersUp() {
        var points = twoFingersUpPoints()
        extendedFinger(.ringPIP, tip: .ringTip, x: Self.fingerX[2], into: &points)
        let result = classifier.classify(pose(points))
        XCTAssertEqual(result.gesture, .threeFingersUp)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testThreeFingersUpIgnoresThumb() {
        var points = twoFingersUpPoints()
        extendedFinger(.ringPIP, tip: .ringTip, x: Self.fingerX[2], into: &points)
        points[.thumbTip] = SIMD2(0.18, 0.45) // thumb out: still three fingers up
        XCTAssertEqual(classifier.classify(pose(points)).gesture, .threeFingersUp)
    }

    func testDeepCurlFist() {
        let result = classifier.classify(pose(deepCurlFistPoints()))
        XCTAssertEqual(result.gesture, .fist)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testFistWithThumbAcross() {
        var points = fistPoints()
        points[.thumbTip] = SIMD2(0.40, 0.42) // thumb lying over the fingers
        XCTAssertEqual(classifier.classify(pose(points)).gesture, .fist)
    }

    func testFistWithSideThumb() {
        var points = fistPoints()
        points[.thumbTip] = SIMD2(0.30, 0.50) // thumb alongside, clearly not raised
        XCTAssertEqual(classifier.classify(pose(points)).gesture, .fist)
    }

    func testFistWithOccludedThumb() {
        var points = fistPoints()
        points.removeValue(forKey: .thumbTip)
        XCTAssertEqual(classifier.classify(pose(points)).gesture, .fist)
    }

    // MARK: - Real-fist robustness (unseen fingertips)

    /// Real-fist simulation: clear palm skeleton, tucked tips Vision cannot see.
    private func pose(_ points: [Joint: SIMD2<Float>], tipConfidence: Float, baseConfidence: Float = 0.9) -> HandPose {
        var confidences: [Joint: Float] = [:]
        for key in points.keys {
            switch key {
            case .indexTip, .middleTip, .ringTip, .pinkyTip, .thumbTip:
                confidences[key] = tipConfidence
            default:
                confidences[key] = baseConfidence
            }
        }
        return HandPose(points: points, confidences: confidences)
    }

    func testFistWithUnseenFingertips() {
        var points = fistPoints()
        points.removeValue(forKey: .indexTip)
        points.removeValue(forKey: .middleTip)
        points.removeValue(forKey: .ringTip)
        points.removeValue(forKey: .pinkyTip)
        let result = classifier.classify(pose(points))
        XCTAssertEqual(result.gesture, .fist)
        // Must clear the state machine's 0.35 gate to actually fire.
        XCTAssertGreaterThan(result.confidence, 0.35)
    }

    func testFistWithLowTipConfidence() {
        let result = classifier.classify(pose(fistPoints(), tipConfidence: 0.15))
        XCTAssertEqual(result.gesture, .fist)
        XCTAssertGreaterThan(result.confidence, 0.35)
    }

    func testUnseenIndexTipReadsAsFist() {
        // Occlusion never extends: an unseen index tip curls, so the pose
        // reads as a fist — never as index-up.
        var points = indexUpPoints()
        points.removeValue(forKey: .indexTip)
        XCTAssertEqual(classifier.classify(pose(points)).gesture, .fist)
    }

    func testWeakSkeletonIsUnknown() {
        // A distant/noisy hand must not false-positive via the occlusion rule.
        XCTAssertEqual(classifier.classify(pose(fistPoints(), confidence: 0.2)), .unknown)
    }

    func testDiagnosisReportsOcclusion() {
        var points = fistPoints()
        points.removeValue(forKey: .ringTip)
        let diagnosis = classifier.diagnose(pose(points))
        XCTAssertTrue(diagnosis.contains("R:occluded"), diagnosis)
        XCTAssertTrue(diagnosis.contains("fist"), diagnosis)
    }

    // MARK: - Confidence and completeness gating

    func testLowLandmarkConfidenceIsUnknown() {
        let result = classifier.classify(pose(openPalmPoints(), confidence: 0.1))
        XCTAssertEqual(result, .unknown)
    }

    func testConfidenceScalesWithLandmarkQuality() {
        let crisp = classifier.classify(pose(openPalmPoints(), confidence: 1.0))
        let blurry = classifier.classify(pose(openPalmPoints(), confidence: 0.5))
        XCTAssertEqual(crisp.gesture, .openPalm)
        XCTAssertEqual(blurry.gesture, .openPalm)
        XCTAssertLessThan(blurry.confidence, crisp.confidence)
    }

    func testMissingWristIsUnknown() {
        var points = fistPoints()
        points.removeValue(forKey: .wrist)
        XCTAssertEqual(classifier.classify(pose(points)), .unknown)
    }

    func testMissingFingertipIsUnknown() {
        var points = openPalmPoints()
        points.removeValue(forKey: .middleTip)
        XCTAssertEqual(classifier.classify(pose(points)), .unknown)
    }

    // MARK: - Ambiguous and degenerate poses

    func testThumbsUp() {
        var points = fistPoints()
        points[.thumbTip] = SIMD2(0.42, 0.72) // thumb rising past the knuckles
        let result = classifier.classify(pose(points))
        XCTAssertEqual(result.gesture, .thumbsUp)
        XCTAssertGreaterThan(result.confidence, 0.5)
        let analysis = classifier.analyze(pose(points))
        XCTAssertEqual(analysis.thumbAxial ?? -1, 0.77, accuracy: 0.05)
        XCTAssertEqual(analysis.thumbLateral ?? 99, 0, accuracy: 0.05)
    }

    func testThumbRight() {
        // Tip far toward image-left = the user's own right (unmirrored view).
        var points = fistPoints()
        points[.thumbTip] = SIMD2(0.18, 0.45)
        let result = classifier.classify(pose(points))
        XCTAssertEqual(result.gesture, .thumbRight)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testThumbLeft() {
        var points = fistPoints()
        points[.thumbTip] = SIMD2(0.74, 0.45)
        let result = classifier.classify(pose(points))
        XCTAssertEqual(result.gesture, .thumbLeft)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testDiagonalThumbPrefersUp() {
        // Axial 0.5, lateral 0.3: up wins ties and near-ties.
        var points = fistPoints()
        points[.thumbTip] = SIMD2(0.545, 0.637)
        XCTAssertEqual(classifier.classify(pose(points)).gesture, .thumbsUp)
    }

    func testThumbsUpWithUnseenFingertips() {
        // Real thumbs-up: tucked tips Vision cannot see, thumb clearly out.
        var points = fistPoints()
        points[.thumbTip] = SIMD2(0.42, 0.72)
        points.removeValue(forKey: .indexTip)
        points.removeValue(forKey: .middleTip)
        points.removeValue(forKey: .ringTip)
        points.removeValue(forKey: .pinkyTip)
        let result = classifier.classify(pose(points))
        XCTAssertEqual(result.gesture, .thumbsUp)
        XCTAssertGreaterThan(result.confidence, 0.35)
    }

    func testDegeneratePipAtWristIsUnknown() {
        var points = openPalmPoints()
        points[.indexPIP] = Self.wrist
        XCTAssertEqual(classifier.classify(pose(points)), .unknown)
    }

    func testZeroPalmWidthIsUnknown() {
        var points = openPalmPoints()
        points[.pinkyMCP] = Self.indexMCP
        XCTAssertEqual(classifier.classify(pose(points)), .unknown)
    }

    func testClassificationCarriesWristAnchor() {
        XCTAssertEqual(classifier.classify(pose(openPalmPoints())).anchor, Self.wrist)
        XCTAssertNil(classifier.classify(pose([:])).anchor)
    }

    func testCurledTipsExcludedFromStillness() {
        // Seen-but-curled tips are estimates that wobble: they must not
        // gate the hold, or fist-family poses could never fire.
        let fist = classifier.classify(pose(fistPoints()))
        XCTAssertEqual(fist.gesture, .fist)
        XCTAssertTrue(fist.tips.allSatisfy { $0 == nil })
        let index = classifier.classify(pose(indexUpPoints()))
        XCTAssertEqual(index.gesture, .indexUp)
        XCTAssertNotNil(index.tips[0], "extended index tip gates the hold")
        XCTAssertTrue(index.tips[1...].allSatisfy { $0 == nil })
    }

    func testClassificationCarriesTipPoints() {
        let palm = classifier.classify(pose(openPalmPoints()))
        XCTAssertEqual(palm.tips.count, 4)
        XCTAssertTrue(palm.tips.allSatisfy { $0 != nil })
        var tucked = fistPoints()
        tucked.removeValue(forKey: .indexTip)
        tucked.removeValue(forKey: .middleTip)
        tucked.removeValue(forKey: .ringTip)
        tucked.removeValue(forKey: .pinkyTip)
        let fist = classifier.classify(pose(tucked))
        XCTAssertEqual(fist.tips.count, 4)
        XCTAssertTrue(fist.tips.allSatisfy { $0 == nil })
    }
}

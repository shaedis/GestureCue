import CoreGraphics
import XCTest
@testable import GestureCue

final class FingerPaintControllerTests: XCTestCase {
    private let cardA = UUID()
    private let cardB = UUID()

    /// Hand with thumb/index tips placed for pinch control. Wrist (0.5, 0.1),
    /// middle MCP (0.5, 0.45): hand size 0.35.
    private func pose(thumbTip: SIMD2<Float>, indexTip: SIMD2<Float>, confidence: Float = 0.95) -> HandPose {
        let points: [Joint: SIMD2<Float>] = [
            .wrist: SIMD2(0.5, 0.1),
            .middleMCP: SIMD2(0.5, 0.45),
            .thumbTip: thumbTip,
            .indexTip: indexTip,
        ]
        return HandPose(points: points, confidences: Dictionary(uniqueKeysWithValues: points.keys.map { ($0, confidence) }))
    }

    private func pinchedPose(at x: Float = 0.5, y: Float = 0.5, confidence: Float = 0.95) -> HandPose {
        // Gap 0.02 / 0.35 ≈ 0.06: firmly pinched.
        pose(thumbTip: SIMD2(x, y), indexTip: SIMD2(x + 0.02, y), confidence: confidence)
    }

    private func openPose(at x: Float = 0.5, y: Float = 0.5) -> HandPose {
        // Gap 0.3 / 0.35 ≈ 0.86: firmly open.
        pose(thumbTip: SIMD2(x, y), indexTip: SIMD2(x + 0.3, y))
    }

    private func midPose(at x: Float = 0.5, y: Float = 0.5) -> HandPose {
        // Gap 0.21 / 0.35 = 0.6: inside the hysteresis band (0.5...0.65).
        pose(thumbTip: SIMD2(x, y), indexTip: SIMD2(x + 0.21, y))
    }

    private func paintedController(card: UUID? = nil) -> (FingerPaintController, LayersBox) {
        let paint = FingerPaintController()
        paint.setMode(.paint)
        paint.setCurrentCard(card)
        let box = LayersBox()
        paint.sink = { box.layers.append($0) }
        return (paint, box)
    }

    private func drawStroke(_ paint: FingerPaintController, at x: Float) {
        _ = paint.handle(pinchedPose(at: x, y: 0.5))
        _ = paint.handle(pinchedPose(at: x + 0.05, y: 0.5))
        _ = paint.handle(openPose(at: x + 0.05, y: 0.5))
    }

    func testModeOffIgnoresFrames() {
        let paint = FingerPaintController()
        let box = LayersBox()
        paint.sink = { box.layers.append($0) }
        XCTAssertFalse(paint.handle(pinchedPose()))
        XCTAssertTrue(box.layers.isEmpty)
    }

    func testPinchStartsStrokeAndDragAppendsPoints() {
        let (paint, box) = paintedController(card: cardA)
        XCTAssertTrue(paint.handle(pinchedPose(at: 0.4, y: 0.5)))
        XCTAssertTrue(paint.handle(pinchedPose(at: 0.45, y: 0.5)))
        XCTAssertTrue(paint.handle(pinchedPose(at: 0.5, y: 0.5)))
        let strokes = box.layers.last?.strokes ?? []
        XCTAssertEqual(strokes.count, 1)
        XCTAssertEqual(strokes.first?.color, .yellow)
        XCTAssertGreaterThanOrEqual(strokes.first?.points.count ?? 0, 3)
    }

    func testReleaseCommitsStroke() {
        let (paint, box) = paintedController(card: cardA)
        XCTAssertTrue(paint.handle(pinchedPose()))
        XCTAssertFalse(paint.handle(openPose()))
        XCTAssertEqual(box.layers.last?.strokes.count, 1, "released stroke is committed")
        XCTAssertTrue(paint.handle(pinchedPose()))
        XCTAssertFalse(paint.handle(openPose()))
        XCTAssertEqual(box.layers.last?.strokes.count, 2)
    }

    func testHysteresisBandKeepsState() {
        let (paint, _) = paintedController(card: cardA)
        XCTAssertFalse(paint.handle(midPose()), "mid-band from open stays open")
        XCTAssertTrue(paint.handle(pinchedPose()))
        XCTAssertTrue(paint.handle(midPose()), "mid-band from pinched keeps painting")
    }

    func testHandLossCommitsAndHidesPointer() {
        let (paint, box) = paintedController(card: cardA)
        XCTAssertTrue(paint.handle(pinchedPose()))
        XCTAssertFalse(paint.handle(nil))
        XCTAssertEqual(box.layers.last?.strokes.count, 1)
        XCTAssertNil(box.layers.last?.pointer)
    }

    func testSmoothingConverges() {
        let (paint, box) = paintedController(card: cardA)
        for _ in 0..<20 {
            _ = paint.handle(openPose(at: 0.5, y: 0.5)) // index tip at (0.8, 0.5)
        }
        let settled = box.layers.last?.pointer
        XCTAssertEqual(settled?.x ?? -1, 0.8, accuracy: 0.001)
        XCTAssertEqual(settled?.y ?? -1, 0.5, accuracy: 0.001)
        _ = paint.handle(openPose(at: 0.5, y: 0.6))
        let moved = box.layers.last?.pointer
        XCTAssertEqual(moved?.y ?? -1, 0.54, accuracy: 0.001, "one frame moves only 40% of the step")
    }

    func testUndoRedoClear() {
        let (paint, box) = paintedController(card: cardA)
        drawStroke(paint, at: 0.4)
        drawStroke(paint, at: 0.6)
        XCTAssertEqual(box.layers.last?.strokes.count, 2)
        paint.undo()
        XCTAssertEqual(box.layers.last?.strokes.count, 1)
        paint.redo()
        XCTAssertEqual(box.layers.last?.strokes.count, 2)
        paint.clear()
        XCTAssertEqual(box.layers.last?.strokes.count, 0)
        paint.redo()
        XCTAssertEqual(box.layers.last?.strokes.count, 0, "clear wipes the redo stack")
    }

    func testStrokesKeptPerCard() {
        let (paint, box) = paintedController(card: cardA)
        drawStroke(paint, at: 0.4)
        XCTAssertEqual(box.layers.last?.strokes.count, 1)
        paint.setCurrentCard(cardB)
        XCTAssertEqual(box.layers.last?.strokes.count, 0, "other card starts clean")
        drawStroke(paint, at: 0.6)
        paint.setCurrentCard(cardA)
        XCTAssertEqual(box.layers.last?.strokes.count, 1, "first card's stroke restored")
    }

    func testLowConfidenceTreatedAsNoHand() {
        let (paint, box) = paintedController(card: cardA)
        XCTAssertFalse(paint.handle(pinchedPose(confidence: 0.1)))
        XCTAssertTrue(box.layers.isEmpty, "nothing pushed for unreliable frames")
    }

    func testColorAppliesToNewStrokes() {
        let (paint, box) = paintedController(card: cardA)
        paint.setColor(.red)
        drawStroke(paint, at: 0.4)
        XCTAssertEqual(box.layers.last?.strokes.first?.color, .red)
        XCTAssertEqual(box.layers.last?.pointerColor, .red)
    }

    func testMinSpacingSkipsDuplicates() {
        let (paint, box) = paintedController(card: cardA)
        for _ in 0..<10 {
            _ = paint.handle(pinchedPose(at: 0.5, y: 0.5))
        }
        XCTAssertEqual(box.layers.last?.strokes.first?.points.count, 1)
    }
}

/// Test-only sink capture. Single-threaded use; marked Sendable for the sink type.
private final class LayersBox: @unchecked Sendable {
    var layers: [PaintLayer] = []
}

final class PinchZoomTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ step: Int) -> Date {
        start.addingTimeInterval(Double(step) / 30)
    }

    /// Pose with an approximate normalized thumb–index gap (hand size ≈ 0.352).
    private func gapPose(gap: Float, confidence: Float = 0.9) -> HandPose {
        HandPose(
            points: [
                .wrist: SIMD2(0.5, 0.1),
                .middleMCP: SIMD2(0.46, 0.45),
                .indexTip: SIMD2(0.5, 0.6),
                .thumbTip: SIMD2(0.5 + gap * 0.352, 0.6),
            ],
            confidences: [.wrist: confidence, .middleMCP: confidence, .indexTip: confidence, .thumbTip: confidence]
        )
    }

    func testPinchGapValue() {
        let gap = FingerPaintController.pinchGap(of: gapPose(gap: 0.3), minJointConfidence: 0.3)
        XCTAssertEqual(gap ?? -1, 0.3, accuracy: 0.01)
    }

    func testPinchGapNilWhenWeakOrMissing() {
        XCTAssertNil(FingerPaintController.pinchGap(of: gapPose(gap: 0.3, confidence: 0.1), minJointConfidence: 0.3))
        XCTAssertNil(FingerPaintController.pinchGap(of: nil, minJointConfidence: 0.3))
        XCTAssertNil(FingerPaintController.pinchGap(of: HandPose(), minJointConfidence: 0.3))
    }

    func testSpreadFiresZoomIn() {
        var tracker = PinchZoomTracker()
        let distances: [Float] = [0.20, 0.26, 0.32, 0.38]
        var actions: [CardAction?] = []
        for (step, distance) in distances.enumerated() {
            actions.append(tracker.update(distance: distance, at: at(step)).zoomAction)
        }
        XCTAssertEqual(actions, [nil, nil, nil, .zoomIn])
    }

    func testCloseFiresZoomOut() {
        var tracker = PinchZoomTracker()
        let distances: [Float] = [0.60, 0.54, 0.48, 0.42]
        var actions: [CardAction?] = []
        for (step, distance) in distances.enumerated() {
            actions.append(tracker.update(distance: distance, at: at(step)).zoomAction)
        }
        XCTAssertEqual(actions, [nil, nil, nil, .zoomOut])
    }

    func testStillHandNeverFiresNorSuppresses() {
        var tracker = PinchZoomTracker()
        for step in 0..<10 {
            let decision = tracker.update(distance: 0.5, at: at(step))
            XCTAssertNil(decision.zoomAction)
            XCTAssertFalse(decision.suppressStatic)
        }
    }

    func testJitterBelowThresholdIsIgnored() {
        var tracker = PinchZoomTracker()
        for step in 0..<10 {
            let distance: Float = step.isMultiple(of: 2) ? 0.50 : 0.51
            let decision = tracker.update(distance: distance, at: at(step))
            XCTAssertNil(decision.zoomAction)
            XCTAssertFalse(decision.suppressStatic)
        }
    }

    func testNilResets() {
        var tracker = PinchZoomTracker()
        _ = tracker.update(distance: 0.2, at: at(0))
        _ = tracker.update(distance: 0.3, at: at(1))
        XCTAssertEqual(tracker.update(distance: nil, at: at(2)), .none)
        let decision = tracker.update(distance: 0.3, at: at(3))
        XCTAssertNil(decision.zoomAction)
        XCTAssertFalse(decision.suppressStatic, "fresh anchor after reset")
    }

    func testCooldownPacesSteps() {
        var config = PinchZoomTracker.Config()
        config.stepCooldown = 10
        var tracker = PinchZoomTracker(config: config)
        var fires = 0
        var distance: Float = 0.2
        for step in 0..<30 {
            distance += 0.03
            if tracker.update(distance: distance, at: at(step)).zoomAction != nil {
                fires += 1
            }
        }
        XCTAssertEqual(fires, 1)
    }

    func testSuppressionLingersAfterMotion() {
        var tracker = PinchZoomTracker()
        _ = tracker.update(distance: 0.2, at: at(0))
        let moving = tracker.update(distance: 0.25, at: at(1))
        XCTAssertTrue(moving.suppressStatic)
        let stopped = tracker.update(distance: 0.25, at: at(2))
        XCTAssertTrue(stopped.suppressStatic, "motion 1 frame ago still suppresses")
        let later = tracker.update(distance: 0.25, at: start.addingTimeInterval(1.5))
        XCTAssertFalse(later.suppressStatic)
        XCTAssertNil(later.zoomAction)
    }
}

final class ZoomHandGateTests: XCTestCase {
    private let zoomFingers = [true, false, false, false]

    func testEngagesOnIndexPlusRaisedThumb() {
        var gate = ZoomHandGate()
        let first = gate.update(fingers: zoomFingers, thumbHeight: 0.8)
        XCTAssertTrue(first.engaged)
        XCTAssertTrue(first.justEngaged)
        let again = gate.update(fingers: zoomFingers, thumbHeight: 0.8)
        XCTAssertTrue(again.engaged)
        XCTAssertFalse(again.justEngaged, "only the transition reports fresh")
    }

    func testTuckedThumbNeverEngages() {
        var gate = ZoomHandGate()
        // Index up, thumb tucked = the "next" command hand, never zoom.
        let decision = gate.update(fingers: zoomFingers, thumbHeight: 0.3)
        XCTAssertFalse(decision.engaged)
        XCTAssertFalse(decision.justEngaged)
    }

    func testHiddenThumbNeverEngages() {
        var gate = ZoomHandGate()
        XCTAssertFalse(gate.update(fingers: zoomFingers, thumbHeight: nil).engaged)
    }

    func testOtherPatternsNeverEngage() {
        // Fist, two/three fingers, palm: a raised thumb must not arm zoom.
        let patterns = [
            [false, false, false, false],
            [true, true, false, false],
            [true, true, true, false],
            [true, true, true, true],
        ]
        for fingers in patterns {
            var gate = ZoomHandGate()
            XCTAssertFalse(
                gate.update(fingers: fingers, thumbHeight: 0.9).engaged,
                "\(fingers) must not engage the zoom gate"
            )
        }
    }

    func testHysteresis() {
        var gate = ZoomHandGate()
        XCTAssertTrue(gate.update(fingers: zoomFingers, thumbHeight: 0.8).engaged)
        XCTAssertTrue(
            gate.update(fingers: zoomFingers, thumbHeight: 0.55).engaged,
            "stays engaged between release and engage heights"
        )
        XCTAssertFalse(gate.update(fingers: zoomFingers, thumbHeight: 0.45).engaged)
        XCTAssertFalse(
            gate.update(fingers: zoomFingers, thumbHeight: 0.55).engaged,
            "no re-engage below the engage height"
        )
    }

    func testMismatchDropsImmediately() {
        var gate = ZoomHandGate()
        _ = gate.update(fingers: zoomFingers, thumbHeight: 0.8)
        XCTAssertFalse(gate.update(fingers: [false, false, false, false], thumbHeight: 0.9).engaged)
        XCTAssertFalse(gate.engaged)
    }

    func testReset() {
        var gate = ZoomHandGate()
        _ = gate.update(fingers: zoomFingers, thumbHeight: 0.8)
        gate.reset()
        XCTAssertFalse(gate.engaged)
    }
}

final class ThumbHeightTests: XCTestCase {
    /// Pose with an approximate thumb height (hand size ≈ 0.352).
    private func heightPose(height: Float, confidence: Float = 0.9) -> HandPose {
        HandPose(
            points: [
                .wrist: SIMD2(0.5, 0.1),
                .middleMCP: SIMD2(0.46, 0.45),
                .thumbTip: SIMD2(0.46 + height * 0.352, 0.45),
            ],
            confidences: [.wrist: confidence, .middleMCP: confidence, .thumbTip: confidence]
        )
    }

    func testThumbHeightValue() {
        XCTAssertEqual(FingerPaintController.thumbHeight(of: heightPose(height: 0.8), minJointConfidence: 0.3) ?? -1, 0.8, accuracy: 0.01)
        XCTAssertEqual(FingerPaintController.thumbHeight(of: heightPose(height: 0.3), minJointConfidence: 0.3) ?? -1, 0.3, accuracy: 0.01)
    }

    func testThumbHeightNilWhenWeakOrMissing() {
        XCTAssertNil(FingerPaintController.thumbHeight(of: heightPose(height: 0.8, confidence: 0.1), minJointConfidence: 0.3))
        XCTAssertNil(FingerPaintController.thumbHeight(of: nil, minJointConfidence: 0.3))
        XCTAssertNil(FingerPaintController.thumbHeight(of: HandPose(), minJointConfidence: 0.3))
    }
}

final class PinchZoomHoldTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    func testHoldFreezesWithoutFiring() {
        var tracker = PinchZoomTracker()
        _ = tracker.update(distance: 0.2, at: start)
        _ = tracker.update(distance: 0.3, at: start.addingTimeInterval(1 / 30))
        for step in 2..<30 {
            let decision = tracker.hold(at: start.addingTimeInterval(Double(step) / 30))
            XCTAssertNil(decision.zoomAction, "frozen signal must never fire")
        }
    }

    func testHoldWithNoSignalIsSilent() {
        var tracker = PinchZoomTracker()
        XCTAssertEqual(tracker.hold(at: start), .none)
    }

    func testResetClearsAnchor() {
        var tracker = PinchZoomTracker()
        _ = tracker.update(distance: 0.2, at: start)
        _ = tracker.update(distance: 0.3, at: start.addingTimeInterval(1 / 30))
        tracker.reset()
        // A gap far from the stale anchor must anchor fresh, not fire.
        let decision = tracker.update(distance: 0.9, at: start.addingTimeInterval(2 / 30))
        XCTAssertNil(decision.zoomAction)
        XCTAssertFalse(decision.suppressStatic)
    }
}

final class BrushStrokeTests: XCTestCase {
    private let brushFingers = [true, true, false, false]

    /// Two-finger pose: brush tip is the midpoint of the two tips.
    private func brushPose(indexTip: SIMD2<Float>, middleTip: SIMD2<Float>, confidence: Float = 0.95) -> HandPose {
        HandPose(
            points: [.indexTip: indexTip, .middleTip: middleTip],
            confidences: [.indexTip: confidence, .middleTip: confidence]
        )
    }

    private func brushedController(fade: TimeInterval = 1.5) -> (FingerPaintController, LayersBox) {
        var config = FingerPaintConfig()
        config.brushFadeDuration = fade
        let paint = FingerPaintController(config: config)
        let box = LayersBox()
        paint.sink = { box.layers.append($0) }
        return (paint, box)
    }

    func testBrushTipIsMidpointOfTwoTips() {
        let tip = FingerPaintController.brushTip(
            of: brushPose(indexTip: SIMD2(0.4, 0.5), middleTip: SIMD2(0.6, 0.5)),
            minJointConfidence: 0.3
        )
        XCTAssertEqual(tip?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(tip?.y ?? -1, 0.5, accuracy: 0.001)
    }

    func testBrushTipNilWhenWeak() {
        XCTAssertNil(FingerPaintController.brushTip(
            of: brushPose(indexTip: SIMD2(0.4, 0.5), middleTip: SIMD2(0.6, 0.5), confidence: 0.1),
            minJointConfidence: 0.3
        ))
        XCTAssertNil(FingerPaintController.brushTip(of: nil, minJointConfidence: 0.3))
    }

    func testBrushEngagesAndDrawsWhileMoving() {
        let (paint, box) = brushedController()
        let fingers = brushFingers
        XCTAssertTrue(paint.updateBrush(pose: brushPose(indexTip: SIMD2(0.4, 0.5), middleTip: SIMD2(0.44, 0.5)), fingers: fingers))
        XCTAssertTrue(paint.updateBrush(pose: brushPose(indexTip: SIMD2(0.5, 0.5), middleTip: SIMD2(0.54, 0.5)), fingers: fingers))
        XCTAssertTrue(paint.updateBrush(pose: brushPose(indexTip: SIMD2(0.6, 0.5), middleTip: SIMD2(0.64, 0.5)), fingers: fingers))
        let strokes = box.layers.last?.brushStrokes ?? []
        XCTAssertEqual(strokes.count, 1)
        XCTAssertGreaterThanOrEqual(strokes.first?.stroke.points.count ?? 0, 3)
        XCTAssertNil(strokes.first?.endedAt, "live stroke has no end date")
        XCTAssertNotNil(box.layers.last?.pointer, "brush pointer aims the stroke")
    }

    func testBrushDrawsVerticallyToo() {
        let (paint, box) = brushedController()
        let fingers = brushFingers
        XCTAssertTrue(paint.updateBrush(pose: brushPose(indexTip: SIMD2(0.5, 0.4), middleTip: SIMD2(0.54, 0.4)), fingers: fingers))
        XCTAssertTrue(paint.updateBrush(pose: brushPose(indexTip: SIMD2(0.5, 0.6), middleTip: SIMD2(0.54, 0.6)), fingers: fingers))
        XCTAssertGreaterThanOrEqual(box.layers.last?.brushStrokes.first?.stroke.points.count ?? 0, 2)
    }

    func testBrushIgnoresOtherPoses() {
        let (paint, box) = brushedController()
        let pose = brushPose(indexTip: SIMD2(0.5, 0.5), middleTip: SIMD2(0.54, 0.5))
        for fingers in [[true, false, false, false], [true, true, true, false], [false, false, false, false], []] {
            XCTAssertFalse(paint.updateBrush(pose: pose, fingers: fingers), "must not engage on \(fingers)")
        }
        XCTAssertTrue(box.layers.allSatisfy { $0.brushStrokes.isEmpty })
    }

    func testBrushAndZoomNeverEngageTogether() {
        var brush = BrushStrokeTracker()
        var gate = ZoomHandGate()
        let tip = SIMD2<Float>(0.5, 0.5)
        let patterns: [[Bool]] = [
            [true, false, false, false], [true, true, false, false],
            [true, true, true, false], [false, false, false, false],
        ]
        for fingers in patterns {
            let brushOn = brush.update(fingers: fingers, tip: tip, smoothing: 0.4) != nil
            let zoomOn = gate.update(fingers: fingers, thumbHeight: 0.8).engaged
            XCTAssertFalse(brushOn && zoomOn, "mutually exclusive on \(fingers)")
        }
    }

    func testEndedStrokeSurvivesDuringFade() {
        let (paint, box) = brushedController()
        XCTAssertTrue(paint.updateBrush(
            pose: brushPose(indexTip: SIMD2(0.5, 0.5), middleTip: SIMD2(0.54, 0.5)), fingers: brushFingers
        ))
        XCTAssertFalse(paint.updateBrush(pose: nil, fingers: []), "hand lost ends the stroke")
        let strokes = box.layers.last?.brushStrokes ?? []
        XCTAssertEqual(strokes.count, 1)
        XCTAssertNotNil(strokes.first?.endedAt, "ended stroke kept while fading")
    }

    func testExpiredStrokeIsPruned() {
        let (paint, box) = brushedController(fade: 0)
        XCTAssertTrue(paint.updateBrush(
            pose: brushPose(indexTip: SIMD2(0.5, 0.5), middleTip: SIMD2(0.54, 0.5)), fingers: brushFingers
        ))
        XCTAssertFalse(paint.updateBrush(pose: nil, fingers: []))
        XCTAssertTrue(box.layers.last?.brushStrokes.isEmpty ?? false, "zero fade prunes on release")
    }

    func testCardSwitchClearsBrush() {
        let (paint, box) = brushedController()
        XCTAssertTrue(paint.updateBrush(
            pose: brushPose(indexTip: SIMD2(0.5, 0.5), middleTip: SIMD2(0.54, 0.5)), fingers: brushFingers
        ))
        paint.setCurrentCard(UUID())
        XCTAssertTrue(box.layers.last?.brushStrokes.isEmpty ?? false, "remnants must not leak onto another card")
    }

    func testBrushEndSnapsWobblyHorizontal() throws {
        let (paint, box) = brushedController()
        // Wobbly horizontal drag, then fingers off.
        for (x, wobble) in [(0.2, 0.0), (0.3, 0.005), (0.4, -0.004), (0.5, 0.003), (0.6, 0.0)] {
            let tip = SIMD2<Float>(Float(x), Float(0.5 + wobble))
            XCTAssertTrue(paint.updateBrush(
                pose: brushPose(indexTip: tip, middleTip: tip + SIMD2(0.04, 0)), fingers: brushFingers
            ))
        }
        let raw = try XCTUnwrap(box.layers.last?.brushStrokes.first)
        XCTAssertNil(raw.endedAt)
        XCTAssertGreaterThan(raw.stroke.points.count, 2, "live stroke keeps raw wobble")
        XCTAssertFalse(paint.updateBrush(pose: nil, fingers: []))
        let snapped = try XCTUnwrap(box.layers.last?.brushStrokes.first)
        XCTAssertNotNil(snapped.endedAt)
        XCTAssertEqual(snapped.stroke.points.count, 2, "snapped line is two endpoints")
        XCTAssertEqual(snapped.stroke.points[0].y, snapped.stroke.points[1].y, accuracy: 0.0001)
        XCTAssertGreaterThan(snapped.stroke.points[1].x - snapped.stroke.points[0].x, 0.1)
    }

    func testBrushEndSnapsLoopToEllipse() throws {
        let (paint, box) = brushedController()
        // Screen circle around (0.5, 0.5): normalized ry is taller.
        for step in 0 ... 12 {
            let angle = Float(step) * 2 * Float.pi / 12
            let tip = SIMD2<Float>(0.5 + 0.1 * cos(angle), 0.5 + 0.1 * Float(16.0 / 9.0) * sin(angle))
            XCTAssertTrue(paint.updateBrush(
                pose: brushPose(indexTip: tip, middleTip: tip + SIMD2(0.04, 0)), fingers: brushFingers
            ))
        }
        XCTAssertFalse(paint.updateBrush(pose: nil, fingers: []))
        let snapped = try XCTUnwrap(box.layers.last?.brushStrokes.first)
        XCTAssertEqual(snapped.stroke.points.count, 48, "sampled ellipse perimeter")
        let xs = snapped.stroke.points.map(\.x), ys = snapped.stroke.points.map(\.y)
        XCTAssertEqual((xs.max() ?? 0) - (xs.min() ?? 0), 0.2, accuracy: 0.06)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), 0.2 * 16 / 9, accuracy: 0.12)
    }

    func testBrushEndKeepsDiagonalFreehand() throws {
        let (paint, box) = brushedController()
        for t in [0.2, 0.3, 0.4, 0.5] {
            let tip = SIMD2<Float>(Float(t), Float(t))
            XCTAssertTrue(paint.updateBrush(
                pose: brushPose(indexTip: tip, middleTip: tip + SIMD2(0.04, 0)), fingers: brushFingers
            ))
        }
        XCTAssertFalse(paint.updateBrush(pose: nil, fingers: []))
        let points = try XCTUnwrap(box.layers.last?.brushStrokes.first?.stroke.points)
        XCTAssertGreaterThan(points.count, 2, "diagonals keep raw points")
    }
}

final class MouseBrushTests: XCTestCase {
    private func mouseController(snapping: Bool = true, fade: TimeInterval = 1.5) -> (FingerPaintController, LayersBox) {
        var config = FingerPaintConfig()
        config.shapeSnapping = snapping
        config.brushFadeDuration = fade
        let paint = FingerPaintController(config: config)
        let box = LayersBox()
        paint.sink = { box.layers.append($0) }
        return (paint, box)
    }

    func testDownMoveUpProducesFadingStroke() throws {
        let (paint, box) = mouseController(snapping: false)
        paint.mouseBrushDown(at: CGPoint(x: 0.2, y: 0.2))
        paint.mouseBrushMoved(to: CGPoint(x: 0.4, y: 0.3))
        paint.mouseBrushMoved(to: CGPoint(x: 0.401, y: 0.301))
        paint.mouseBrushUp()
        let strokes = try XCTUnwrap(box.layers.last?.brushStrokes)
        XCTAssertEqual(strokes.count, 1)
        XCTAssertNotNil(strokes.first?.endedAt, "released stroke is fading")
        XCTAssertEqual(strokes.first?.stroke.points.count, 2, "sub-spacing nudge ignored")
    }

    func testUpSnapsWobblyHorizontal() throws {
        let (paint, box) = mouseController()
        paint.mouseBrushDown(at: CGPoint(x: 0.2, y: 0.5))
        paint.mouseBrushMoved(to: CGPoint(x: 0.4, y: 0.51))
        paint.mouseBrushMoved(to: CGPoint(x: 0.6, y: 0.49))
        paint.mouseBrushMoved(to: CGPoint(x: 0.8, y: 0.5))
        paint.mouseBrushUp()
        let points = try XCTUnwrap(box.layers.last?.brushStrokes.first?.stroke.points)
        XCTAssertEqual(points.count, 2, "snapped line is two endpoints")
        XCTAssertEqual(points.first?.y ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(points.last?.y ?? -1, 0.5, accuracy: 1e-9)
    }

    func testPrunesAfterFade() throws {
        let (paint, box) = mouseController(fade: 0.01)
        paint.mouseBrushDown(at: CGPoint(x: 0.2, y: 0.2))
        paint.mouseBrushUp()
        Thread.sleep(forTimeInterval: 0.05)
        paint.mouseBrushDown(at: CGPoint(x: 0.5, y: 0.5))
        let strokes = try XCTUnwrap(box.layers.last?.brushStrokes)
        XCTAssertEqual(strokes.count, 1, "faded stroke pruned on next press")
        XCTAssertNil(strokes.first?.endedAt, "only the new live stroke remains")
    }

    func testMoveWithoutDownIsNoop() {
        let (paint, box) = mouseController()
        paint.mouseBrushMoved(to: CGPoint(x: 0.5, y: 0.5))
        paint.mouseBrushUp()
        XCTAssertTrue(box.layers.isEmpty, "hover and dry release push nothing")
    }

    func testSurvivesHandParking() throws {
        // Detection pauses park the hand (nil pose) but must not kill a
        // mouse stroke: the mouse is explicit UI input, like buttons.
        let (paint, box) = mouseController()
        paint.mouseBrushDown(at: CGPoint(x: 0.3, y: 0.3))
        _ = paint.updateBrush(pose: nil, fingers: [])
        let strokes = try XCTUnwrap(box.layers.last?.brushStrokes)
        XCTAssertEqual(strokes.count, 1)
        XCTAssertNil(strokes.first?.endedAt, "mouse stroke stays live")
    }

    func testMouseAndHandBrushCoexist() throws {
        let (paint, box) = mouseController()
        let pose = HandPose(
            points: [.indexTip: SIMD2<Float>(0.5, 0.5), .middleTip: SIMD2<Float>(0.54, 0.5)],
            confidences: [.indexTip: 0.95, .middleTip: 0.95]
        )
        XCTAssertTrue(paint.updateBrush(pose: pose, fingers: [true, true, false, false]))
        paint.mouseBrushDown(at: CGPoint(x: 0.2, y: 0.2))
        paint.mouseBrushMoved(to: CGPoint(x: 0.3, y: 0.2))
        let strokes = try XCTUnwrap(box.layers.last?.brushStrokes)
        XCTAssertEqual(strokes.count, 2, "hand and mouse strokes merge into one layer")
        XCTAssertTrue(strokes.allSatisfy { $0.endedAt == nil }, "both stay live")
    }

    func testClearedOnCardSwitch() throws {
        let (paint, box) = mouseController()
        paint.mouseBrushDown(at: CGPoint(x: 0.3, y: 0.3))
        paint.setCurrentCard(UUID())
        XCTAssertTrue(try XCTUnwrap(box.layers.last?.brushStrokes).isEmpty)
    }
}

final class BrushShapeClassifierTests: XCTestCase {
    func testHorizontalWobbleSnaps() throws {
        let points = [0.2, 0.3, 0.4, 0.5, 0.6].enumerated().map { index, x in
            CGPoint(x: x, y: 0.5 + [0.0, 0.004, -0.003, 0.002, 0.0][index])
        }
        let shape = try XCTUnwrap(BrushShapeClassifier.classify(points))
        guard case let .line(from, to) = shape else { return XCTFail("expected line, got \(shape)") }
        XCTAssertEqual(from.y, to.y, accuracy: 0.0001)
        XCTAssertEqual(from.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(from.x, 0.2, accuracy: 0.01)
        XCTAssertEqual(to.x, 0.6, accuracy: 0.01)
    }

    func testVerticalSnaps() throws {
        let points = [0.2, 0.35, 0.5, 0.65].map { CGPoint(x: 0.4, y: $0) }
        let shape = try XCTUnwrap(BrushShapeClassifier.classify(points))
        guard case let .line(from, to) = shape else { return XCTFail("expected line, got \(shape)") }
        XCTAssertEqual(from.x, to.x, accuracy: 0.0001)
        XCTAssertEqual(from.x, 0.4, accuracy: 0.01)
    }

    func testDiagonalStaysFreehand() {
        let points = [0.2, 0.3, 0.4, 0.5, 0.6].map { CGPoint(x: $0, y: $0) }
        XCTAssertNil(BrushShapeClassifier.classify(points))
    }

    func testWobblyLineStaysFreehand() {
        var points: [CGPoint] = []
        for index in 0 ..< 10 {
            points.append(CGPoint(x: 0.2 + Double(index) * 0.04, y: 0.5 + (index % 2 == 0 ? 0.05 : -0.05)))
        }
        XCTAssertNil(BrushShapeClassifier.classify(points), "zigzag is no line")
    }

    func testShortStrokeAndDotsStayFreehand() {
        XCTAssertNil(BrushShapeClassifier.classify([]))
        XCTAssertNil(BrushShapeClassifier.classify([CGPoint(x: 0.5, y: 0.5)]))
        XCTAssertNil(BrushShapeClassifier.classify([CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.51, y: 0.5)]))
    }

    func testScreenCircleFitsEllipse() throws {
        // Screen circle: normalized ry stretched by the frame aspect.
        var points: [CGPoint] = []
        for step in 0 ... 24 {
            let angle = Double(step) * 2 * Double.pi / 24
            points.append(CGPoint(x: 0.5 + 0.1 * cos(angle), y: 0.5 + 0.1 * 16 / 9 * sin(angle)))
        }
        let shape = try XCTUnwrap(BrushShapeClassifier.classify(points))
        guard case let .ellipse(center, rx, ry) = shape else { return XCTFail("expected ellipse, got \(shape)") }
        XCTAssertEqual(center.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(rx, 0.1, accuracy: 0.01)
        XCTAssertEqual(ry, 0.1 * 16 / 9, accuracy: 0.01)
    }

    func testOpenCShapeStaysFreehand() {
        var points: [CGPoint] = []
        for step in 0 ... 18 {
            let angle = Double(step) * 1.5 * Double.pi / 18
            points.append(CGPoint(x: 0.5 + 0.1 * cos(angle), y: 0.5 + 0.1 * 16 / 9 * sin(angle)))
        }
        XCTAssertNil(BrushShapeClassifier.classify(points), "three-quarter arc is no loop")
    }

    func testOutAndBackStaysFreehand() {
        let out = [0.2, 0.3, 0.4, 0.5, 0.6].map { CGPoint(x: $0, y: 0.5) }
        let back = [0.5, 0.4, 0.3, 0.2].map { CGPoint(x: $0, y: 0.5) }
        XCTAssertNil(BrushShapeClassifier.classify(out + back), "retrace is no loop")
    }

    func testTinyLoopStaysFreehand() {
        var points: [CGPoint] = []
        for step in 0 ... 12 {
            let angle = Double(step) * 2 * Double.pi / 12
            points.append(CGPoint(x: 0.5 + 0.01 * cos(angle), y: 0.5 + 0.01 * sin(angle)))
        }
        XCTAssertNil(BrushShapeClassifier.classify(points), "scribble dots don't become ellipses")
    }

    func testSampledLineHasTwoEndpoints() throws {
        let sampled = BrushShapeClassifier.sampledPoints(for: .line(from: CGPoint(x: 0.1, y: 0.2), to: CGPoint(x: 0.3, y: 0.2)))
        XCTAssertEqual(sampled.count, 2)
        XCTAssertEqual(try XCTUnwrap(sampled.first), CGPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(try XCTUnwrap(sampled.last), CGPoint(x: 0.3, y: 0.2))
    }

    func testSampledEllipseHasPerimeterPoints() {
        let sampled = BrushShapeClassifier.sampledPoints(for: .ellipse(center: CGPoint(x: 0.5, y: 0.5), rx: 0.1, ry: 0.2))
        XCTAssertEqual(sampled.count, 48)
        for point in sampled {
            let dx = (point.x - 0.5) / 0.1, dy = (point.y - 0.5) / 0.2
            XCTAssertEqual(dx * dx + dy * dy, 1, accuracy: 0.001)
        }
    }
}

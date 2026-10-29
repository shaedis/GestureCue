import XCTest
@testable import GestureCue

final class GestureStateMachineTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    /// Mechanics config: hold clock disabled so match/debounce/cooldown logic
    /// is tested in isolation (hold + stillness have dedicated tests below).
    private static let fastConfig: GestureStateMachine.Config = {
        var config = GestureStateMachine.Config()
        config.holdDuration = 0
        return config
    }()

    private func frame(
        _ machine: inout GestureStateMachine,
        _ gesture: HandGesture,
        confidence: Float = 0.9,
        anchor: SIMD2<Float>? = nil,
        tips: [SIMD2<Float>?] = [],
        step: Int
    ) -> HandGesture? {
        let classification = Classification(gesture: gesture, confidence: confidence, anchor: anchor, tips: tips)
        return machine.update(classification, at: start.addingTimeInterval(Double(step) / 30))
    }

    // MARK: - Match/debounce/cooldown mechanics (hold clock off)

    func testFiresAfterRequiredStableFrames() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<2 {
            XCTAssertNil(frame(&machine, .openPalm, step: step), "must not fire before 3 stable frames")
        }
        XCTAssertEqual(frame(&machine, .openPalm, step: 2), .openPalm)
    }

    func testMidConfidenceFires() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<2 {
            XCTAssertNil(frame(&machine, .fist, confidence: 0.4, step: step))
        }
        XCTAssertEqual(frame(&machine, .fist, confidence: 0.4, step: 2), .fist, "0.4 clears the 0.35 gate")
    }

    func testLowConfidenceNeverFires() {
        var machine = GestureStateMachine()
        for step in 0..<20 {
            XCTAssertNil(frame(&machine, .fist, confidence: 0.2, step: step))
        }
        XCTAssertEqual(machine.snapshot.candidate, .unknown)
    }

    func testSingleUnknownGapIsTolerated() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<2 {
            XCTAssertNil(frame(&machine, .openPalm, step: step))
        }
        XCTAssertNil(frame(&machine, .unknown, step: 2), "one gap frame is absorbed")
        XCTAssertEqual(frame(&machine, .openPalm, step: 3), .openPalm, "stability count survives the gap")
    }

    func testTwoGapFramesTolerated() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<2 {
            XCTAssertNil(frame(&machine, .indexUp, step: step))
        }
        XCTAssertNil(frame(&machine, .unknown, step: 2))
        XCTAssertNil(frame(&machine, .unknown, step: 3))
        XCTAssertEqual(frame(&machine, .indexUp, step: 4), .indexUp)
    }

    func testThreeUnknownsResetAndRelease() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<3 {
            _ = frame(&machine, .fist, step: step) // fires at step 2
        }
        XCTAssertNil(frame(&machine, .unknown, step: 3))
        XCTAssertNil(frame(&machine, .unknown, step: 4))
        XCTAssertNil(machine.update(nil, at: start.addingTimeInterval(5.0 / 30)), "third gap resets")
        XCTAssertEqual(machine.snapshot.candidate, .unknown)
        // Released: fires again after stability (past cooldown).
        var fired: HandGesture?
        for step in 0..<3 {
            fired = frame(&machine, .fist, step: 60 + step)
        }
        XCTAssertEqual(fired, .fist)
    }

    func testSingleNilDoesNotRearm() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<3 {
            _ = frame(&machine, .fist, step: step) // fires at step 2
        }
        XCTAssertNil(machine.update(nil, at: start.addingTimeInterval(3.0 / 30)), "brief dropout is a gap, not a release")
        for step in 4..<30 {
            XCTAssertNil(frame(&machine, .fist, step: step), "still debounced without a genuine release")
        }
    }

    func testNilMeansNoHandAndRearmsAfterSustainedAbsence() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<3 {
            _ = frame(&machine, .fist, step: step)
        }
        for step in 3..<6 {
            XCTAssertNil(machine.update(nil, at: start.addingTimeInterval(Double(step) / 30)))
        }
        XCTAssertEqual(machine.snapshot.candidate, .unknown)
        var fired: HandGesture?
        for step in 0..<3 {
            fired = frame(&machine, .fist, step: 60 + step)
        }
        XCTAssertEqual(fired, .fist)
    }

    func testRivalFlickerTolerated() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<2 {
            XCTAssertNil(frame(&machine, .openPalm, step: step))
        }
        XCTAssertNil(frame(&machine, .fist, step: 2), "one misclassified frame is absorbed")
        XCTAssertEqual(machine.snapshot.candidate, .openPalm)
        XCTAssertEqual(frame(&machine, .openPalm, step: 3), .openPalm)
    }

    func testSustainedRivalSwitchesCandidate() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<2 {
            XCTAssertNil(frame(&machine, .openPalm, step: step))
        }
        XCTAssertNil(frame(&machine, .fist, step: 2))
        XCTAssertNil(frame(&machine, .fist, step: 3))
        XCTAssertNil(frame(&machine, .fist, step: 4), "third rival frame switches the candidate")
        XCTAssertEqual(machine.snapshot.candidate, .fist)
        XCTAssertEqual(machine.snapshot.progress, 1.0 / 3.0, accuracy: 0.001)
        var fired: HandGesture?
        for step in 5..<7 {
            fired = frame(&machine, .fist, step: step)
        }
        XCTAssertEqual(fired, .fist)
    }

    func testDebounceRequiresRelease() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<3 {
            _ = frame(&machine, .indexUp, step: step)
        }
        for step in 3..<30 {
            XCTAssertNil(frame(&machine, .indexUp, step: step), "holding must not refire")
        }
    }

    func testCooldownBlocksFastGestureSwitch() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<3 {
            _ = frame(&machine, .openPalm, step: step) // fires at step 2 (~0.07s)
        }
        // A different gesture stabilizing inside the 0.5s cooldown must not fire…
        for step in 6..<12 {
            XCTAssertNil(frame(&machine, .fist, step: step))
        }
        // …but fires once the cooldown elapses while still held.
        var fired: HandGesture?
        for step in 12..<45 {
            fired = frame(&machine, .fist, step: step)
            if fired != nil { break }
        }
        XCTAssertEqual(fired, .fist)
    }

    func testProgressTracksMatches() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        XCTAssertEqual(machine.snapshot.progress, 0)
        for step in 0..<2 {
            _ = frame(&machine, .openPalm, step: step)
        }
        XCTAssertEqual(machine.snapshot.candidate, .openPalm)
        XCTAssertEqual(machine.snapshot.progress, 2.0 / 3.0, accuracy: 0.001)
    }

    func testReset() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        for step in 0..<3 {
            _ = frame(&machine, .openPalm, step: step)
        }
        machine.reset()
        XCTAssertEqual(machine.snapshot, GestureStateMachine.Snapshot())
        // Fully rearmed: fires immediately after stability again.
        for step in 100..<102 {
            XCTAssertNil(frame(&machine, .openPalm, step: step))
        }
        XCTAssertEqual(frame(&machine, .openPalm, step: 102), .openPalm)
    }

    // MARK: - Hold-to-fire + stillness (default config)

    func testHoldDurationRequired() {
        var machine = GestureStateMachine()
        let anchor = SIMD2<Float>(0.5, 0.5)
        for step in 0..<15 {
            XCTAssertNil(frame(&machine, .fist, anchor: anchor, step: step), "must not fire before the 0.5s hold")
        }
        var fired: HandGesture?
        for step in 15..<20 {
            fired = frame(&machine, .fist, anchor: anchor, step: step)
            if fired != nil { break }
        }
        XCTAssertEqual(fired, .fist, "fires once the still hold completes")
    }

    func testDefaultHoldDurationIsHalfSecond() {
        XCTAssertEqual(GestureStateMachine.Config().holdDuration, 0.5)
    }

    func testCustomHoldDurationDelaysFiring() {
        var config = GestureStateMachine.Config()
        config.holdDuration = 1.5
        var machine = GestureStateMachine(config: config)
        let anchor = SIMD2<Float>(0.5, 0.5)
        for step in 0..<45 {
            XCTAssertNil(frame(&machine, .fist, anchor: anchor, step: step), "must not fire before the 1.5s hold")
        }
        var fired: HandGesture?
        for step in 45..<50 {
            fired = frame(&machine, .fist, anchor: anchor, step: step)
            if fired != nil { break }
        }
        XCTAssertEqual(fired, .fist, "fires once the configured hold completes")
    }

    func testMotionPreventsFiring() {
        var machine = GestureStateMachine()
        // Same pose, wrist jumping 0.2 (beyond the 0.12 radius): signing-like.
        for step in 0..<100 {
            let anchor = SIMD2<Float>(step.isMultiple(of: 2) ? 0.4 : 0.6, 0.5)
            XCTAssertNil(frame(&machine, .fist, anchor: anchor, step: step), "moving hands must never fire")
        }
    }

    func testSmallDriftTolerated() {
        var machine = GestureStateMachine()
        // Slow creep totaling 0.069: inside the radius, fires after the hold.
        var fired: HandGesture?
        for step in 0..<70 {
            let anchor = SIMD2<Float>(0.5 + Float(step) * 0.001, 0.5)
            fired = frame(&machine, .indexUp, anchor: anchor, step: step)
            if fired != nil { break }
        }
        XCTAssertEqual(fired, .indexUp)
    }

    func testProgressTracksHold() {
        var machine = GestureStateMachine()
        let anchor = SIMD2<Float>(0.5, 0.5)
        for step in 0..<8 {
            _ = frame(&machine, .openPalm, anchor: anchor, step: step)
        }
        XCTAssertEqual(machine.snapshot.candidate, .openPalm)
        XCTAssertEqual(machine.snapshot.progress, 0.5, accuracy: 0.05, "meter fills across the hold")
    }

    // MARK: - Fingertip stillness (shaking fingers must not fire)

    func testShakingFingertipNeverFires() {
        // Signing scenario: steady wrist, oscillating index tip.
        var machine = GestureStateMachine()
        for step in 0..<60 {
            let x: Float = step.isMultiple(of: 2) ? 0.5 : 0.7
            XCTAssertNil(
                frame(&machine, .indexUp, anchor: SIMD2(0.5, 0.1), tips: [SIMD2(x, 0.85), nil, nil, nil], step: step),
                "shaking index must restart the hold (step \(step))"
            )
        }
    }

    func testSteadyFingertipsFire() {
        var machine = GestureStateMachine()
        var fired: HandGesture?
        let tips: [SIMD2<Float>?] = [SIMD2(0.5, 0.85), SIMD2(0.46, 0.42), nil, nil]
        for step in 0..<20 {
            fired = frame(&machine, .indexUp, anchor: SIMD2(0.5, 0.1), tips: tips, step: step) ?? fired
        }
        XCTAssertEqual(fired, .indexUp)
    }

    func testHandSwayWithSteadyFingersFires() {
        // Whole-hand sway inside the wrist radius: relative tip vectors
        // stay constant, so the hold completes.
        var machine = GestureStateMachine()
        var fired: HandGesture?
        for step in 0..<20 {
            let sway = Float(step) * 0.005
            let tips: [SIMD2<Float>?] = [SIMD2(0.5 + sway, 0.85), nil, nil, nil]
            fired = frame(&machine, .indexUp, anchor: SIMD2(0.5 + sway, 0.1), tips: tips, step: step) ?? fired
        }
        XCTAssertEqual(fired, .indexUp)
    }

    func testNewlyVisibleTipIsAdopted() {
        var machine = GestureStateMachine()
        var fired: HandGesture?
        for step in 0..<20 {
            let tips: [SIMD2<Float>?] = step < 5 ? [nil, nil, nil, nil] : [SIMD2(0.5, 0.85), nil, nil, nil]
            fired = frame(&machine, .indexUp, anchor: SIMD2(0.5, 0.1), tips: tips, step: step) ?? fired
        }
        XCTAssertEqual(fired, .indexUp, "a newly seen tip must not restart the hold")
    }

    func testVanishingTipIsSkipped() {
        var machine = GestureStateMachine()
        var fired: HandGesture?
        for step in 0..<20 {
            let tips: [SIMD2<Float>?] = step < 10 ? [SIMD2(0.5, 0.85), nil, nil, nil] : [nil, nil, nil, nil]
            fired = frame(&machine, .indexUp, anchor: SIMD2(0.5, 0.1), tips: tips, step: step) ?? fired
        }
        XCTAssertEqual(fired, .indexUp, "occlusion must not restart the hold")
    }

    func testMissingAnchorSkipsTipCheck() {
        var machine = GestureStateMachine(config: Self.fastConfig)
        XCTAssertNil(frame(&machine, .indexUp, tips: [SIMD2(0.9, 0.9), nil, nil, nil], step: 0))
        XCTAssertNil(frame(&machine, .indexUp, tips: [SIMD2(0.1, 0.1), nil, nil, nil], step: 1))
        XCTAssertEqual(frame(&machine, .indexUp, step: 2), .indexUp)
    }
}

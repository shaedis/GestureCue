import XCTest
@testable import GestureCue

final class HandGestureDetectorTests: XCTestCase {
    func testPaintModePassesPalmFistAndThumbs() {
        for gesture: HandGesture in [.openPalm, .fist, .thumbsUp, .thumbLeft, .thumbRight] {
            let classification = Classification(gesture: gesture, confidence: 0.9, anchor: SIMD2<Float>(0.5, 0.5))
            XCTAssertEqual(HandGestureDetector.allowedInPaintMode(classification), classification)
        }
    }

    func testPaintModeSwallowsIndexFamily() {
        for gesture: HandGesture in [.indexUp, .twoFingersUp, .threeFingersUp, .unknown] {
            let classification = Classification(gesture: gesture, confidence: 0.9, anchor: SIMD2<Float>(0.5, 0.5))
            XCTAssertNil(
                HandGestureDetector.allowedInPaintMode(classification),
                "\(gesture) must never fire cards in Paint Mode"
            )
        }
    }

    func testPaintModeSwallowsMissingHand() {
        XCTAssertNil(HandGestureDetector.allowedInPaintMode(nil))
    }
}

final class ReleaseGateTests: XCTestCase {
    func testOpenGatePassesEverything() {
        var gate = ReleaseGate()
        XCTAssertTrue(gate.pass(.openPalm))
        XCTAssertTrue(gate.pass(nil))
    }

    func testSuppressedGestureBlockedUntilChange() {
        var gate = ReleaseGate()
        gate.suppress(.openPalm)
        XCTAssertFalse(gate.pass(.openPalm))
        XCTAssertFalse(gate.pass(.openPalm), "still-held palm stays blocked")
        XCTAssertTrue(gate.pass(.fist), "changed hand clears and passes")
        XCTAssertTrue(gate.pass(.openPalm), "suppression cleared")
    }

    func testMissingHandClears() {
        var gate = ReleaseGate()
        gate.suppress(.openPalm)
        XCTAssertTrue(gate.pass(nil))
        XCTAssertTrue(gate.pass(.openPalm))
    }

    func testReset() {
        var gate = ReleaseGate()
        gate.suppress(.openPalm)
        gate.reset()
        XCTAssertTrue(gate.pass(.openPalm))
    }
}

final class CommandWindowTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    func testDefaultIdleTimeout() {
        XCTAssertEqual(CommandWindow().idleTimeout, 300)
    }

    func testArmOpensWithFullRemaining() {
        var window = CommandWindow(idleTimeout: 20)
        XCTAssertFalse(window.isOpen)
        XCTAssertEqual(window.remaining(at: start), 0)
        window.arm(at: start)
        XCTAssertTrue(window.isOpen)
        XCTAssertEqual(window.remaining(at: start), 20, accuracy: 0.001)
        XCTAssertEqual(window.remaining(at: start.addingTimeInterval(19)), 1, accuracy: 0.001)
    }

    func testTickExpiresOnce() {
        var window = CommandWindow(idleTimeout: 20)
        window.arm(at: start)
        XCTAssertFalse(window.tick(at: start.addingTimeInterval(19.9)))
        XCTAssertTrue(window.isOpen)
        XCTAssertTrue(window.tick(at: start.addingTimeInterval(20)))
        XCTAssertFalse(window.isOpen)
        XCTAssertFalse(window.tick(at: start.addingTimeInterval(21)), "expiry reports once")
    }

    func testActivityExtends() {
        var window = CommandWindow(idleTimeout: 20)
        window.arm(at: start)
        window.registerActivity(at: start.addingTimeInterval(19))
        XCTAssertTrue(window.isOpen)
        XCTAssertEqual(window.remaining(at: start.addingTimeInterval(19)), 20, accuracy: 0.001)
        XCTAssertFalse(window.tick(at: start.addingTimeInterval(38)))
        XCTAssertTrue(window.tick(at: start.addingTimeInterval(39)))
    }

    func testSustainedActivityNeverExpires() {
        // The latch must survive continuous use: no cap may kill it.
        var window = CommandWindow(idleTimeout: 20)
        window.arm(at: start)
        for step in 1...30 {
            window.registerActivity(at: start.addingTimeInterval(Double(step) * 10))
            XCTAssertFalse(window.tick(at: start.addingTimeInterval(Double(step) * 10)))
        }
        XCTAssertTrue(window.isOpen)
        XCTAssertTrue(window.tick(at: start.addingTimeInterval(320)))
        XCTAssertFalse(window.isOpen)
    }

    func testActivityWhenClosedIsNoOp() {
        var window = CommandWindow(idleTimeout: 20)
        window.registerActivity(at: start)
        XCTAssertFalse(window.isOpen)
        window.arm(at: start)
        window.end()
        XCTAssertFalse(window.isOpen)
        XCTAssertEqual(window.remaining(at: start), 0)
    }
}

final class ArmHoldTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    /// The detector's arming configuration: a still palm held 2 s.
    private func armMachine() -> GestureStateMachine {
        GestureStateMachine(config: .init(holdDuration: 2.0))
    }

    private func frame(_ gesture: HandGesture, anchor: SIMD2<Float> = SIMD2(0.5, 0.5)) -> Classification {
        Classification(gesture: gesture, confidence: 0.9, anchor: anchor)
    }

    private func at(_ step: Int) -> Date {
        start.addingTimeInterval(Double(step) / 30)
    }

    func testStillPalmHoldArms() {
        var machine = armMachine()
        var fires = 0
        for step in 0..<75 {
            if machine.update(frame(.openPalm), at: at(step)) != nil {
                fires += 1
            }
        }
        XCTAssertEqual(fires, 1, "one arming fire per hold")
    }

    func testBriefPalmHoldDoesNotArm() {
        var machine = armMachine()
        for step in 0..<30 {
            XCTAssertNil(machine.update(frame(.openPalm), at: at(step)), "1 s hold must not arm")
        }
    }

    func testSigningChurnNeverArms() {
        var machine = armMachine()
        let churn: [HandGesture] = [.fist, .openPalm, .indexUp, .twoFingersUp, .threeFingersUp, .unknown]
        for step in 0..<180 {
            let anchor = SIMD2<Float>(0.3 + 0.4 * Float(step % 7) / 7, 0.5)
            XCTAssertNil(
                machine.update(frame(churn[step % churn.count], anchor: anchor), at: at(step)),
                "6 s of changing, moving hands must never arm (step \(step))"
            )
        }
    }
}

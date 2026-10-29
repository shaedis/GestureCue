import CoreGraphics
import CoreMedia
import Foundation

/// Analyzes camera frames locally: Vision hand landmarks → geometric
/// classification → temporal stabilization. A `VideoFrameConsumer` on the shared
/// capture pipeline; publishes throttled UI snapshots plus fire-once gesture
/// events. Mutable state is lock-guarded; safe to share across threads.
final class HandGestureDetector: VideoFrameConsumer, @unchecked Sendable {
    /// Throttled per-frame UI state (candidate gesture, stability, landmarks).
    struct Snapshot: Sendable, Equatable {
        var candidate: HandGesture = .unknown
        var progress: Double = 0
        /// Latest frame classification confidence (0...1, 0 when no hand).
        var confidence: Float = 0
        /// Normalized Vision landmark coordinates (origin lower-left) for the overlay.
        var landmarks: [CGPoint] = []
        /// True while a paint stroke is being drawn (paint mode only).
        var painting: Bool = false
        /// One-line classifier diagnosis for on-screen debugging ("no hand" when Vision saw nothing).
        var diagnosis: String = ""
    }

    let snapshots: AsyncStream<Snapshot>
    /// Gestures that newly qualified to fire an action.
    let fired: AsyncStream<HandGesture>
    /// Pinch-zoom steps from presentation-mode finger spreading/pinching.
    let zoomSteps: AsyncStream<CardAction>
    /// Fires when a 2 s still palm hold arms listening (paused only).
    let armed: AsyncStream<Void>
    /// Fires when a 2 s still fist hold ends listening (listening only).
    let disarmed: AsyncStream<Void>

    private let snapshotsContinuation: AsyncStream<Snapshot>.Continuation
    private let firedContinuation: AsyncStream<HandGesture>.Continuation
    private let zoomContinuation: AsyncStream<CardAction>.Continuation
    private let armedContinuation: AsyncStream<Void>.Continuation
    private let disarmedContinuation: AsyncStream<Void>.Continuation
    private let detector: HandPoseDetector
    private let classifier: any GestureClassifier
    private let paint: FingerPaintController
    private let lock = NSLock()
    private var stateMachine: GestureStateMachine
    private var pinchZoom = PinchZoomTracker()
    private var zoomGate = ZoomHandGate()
    /// Signing mode: hands are ignored until a command window opens.
    private var detectionPaused = true
    /// Still-hold clutch (2 s): a palm arms listening, a fist ends it.
    private var clutchMachine = GestureStateMachine(config: .init(holdDuration: 2.0))
    private var releaseGate = ReleaseGate()
    private var lastSnapshotDate = Date.distantPast
    private let snapshotInterval: TimeInterval

    init(
        detector: HandPoseDetector = HandPoseDetector(),
        classifier: any GestureClassifier = GeometricGestureClassifier(),
        stateMachine: GestureStateMachine = GestureStateMachine(),
        paint: FingerPaintController = FingerPaintController(),
        snapshotInterval: TimeInterval = 1 / 12
    ) {
        self.detector = detector
        self.classifier = classifier
        self.stateMachine = stateMachine
        self.paint = paint
        self.snapshotInterval = snapshotInterval
        (snapshots, snapshotsContinuation) = AsyncStream.makeStream(of: Snapshot.self)
        (fired, firedContinuation) = AsyncStream.makeStream(of: HandGesture.self)
        (zoomSteps, zoomContinuation) = AsyncStream.makeStream(of: CardAction.self)
        (armed, armedContinuation) = AsyncStream.makeStream(of: Void.self)
        (disarmed, disarmedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        snapshotsContinuation.finish()
        firedContinuation.finish()
        zoomContinuation.finish()
        armedContinuation.finish()
        disarmedContinuation.finish()
    }

    /// Enables paint mode (index-family card gestures suppressed, fingertip
    /// paints, palm/fist still drive cards) or restores presentation mode.
    /// Resets gesture stability on every switch.
    func setPaintMode(_ enabled: Bool) {
        lock.withLock {
            stateMachine.reset()
            pinchZoom.reset()
            zoomGate.reset()
        }
        paint.setMode(enabled ? .paint : .off)
    }

    /// Sets the command hold-to-fire duration (user-configurable trigger
    /// timing). Resets stability so a mid-hold change can't half-fire. The
    /// 2 s arming clutch is a fixed safety latch and stays untouched.
    func setHoldDuration(_ duration: TimeInterval) {
        lock.withLock {
            stateMachine.config.holdDuration = max(0, duration)
            stateMachine.reset()
        }
    }

    /// Pauses hand-driven input (signing mode): cards, zoom, and paint ignore
    /// the hands; only the 2 s palm hold can arm a command window. Resets all
    /// gesture stability on every switch.
    func setDetectionPaused(_ paused: Bool) {
        lock.withLock {
            detectionPaused = paused
            stateMachine.reset()
            clutchMachine.reset()
            pinchZoom.reset()
            zoomGate.reset()
            releaseGate.reset()
        }
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        let pose = detector.detect(in: sampleBuffer)
        let paused = lock.withLock { detectionPaused }
        // Paused hands are invisible to paint: the stroke commits and the
        // pointer hides, exactly as if the hand had left the frame.
        let painting = paint.handle(paused ? nil : pose)
        let analysis = pose.map { classifier.analyze($0) }
        let classification = analysis?.result
        let brushing = paint.updateBrush(pose: paused ? nil : pose, fingers: paused ? [] : (analysis?.fingers.map(\.extended) ?? []))
        let now = Date()

        lock.lock()
        let engaged: Bool
        let zoomDecision: PinchZoomTracker.Decision
        var didArm = false
        var didDisarm = false
        if paused {
            // Signing mode: everything hand-driven is parked; only the
            // 2 s palm hold starts listening.
            zoomGate.reset()
            zoomDecision = pinchZoom.update(distance: nil, at: now)
            engaged = false
            _ = stateMachine.update(nil, at: now)
            if clutchMachine.update(classification, at: now) == .openPalm {
                // The still-held palm must not fire its own command when
                // the window opens — suppressed until the hand changes.
                releaseGate.suppress(.openPalm)
                didArm = true
            }
        } else if paint.isPaintMode || pose == nil {
            // Paint owns the pinch; a missing hand ends the presentation.
            zoomGate.reset()
            zoomDecision = pinchZoom.update(distance: nil, at: now)
            engaged = false
        } else {
            let gate = zoomGate.update(
                fingers: analysis?.fingers.map(\.extended) ?? [],
                thumbHeight: FingerPaintController.thumbHeight(
                    of: pose, minJointConfidence: pinchZoom.config.minJointConfidence
                )
            )
            engaged = gate.engaged
            if gate.justEngaged {
                // Fresh hand shape, fresh anchor: stale gaps must not fire.
                pinchZoom.reset()
            }
            if engaged {
                if let gap = FingerPaintController.pinchGap(
                    of: pose, minJointConfidence: pinchZoom.config.minJointConfidence
                ) {
                    zoomDecision = pinchZoom.update(distance: gap, at: now)
                } else {
                    zoomDecision = pinchZoom.hold(at: now)
                }
            } else {
                // Command hand: the tracker is frozen, so morphing between
                // static poses can never zoom or disturb the hold clock.
                zoomDecision = pinchZoom.hold(at: now)
            }
        }
        if !paused, clutchMachine.update(classification, at: now) == .fist {
            // A still fist ends listening (fist is unassigned, so the hold
            // itself never fires a card command).
            didDisarm = true
        }
        let firedGesture: HandGesture?
        if paused {
            firedGesture = nil
        } else {
            let gated: Classification?
            if paint.isPaintMode {
                // Paint mode: index-family poses are the painting tools (pointing
                // resembles index-up, pinching resembles static poses), so only
                // palm/fist/thumb poses — which no painting posture resembles — drive cards.
                gated = Self.allowedInPaintMode(classification)
            } else if engaged {
                // The zoom hand owns the frame: it classifies as index-up (the
                // classifier ignores the thumb), so it must never feed the
                // state machine — zooming can never flip cards.
                gated = nil
            } else if brushing {
                // The brush hand owns the frame: two extended fingers classify
                // as a two-finger command, which must never fire from a brush
                // stroke.
                gated = nil
            } else {
                gated = classification
            }
            if releaseGate.pass(classification?.gesture), let gated {
                firedGesture = stateMachine.update(gated, at: now)
            } else {
                firedGesture = stateMachine.update(nil, at: now)
            }
        }
        let machineSnapshot = stateMachine.snapshot
        let shouldSnapshot = firedGesture != nil || now.timeIntervalSince(lastSnapshotDate) >= snapshotInterval
        if shouldSnapshot {
            lastSnapshotDate = now
        }
        lock.unlock()

        if didArm {
            armedContinuation.yield()
        }
        if didDisarm {
            disarmedContinuation.yield()
        }
        if let zoomAction = zoomDecision.zoomAction {
            zoomContinuation.yield(zoomAction)
        }
        if let firedGesture {
            firedContinuation.yield(firedGesture)
        }
        if shouldSnapshot {
            snapshotsContinuation.yield(Snapshot(
                candidate: machineSnapshot.candidate,
                progress: machineSnapshot.progress,
                confidence: classification?.confidence ?? 0,
                landmarks: pose.map(Self.overlayPoints(from:)) ?? [],
                painting: painting,
                diagnosis: Self.diagnosis(for: pose, classifier: classifier, zoomEngaged: engaged, paused: paused)
            ))
        }
    }

    private static func overlayPoints(from pose: HandPose) -> [CGPoint] {
        Joint.allCases.compactMap { joint in
            pose.point(joint).map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        }
    }

    /// Paint Mode gate: palm, fist, and thumb poses drive card actions;
    /// index-family poses are the painting tools and must never fire
    /// cards (pointing safety).
    static func allowedInPaintMode(_ classification: Classification?) -> Classification? {
        guard let classification else { return nil }
        switch classification.gesture {
        case .openPalm, .fist, .thumbsUp, .thumbLeft, .thumbRight: return classification
        default: return nil
        }
    }

    private static func diagnosis(for pose: HandPose?, classifier: any GestureClassifier, zoomEngaged: Bool, paused: Bool) -> String {
        guard let pose else { return "no hand" }
        guard let geometric = classifier as? GeometricGestureClassifier else { return "" }
        let base = geometric.diagnose(pose)
        if paused {
            return base + " PAUSED"
        }
        return zoomEngaged ? base + " ZOOM" : base
    }
}

/// Suppresses one gesture until the hand shows anything else: arming a
/// command window with a held palm must not fire the palm's own command
/// when the window opens. Pure value type; the detector owns one.
struct ReleaseGate: Sendable, Equatable {
    private(set) var suppressed: HandGesture?

    mutating func suppress(_ gesture: HandGesture) {
        suppressed = gesture
    }

    /// True when this frame may feed the state machine. A changed (or
    /// missing) hand clears the suppression.
    mutating func pass(_ gesture: HandGesture?) -> Bool {
        guard let held = suppressed else { return true }
        guard gesture != held else { return false }
        suppressed = nil
        return true
    }

    mutating func reset() {
        suppressed = nil
    }
}

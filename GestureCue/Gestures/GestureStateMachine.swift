import Foundation

/// Temporal filter over per-frame classifications. A gesture fires only after
/// the SAME pose is held with the hand approximately still for `holdDuration`:
/// - `minConfidence` gates noisy frames (below it counts as `.unknown`).
/// - `requiredStableFrames` matching frames arm the candidate.
/// - Every matching frame must also fall within `stillnessRadius` of the
///   run's anchor (wrist position when the run started); a frame that moves
///   beyond it restarts the hold immediately (re-based), so waving or
///   signing can never accumulate a hold. Motion restarts; only
///   classification noise gets gap tolerance.
/// - Extended fingertips must also stay within `tipRadius` of their run
///   anchors, measured relative to the wrist: whole-hand sway is free,
///   but a shaking finger (common in sign language) restarts the hold.
///   Curled and unseen tips are skipped (their estimates wobble), newly
///   seen ones adopted.
/// - Up to `maxToleratedGapFrames` gaps are tolerated; longer unknown runs
///   reset and re-arm (release), longer rival-gesture runs switch candidates.
/// - After firing, the same gesture cannot refire until genuinely released;
///   a *different* gesture must wait out `cooldown`.
/// - Progress tracks the hold clock, so the meter fills across the hold.
/// Frames without position info (`anchor == nil`) skip the stillness check.
struct GestureStateMachine {
    struct Config: Sendable, Equatable {
        var requiredStableFrames: Int = 3
        var minConfidence: Float = 0.35
        var maxToleratedGapFrames: Int = 2
        var cooldown: TimeInterval = 0.5
        /// Normalized-space radius the wrist may wander during a hold.
        var stillnessRadius: Float = 0.12
        /// Wrist-relative radius fingertips may wander during a hold.
        var tipRadius: Float = 0.08
        /// How long the pose must be held (approximately still) before firing.
        var holdDuration: TimeInterval = 0.5
    }

    struct Snapshot: Sendable, Equatable {
        var candidate: HandGesture = .unknown
        /// 0...1 progress toward firing (matches and hold clock combined).
        var progress: Double = 0
    }

    var config: Config
    private(set) var candidate: HandGesture = .unknown
    private var matchCount = 0
    private var gapCount = 0
    private var runAnchor: SIMD2<Float>?
    private var runTipAnchors: [SIMD2<Float>?] = []
    private var runStart: Date?
    private var lastProgress = 0.0
    private var firedGesture: HandGesture?
    private var lastFireDate: Date?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one frame; returns the gesture when it newly qualifies to fire.
    /// Pass `nil` when no hand was detected this frame.
    mutating func update(_ classification: Classification?, at date: Date) -> HandGesture? {
        let gesture: HandGesture
        if let classification, classification.confidence >= config.minConfidence {
            gesture = classification.gesture
        } else {
            gesture = .unknown
        }
        let anchor = classification?.anchor

        if gesture == .unknown {
            guard candidate != .unknown else { return nil }
            gapCount += 1
            if gapCount > config.maxToleratedGapFrames {
                resetRun()
                firedGesture = nil
            } else {
                updateProgress(at: date)
            }
            return nil
        }

        if gesture == candidate {
            let currentTips = Self.relativeTips(classification?.tips ?? [], to: anchor)
            if let ref = runAnchor, let anchor, distance(anchor, ref) > config.stillnessRadius {
                // Same pose, but the hand moved: restart the hold here.
                // (Not a release: firedGesture stays, so moving never re-arms.)
                adopt(gesture: gesture, anchor: anchor, tips: classification?.tips ?? [], at: date)
            } else if Self.tipsMoved(currentTips, from: runTipAnchors, radius: config.tipRadius) {
                // Same pose and steady wrist, but the fingers moved — a
                // shaking fingertip must never complete a hold.
                adopt(gesture: gesture, anchor: anchor, tips: classification?.tips ?? [], at: date)
            } else {
                adoptNewTips(currentTips)
                matchCount += 1
                gapCount = 0
            }
        } else if candidate == .unknown {
            adopt(gesture: gesture, anchor: anchor, tips: classification?.tips ?? [], at: date)
        } else {
            gapCount += 1
            if gapCount > config.maxToleratedGapFrames {
                adopt(gesture: gesture, anchor: anchor, tips: classification?.tips ?? [], at: date)
            } else {
                updateProgress(at: date)
            }
        }

        // Fire only on frames that agree with the candidate.
        guard gesture == candidate else { return nil }
        updateProgress(at: date)
        guard matchCount >= config.requiredStableFrames else { return nil }
        guard heldLongEnough(at: date) else { return nil }
        // Debounce: an already-fired gesture must be released before it can fire again.
        guard firedGesture != gesture else { return nil }
        // Cooldown: switching gestures too fast after a fire is ignored.
        if let lastFireDate, date.timeIntervalSince(lastFireDate) < config.cooldown { return nil }

        firedGesture = gesture
        lastFireDate = date
        return gesture
    }

    var snapshot: Snapshot {
        Snapshot(candidate: candidate, progress: lastProgress)
    }

    mutating func reset() {
        resetRun()
        firedGesture = nil
        lastFireDate = nil
    }

    // MARK: - Private

    private mutating func adopt(gesture: HandGesture, anchor: SIMD2<Float>?, tips: [SIMD2<Float>?], at date: Date) {
        candidate = gesture
        matchCount = 1
        gapCount = 0
        runAnchor = anchor
        runTipAnchors = Self.relativeTips(tips, to: anchor)
        runStart = date
        updateProgress(at: date)
    }

    private mutating func resetRun() {
        candidate = .unknown
        matchCount = 0
        gapCount = 0
        runAnchor = nil
        runTipAnchors = []
        runStart = nil
        lastProgress = 0
    }

    /// Fingertip positions relative to the wrist, so whole-hand translation
    /// cancels out and only finger articulation counts. Empty when the wrist
    /// is missing: such frames skip the tip check entirely.
    private static func relativeTips(_ tips: [SIMD2<Float>?], to anchor: SIMD2<Float>?) -> [SIMD2<Float>?] {
        guard let anchor else { return [] }
        return tips.map { $0.map { $0 - anchor } }
    }

    /// True when any tip seen in both the run anchors and this frame moved
    /// beyond the radius. Tips missing on either side are skipped.
    private static func tipsMoved(_ current: [SIMD2<Float>?], from stored: [SIMD2<Float>?], radius: Float) -> Bool {
        for index in 0..<max(current.count, stored.count) {
            let tip = index < current.count ? current[index] : nil
            let ref = index < stored.count ? stored[index] : nil
            if let tip, let ref, distance(tip, ref) > radius {
                return true
            }
        }
        return false
    }

    /// Adopts newly visible tips into the run anchors without restarting.
    private mutating func adoptNewTips(_ current: [SIMD2<Float>?]) {
        if runTipAnchors.count < current.count {
            runTipAnchors += [SIMD2<Float>?](repeating: nil, count: current.count - runTipAnchors.count)
        }
        for index in current.indices where runTipAnchors[index] == nil {
            runTipAnchors[index] = current[index]
        }
    }

    private func heldLongEnough(at date: Date) -> Bool {
        guard config.holdDuration > 0 else { return true }
        guard let runStart else { return false }
        return date.timeIntervalSince(runStart) >= config.holdDuration
    }

    private mutating func updateProgress(at date: Date) {
        guard candidate != .unknown, config.requiredStableFrames > 0 else {
            lastProgress = 0
            return
        }
        let matchProgress = Double(matchCount) / Double(config.requiredStableFrames)
        let timeProgress: Double
        if let runStart, config.holdDuration > 0 {
            timeProgress = date.timeIntervalSince(runStart) / config.holdDuration
        } else {
            timeProgress = 1
        }
        lastProgress = min(1, min(matchProgress, timeProgress))
    }
}

import CoreGraphics
import Foundation

/// Paint interaction mode. In `.paint`, fingertip tracking and pinch drawing
/// are active; the detector suppresses index-family card gestures so painting
/// can never fire a card action (palm/fist still work).
enum PaintMode: Sendable {
    case off
    case paint
}

struct FingerPaintConfig: Sendable, Equatable {
    /// Pinch distance (thumb-index gap / hand size) below which a stroke starts.
    var pinchActivate: Float = 0.5
    /// Distance above which the stroke ends (hysteresis against `pinchActivate`).
    var pinchRelease: Float = 0.65
    /// Exponential smoothing weight of each new fingertip sample (0...1).
    var smoothing: Float = 0.4
    /// Minimum normalized movement before a stroke point is appended.
    var minSpacing: Float = 0.005
    var minJointConfidence: Float = 0.3
    var maxPointsPerStroke: Int = 1000
    /// Seconds a finished brush stroke takes to fade away.
    var brushFadeDuration: TimeInterval = 1.5
    /// Snap finished two-finger strokes to clean horizontal/vertical
    /// lines and ellipses (resolved back into points, so fading and
    /// rendering need no shape support).
    var shapeSnapping = true
    var shapeConfig = BrushShapeClassifier.Config()
}

/// Tracks the index fingertip and turns thumb+index pinches into freehand
/// paint strokes on the current card. Strokes are stored per card (Undo/Redo/
/// Clear operate on the current card) and pushed as a `PaintLayer` through
/// `sink` whenever the visible layer changes.
///
/// Thread-safe via lock; `sink` is invoked holding the paint lock and must
/// only take the compositor lock (`updatePaint`), establishing a global
/// paint → compositor lock order (the compositor never calls back here).
final class FingerPaintController: @unchecked Sendable {
    private let lock = NSLock()
    private var config: FingerPaintConfig
    private var mode: PaintMode = .off
    private var color: HighlightColor = .yellow
    private var currentCardID: UUID?
    private var strokesByCard: [UUID: [PaintStroke]] = [:]
    private var redoByCard: [UUID: [PaintStroke]] = [:]
    private var activeStroke: PaintStroke?
    private var pinching = false
    private var smoothed: SIMD2<Float>?
    private var brush = BrushStrokeTracker()
    private var brushStrokes: [BrushStroke] = []
    private var mouseBrushStrokes: [BrushStroke] = []
    private var lastPushed = PaintLayer()

    /// Called (on the caller's thread) whenever the visible layer changes.
    var sink: (@Sendable (PaintLayer) -> Void)?

    init(config: FingerPaintConfig = FingerPaintConfig()) {
        self.config = config
    }

    var isPaintMode: Bool {
        lock.withLock { mode == .paint }
    }

    func setMode(_ mode: PaintMode) {
        lock.withLock {
            self.mode = mode
            commitLocked()
            pinching = false
            smoothed = nil
            clearBrushLocked()
            pushLocked()
        }
    }

    /// Applies to the next stroke; the active stroke keeps its color.
    func setColor(_ color: HighlightColor) {
        lock.withLock {
            self.color = color
            pushLocked()
        }
    }

    func setCurrentCard(_ id: UUID?) {
        lock.withLock {
            commitLocked()
            pinching = false
            smoothed = nil
            clearBrushLocked()
            currentCardID = id
            pushLocked()
        }
    }

    func undo() {
        lock.withLock {
            commitLocked()
            guard let id = currentCardID, var strokes = strokesByCard[id], !strokes.isEmpty else { return }
            let stroke = strokes.removeLast()
            strokesByCard[id] = strokes
            redoByCard[id, default: []].append(stroke)
            pushLocked()
        }
    }

    func redo() {
        lock.withLock {
            commitLocked()
            guard let id = currentCardID, var redo = redoByCard[id], !redo.isEmpty else { return }
            let stroke = redo.removeLast()
            redoByCard[id] = redo
            strokesByCard[id, default: []].append(stroke)
            pushLocked()
        }
    }

    /// Destructive: clears committed strokes and the redo stack of the current card.
    func clear() {
        lock.withLock {
            commitLocked()
            guard let id = currentCardID else { return }
            strokesByCard[id] = []
            redoByCard[id] = []
            pushLocked()
        }
    }

    /// Per-frame update on the video queue. Returns true while a stroke is
    /// being drawn. No-op (returns false) unless paint mode is on.
    @discardableResult
    func handle(_ pose: HandPose?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard mode == .paint else { return false }
        guard let pose,
              let tip = pose.point(.indexTip),
              pose.point(.thumbTip) != nil,
              let wrist = pose.point(.wrist),
              let middleMCP = pose.point(.middleMCP),
              pose.confidence(.indexTip) >= config.minJointConfidence,
              pose.confidence(.thumbTip) >= config.minJointConfidence,
              pose.confidence(.wrist) >= config.minJointConfidence,
              pose.confidence(.middleMCP) >= config.minJointConfidence,
              distance(wrist, middleMCP) > 1e-6
        else {
            // Hand lost or unreliable: commit, drop tracking, hide pointer.
            commitLocked()
            pinching = false
            smoothed = nil
            pushLocked()
            return false
        }

        guard let gap = Self.pinchGap(of: pose, minJointConfidence: config.minJointConfidence) else {
            commitLocked()
            pinching = false
            smoothed = nil
            pushLocked()
            return false
        }

        if let current = smoothed {
            smoothed = current + (tip - current) * config.smoothing
        } else {
            smoothed = tip
        }
        guard let fingertip = smoothed else { return false }

        if pinching {
            if gap > config.pinchRelease {
                pinching = false
                commitLocked()
            }
        } else if gap < config.pinchActivate {
            pinching = true
            if let id = currentCardID {
                redoByCard[id] = []
            }
        }

        guard pinching else {
            pushLocked()
            return false
        }
        let point = CGPoint(x: CGFloat(fingertip.x), y: CGFloat(fingertip.y))
        if activeStroke == nil {
            activeStroke = PaintStroke(color: color, points: [point])
        } else if let last = activeStroke?.points.last {
            let moved = hypot(Float(point.x - last.x), Float(point.y - last.y))
            if moved >= config.minSpacing, (activeStroke?.points.count ?? 0) < config.maxPointsPerStroke {
                activeStroke?.points.append(point)
            }
        }
        pushLocked()
        return true
    }

    /// Per-frame two-finger brush update on the video queue. Works in any
    /// mode (paused parks it via a nil pose); returns true while a brush
    /// stroke is live so the detector can suppress the two-finger command
    /// the pose resembles. Finished strokes fade out and are pruned; they
    /// never persist, undo, or survive card switches.
    @discardableResult
    func updateBrush(pose: HandPose?, fingers: [Bool]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let tip = Self.brushTip(of: pose, minJointConfidence: config.minJointConfidence)
        let now = Date()
        if let point = brush.update(fingers: fingers, tip: tip, smoothing: config.smoothing) {
            let cg = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
            if let last = brushStrokes.indices.last, brushStrokes[last].endedAt == nil {
                if let prev = brushStrokes[last].stroke.points.last {
                    let moved = hypot(Float(cg.x - prev.x), Float(cg.y - prev.y))
                    if moved >= config.minSpacing, brushStrokes[last].stroke.points.count < config.maxPointsPerStroke {
                        brushStrokes[last].stroke.points.append(cg)
                    }
                } else {
                    brushStrokes[last].stroke.points.append(cg)
                }
            } else {
                brushStrokes.append(BrushStroke(
                    stroke: PaintStroke(color: color, points: [cg]),
                    endedAt: nil,
                    fadeDuration: config.brushFadeDuration
                ))
            }
        } else if let last = brushStrokes.indices.last, brushStrokes[last].endedAt == nil {
            brushStrokes[last].endedAt = now
            if config.shapeSnapping,
               let shape = BrushShapeClassifier.classify(brushStrokes[last].stroke.points, config: config.shapeConfig)
            {
                brushStrokes[last].stroke.points = BrushShapeClassifier.sampledPoints(for: shape)
            }
        }
        pruneBrushLocked(now: now)
        pushLocked()
        return brush.engaged
    }

    /// Mouse-driven brush stroke on the program monitor: explicit UI
    /// input, so it works even while detection is paused (like buttons
    /// and keys). Shares fade, pruning, and shape-snapping semantics
    /// with the two-finger brush; both can be live at once.
    func mouseBrushDown(at point: CGPoint) {
        lock.withLock {
            let now = Date()
            endMouseBrushLocked(at: now)
            pruneBrushLocked(now: now)
            mouseBrushStrokes.append(BrushStroke(
                stroke: PaintStroke(color: color, points: [point]),
                endedAt: nil,
                fadeDuration: config.brushFadeDuration
            ))
            pushLocked()
        }
    }

    /// Appends to the live mouse stroke; no-op unless the button is down.
    /// Prunes expired strokes, so the layer stays fresh between frames.
    func mouseBrushMoved(to point: CGPoint) {
        lock.withLock {
            let now = Date()
            pruneBrushLocked(now: now)
            guard let last = mouseBrushStrokes.indices.last,
                  mouseBrushStrokes[last].endedAt == nil
            else { return }
            if let prev = mouseBrushStrokes[last].stroke.points.last {
                let moved = hypot(point.x - prev.x, point.y - prev.y)
                guard moved >= CGFloat(config.minSpacing),
                      mouseBrushStrokes[last].stroke.points.count < config.maxPointsPerStroke
                else { return }
            }
            mouseBrushStrokes[last].stroke.points.append(point)
            pushLocked()
        }
    }

    /// Ends the live mouse stroke (snapping it when enabled); no-op
    /// unless the button is down.
    func mouseBrushUp() {
        lock.withLock {
            let now = Date()
            endMouseBrushLocked(at: now)
            pruneBrushLocked(now: now)
            pushLocked()
        }
    }

    // MARK: - Private (lock held)

    /// Brush strokes mark only the currently visible card; fading remnants
    /// must never leak onto another card or mode.
    private func clearBrushLocked() {
        brush.reset()
        brushStrokes = []
        mouseBrushStrokes = []
    }

    private func endMouseBrushLocked(at now: Date) {
        guard let last = mouseBrushStrokes.indices.last,
              mouseBrushStrokes[last].endedAt == nil
        else { return }
        mouseBrushStrokes[last].endedAt = now
        if config.shapeSnapping,
           let shape = BrushShapeClassifier.classify(mouseBrushStrokes[last].stroke.points, config: config.shapeConfig)
        {
            mouseBrushStrokes[last].stroke.points = BrushShapeClassifier.sampledPoints(for: shape)
        }
    }

    private func pruneBrushLocked(now: Date) {
        brushStrokes.removeAll { Self.isFaded($0, at: now) }
        mouseBrushStrokes.removeAll { Self.isFaded($0, at: now) }
    }

    private static func isFaded(_ stroke: BrushStroke, at now: Date) -> Bool {
        guard let ended = stroke.endedAt else { return false }
        return now.timeIntervalSince(ended) >= stroke.fadeDuration
    }

    private func commitLocked() {
        guard let id = currentCardID, let stroke = activeStroke, !stroke.points.isEmpty else {
            activeStroke = nil
            return
        }
        strokesByCard[id, default: []].append(stroke)
        activeStroke = nil
    }

    private func pushLocked() {
        var strokes = currentCardID.flatMap { strokesByCard[$0] } ?? []
        if let active = activeStroke, !active.points.isEmpty {
            strokes.append(active)
        }
        let layer = PaintLayer(
            strokes: strokes,
            brushStrokes: brushStrokes + mouseBrushStrokes,
            pointer: smoothed.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                ?? brush.point.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
            pointerColor: color
        )
        guard layer != lastPushed else { return }
        lastPushed = layer
        sink?(layer)
    }
}

extension FingerPaintController {
    /// Normalized thumb–index gap in hand-size units, or nil when the pinch
    /// joints are missing or weak. Shared by pinch drawing and pinch zoom so
    /// both agree on what the fingers are doing.
    static func pinchGap(of pose: HandPose?, minJointConfidence: Float) -> Float? {
        guard let pose,
              let indexTip = pose.point(.indexTip),
              let thumbTip = pose.point(.thumbTip),
              let wrist = pose.point(.wrist),
              let middleMCP = pose.point(.middleMCP),
              pose.confidence(.indexTip) >= minJointConfidence,
              pose.confidence(.thumbTip) >= minJointConfidence,
              pose.confidence(.wrist) >= minJointConfidence,
              pose.confidence(.middleMCP) >= minJointConfidence
        else { return nil }
        let handSize = distance(wrist, middleMCP)
        guard handSize > 1e-6 else { return nil }
        return distance(indexTip, thumbTip) / handSize
    }

    /// Midpoint of the index and middle tips (the brush point), or nil when
    /// either joint is missing or weak.
    static func brushTip(of pose: HandPose?, minJointConfidence: Float) -> SIMD2<Float>? {
        guard let pose,
              let indexTip = pose.point(.indexTip),
              let middleTip = pose.point(.middleTip),
              pose.confidence(.indexTip) >= minJointConfidence,
              pose.confidence(.middleTip) >= minJointConfidence
        else { return nil }
        return (indexTip + middleTip) / 2
    }

    /// Height of the thumb tip above the palm in hand-size units, or nil
    /// when the joints are missing or weak. A tucked thumb reads low
    /// (≈0.2–0.4), a thumb raised with the index reads high (≈0.7+) — the
    /// mode switch between index commands and pinch zoom.
    static func thumbHeight(of pose: HandPose?, minJointConfidence: Float) -> Float? {
        guard let pose,
              let thumbTip = pose.point(.thumbTip),
              let wrist = pose.point(.wrist),
              let middleMCP = pose.point(.middleMCP),
              pose.confidence(.thumbTip) >= minJointConfidence,
              pose.confidence(.wrist) >= minJointConfidence,
              pose.confidence(.middleMCP) >= minJointConfidence
        else { return nil }
        let handSize = distance(wrist, middleMCP)
        guard handSize > 1e-6 else { return nil }
        return distance(thumbTip, middleMCP) / handSize
    }
}

/// Presentation-mode pinch zoom: sustained thumb–index spreading fires
/// zoom-in steps, closing fires zoom-out steps, and finger motion suppresses
/// static gestures so zooming never flips cards. Pure per-frame tracker;
/// feed nil when the hand is gone.
/// Presentation-mode zoom arming: the zoom hand is index extended, all
/// other fingers curled, thumb raised clear of the palm. It carries the
/// same finger verdicts as index-up — the thumb is the mode switch, so a
/// tucked or hidden thumb always means commands. Hysteresis keeps a
/// half-raised thumb from fluttering the gate; any finger mismatch or a
/// missing thumb drops engagement immediately.
struct ZoomHandGate: Sendable {
    var engageHeight: Float = 0.6
    var releaseHeight: Float = 0.5
    private(set) var engaged = false

    /// Returns (engaged, justEngaged); `fingers` is index..pinky extended flags.
    mutating func update(fingers: [Bool], thumbHeight: Float?) -> (engaged: Bool, justEngaged: Bool) {
        guard fingers == [true, false, false, false], let height = thumbHeight else {
            engaged = false
            return (false, false)
        }
        let threshold = engaged ? releaseHeight : engageHeight
        let now = height >= threshold
        let just = now && !engaged
        engaged = now
        return (now, just)
    }

    mutating func reset() {
        engaged = false
    }
}

/// Two-finger brush engagement (index + middle extended, ring + pinky
/// curled): tracks the smoothed midpoint of the two tips. The middle
/// finger is the discriminator — zoom needs it curled, so brush and zoom
/// can never engage together. Pure per-frame tracker; the controller owns
/// stroke assembly, fading, and pruning.
struct BrushStrokeTracker: Sendable {
    private(set) var engaged = false
    private(set) var point: SIMD2<Float>?

    /// `fingers` is index..pinky extended flags; `tip` the brush point, or
    /// nil when its joints are missing or weak. Returns the smoothed tip
    /// while engaged.
    mutating func update(fingers: [Bool], tip: SIMD2<Float>?, smoothing: Float) -> SIMD2<Float>? {
        guard fingers == [true, true, false, false], let tip else {
            engaged = false
            point = nil
            return nil
        }
        engaged = true
        if let current = point {
            point = current + (tip - current) * smoothing
        } else {
            point = tip
        }
        return point
    }

    mutating func reset() {
        engaged = false
        point = nil
    }
}

struct PinchZoomTracker: Sendable {
    struct Config: Sendable, Equatable {
        /// Normalized gap change per zoom step (~6 steps across a full spread).
        var stepThreshold: Float = 0.15
        /// Per-frame gap change counting as finger motion (above Vision jitter).
        var motionThreshold: Float = 0.02
        /// Static gestures stay suppressed this long after motion stops.
        var suppressAfterMotion: TimeInterval = 0.3
        /// Idle longer than this re-syncs the anchor (no phantom trends).
        var idleResync: TimeInterval = 1.0
        /// Minimum gap between zoom steps (paces deliberate zooms).
        var stepCooldown: TimeInterval = 0.3
        /// Joint gate for the pinch signal (matches paint's gate).
        var minJointConfidence: Float = 0.3
    }

    struct Decision: Sendable, Equatable {
        var zoomAction: CardAction?
        var suppressStatic: Bool
        static let none = Decision(zoomAction: nil, suppressStatic: false)
    }

    var config: Config
    private var anchor: Float?
    private var lastDistance: Float?
    private var lastMotionAt: Date?
    private var lastFireAt: Date?

    init(config: Config = Config()) {
        self.config = config
    }

    mutating func update(distance: Float?, at now: Date) -> Decision {
        guard let distance else {
            reset()
            return .none
        }
        if let last = lastDistance, abs(distance - last) > config.motionThreshold {
            lastMotionAt = now
        } else if lastMotionAt.map({ now.timeIntervalSince($0) > config.idleResync }) ?? true {
            anchor = distance
        }
        if anchor == nil {
            anchor = distance
        }
        var action: CardAction?
        if let anchor, now.timeIntervalSince(lastFireAt ?? .distantPast) >= config.stepCooldown {
            if distance - anchor > config.stepThreshold {
                action = .zoomIn
                self.anchor = distance
                lastFireAt = now
            } else if anchor - distance > config.stepThreshold {
                action = .zoomOut
                self.anchor = distance
                lastFireAt = now
            }
        }
        lastDistance = distance
        let recentlyMoved = lastMotionAt.map { now.timeIntervalSince($0) < config.suppressAfterMotion } ?? false
        let displaced = self.anchor.map { abs(distance - $0) > config.stepThreshold / 2 } ?? false
        return Decision(zoomAction: action, suppressStatic: recentlyMoved || displaced)
    }

    /// Re-feed the last distance (frozen signal): no new evidence, so never
    /// fires; idles toward anchor re-sync exactly like genuine stillness.
    /// With no signal yet this is a no-op reset.
    mutating func hold(at now: Date) -> Decision {
        update(distance: lastDistance, at: now)
    }

    mutating func reset() {
        anchor = nil
        lastDistance = nil
        lastMotionAt = nil
        lastFireAt = nil
    }
}

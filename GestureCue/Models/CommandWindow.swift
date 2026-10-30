import Foundation

/// Latch state for command listening. Signing is the rest state: arming
/// (palm hold, button, L) latches listening ON until something ends it —
/// a fist hold, Stop/L, or the idle backstop. User activity (fired
/// commands, zoom steps, paint/brush strokes) refreshes the idle
/// deadline, so the latch never expires mid-use. Pure value type;
/// the view model ticks it.
struct CommandWindow: Sendable, Equatable {
    /// Idle seconds without user activity before the latch releases itself.
    var idleTimeout: TimeInterval = 300
    private(set) var endsAt: Date? = nil

    var isOpen: Bool { endsAt != nil }

    mutating func arm(at now: Date) {
        endsAt = now.addingTimeInterval(idleTimeout)
    }

    /// User activity pushes the idle deadline out.
    mutating func registerActivity(at now: Date) {
        if isOpen {
            endsAt = now.addingTimeInterval(idleTimeout)
        }
    }

    mutating func end() {
        endsAt = nil
    }

    /// Returns true on the transition to closed (once per arming).
    mutating func tick(at now: Date) -> Bool {
        guard let endsAt, now >= endsAt else { return false }
        self.endsAt = nil
        return true
    }

    func remaining(at now: Date) -> TimeInterval {
        max(0, (endsAt ?? now).timeIntervalSince(now))
    }
}

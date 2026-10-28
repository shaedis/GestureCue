import Foundation

/// Hand gestures recognized by GestureCue.
enum HandGesture: String, CaseIterable, Codable, Sendable, Identifiable {
    case openPalm
    case fist
    case thumbsUp
    case thumbLeft
    case thumbRight
    case indexUp
    case twoFingersUp
    case threeFingersUp
    case unknown

    var id: String { rawValue }

    /// Gestures the user can assign to actions (excludes `.unknown`).
    static var assignable: [HandGesture] { [.openPalm, .fist, .thumbsUp, .thumbLeft, .thumbRight, .indexUp, .twoFingersUp, .threeFingersUp] }

    var displayName: String {
        switch self {
        case .openPalm: "Open Palm"
        case .fist: "Closed Fist"
        case .thumbsUp: "Thumbs Up"
        case .thumbLeft: "Thumb Left"
        case .thumbRight: "Thumb Right"
        case .indexUp: "Index Up"
        case .twoFingersUp: "Two Fingers Up"
        case .threeFingersUp: "Three Fingers Up"
        case .unknown: "Unknown"
        }
    }

    /// SF Symbol for the gesture, when a suitable one exists (verified names only).
    var systemImage: String? {
        switch self {
        case .openPalm: "hand.raised"
        case .fist: nil // No fist symbol exists in SF Symbols; rendered as text.
        case .thumbsUp: "hand.thumbsup"
        case .thumbLeft: nil // No verified sideways-thumb symbol; rendered as text.
        case .thumbRight: nil // No verified sideways-thumb symbol; rendered as text.
        case .indexUp: "hand.point.up"
        case .twoFingersUp: nil // No verified two-finger symbol; rendered as text.
        case .threeFingersUp: nil // No verified three-finger symbol; rendered as text.
        case .unknown: nil
        }
    }
}

/// Actions that gestures (or equivalent mouse/keyboard controls) trigger on cards.
enum CardAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case showCard
    case hideCard
    case nextCard
    case previousCard
    case toggleExpand
    case zoomIn
    case zoomOut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .showCard: "Show Card"
        case .hideCard: "Hide Card"
        case .nextCard: "Next Card"
        case .previousCard: "Previous Card"
        case .toggleExpand: "Expand/Collapse Card"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        }
    }

    var systemImage: String {
        switch self {
        case .showCard: "eye"
        case .hideCard: "eye.slash"
        case .nextCard: "arrow.right.circle"
        case .previousCard: "arrow.left.circle"
        case .toggleExpand: "arrow.up.left.and.arrow.down.right"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        }
    }
}

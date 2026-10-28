import Foundation

/// Maps recognized gestures to card actions. The mapping is user-configurable;
/// gestures without an entry (including `.unknown`) trigger nothing.
struct GestureActionRouter: Sendable, Equatable {
    var mapping: [HandGesture: CardAction]

    static var `default`: GestureActionRouter {
        GestureActionRouter(mapping: [
            .openPalm: .showCard,
            .thumbsUp: .hideCard,
            .thumbRight: .nextCard,
            .thumbLeft: .previousCard,
            .threeFingersUp: .toggleExpand,
        ])
    }

    init(mapping: [HandGesture: CardAction] = GestureActionRouter.default.mapping) {
        self.mapping = mapping
    }

    func action(for gesture: HandGesture) -> CardAction? {
        mapping[gesture]
    }
}

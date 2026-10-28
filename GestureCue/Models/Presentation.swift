import Foundation

/// One named slide deck in the presentation catalog: an ordered set of
/// cards presented (and painted on) as a unit. Card UUIDs are stable
/// across saves so per-card paint strokes survive relaunch.
struct Presentation: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var cards: [PresentationCard]

    init(id: UUID = UUID(), name: String, cards: [PresentationCard] = []) {
        self.id = id
        self.name = name
        self.cards = cards
    }
}

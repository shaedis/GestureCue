import Foundation

/// One named slide deck in the presentation catalog: an ordered set of
/// cards presented (and painted on) as a unit. Card UUIDs are stable
/// across saves so per-card paint strokes survive relaunch.
struct Presentation: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var cards: [PresentationCard]
    /// Catalog collection ("History", "Mathematics", …); nil for legacy
    /// and uncategorized decks. Optional so old files still decode.
    var collection: String? = nil
    /// Set when the AI Studio saves the deck. Optional so old files
    /// still decode (those fall back to prompt sniffing below).
    var studioOrigin: Bool? = nil
    /// Studio's optional user guidance, restored into the instructions
    /// field when the deck returns for adjustment. Nil/blank for legacy
    /// and unguided decks; optional so old files still decode.
    var aiInstructions: String? = nil

    init(id: UUID = UUID(), name: String, cards: [PresentationCard] = [], collection: String? = nil, studioOrigin: Bool? = nil, aiInstructions: String? = nil) {
        self.id = id
        self.name = name
        self.cards = cards
        self.collection = collection
        self.studioOrigin = studioOrigin
        self.aiInstructions = aiInstructions
    }

    /// True for AI Studio decks: explicit save marker, or (for decks
    /// saved before the marker) any illustration prompt, which only
    /// the Studio stamps.
    var isStudioDeck: Bool {
        studioOrigin == true || cards.contains { $0.illustrationPrompt != nil }
    }
}

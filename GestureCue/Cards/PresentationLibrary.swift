import Foundation

/// The presentation catalog: named decks with a selected (active) one.
/// Pure value type; persistence is explicit JSON files (`load`/`save`) so
/// storage stays testable. The catalog always holds at least one deck and
/// always has a valid selection (`validated` repairs both).
struct PresentationLibrary: Codable, Sendable, Equatable {
    var presentations: [Presentation]
    var selectedID: UUID?
    /// Seed revision applied to this catalog (nil = pre-revision file).
    /// Optional so catalogs saved before revisions still decode.
    var seedRevision: Int?

    /// Revision 1: the "Matteus 6" sample deck joins the catalog.
    static let currentSeedRevision = 1

    init(presentations: [Presentation] = [], selectedID: UUID? = nil, seedRevision: Int? = nil) {
        self.presentations = presentations
        self.selectedID = selectedID
        self.seedRevision = seedRevision
    }

    /// Fresh catalog seeded from the bundled sample decks.
    static func seeded() -> PresentationLibrary {
        let deck = Presentation(name: "Sample Deck", cards: PresentationCard.samples)
        let matteus = Presentation.matteus6()
        return PresentationLibrary(
            presentations: [deck, matteus], selectedID: deck.id,
            seedRevision: currentSeedRevision
        )
    }

    /// One-time migration for catalogs saved before a seed revision: appends
    /// missing seed decks without touching the selection. Stamps the revision
    /// so a user-deleted seed deck is never re-added.
    func migrated() -> PresentationLibrary {
        var copy = self
        guard (copy.seedRevision ?? 0) < Self.currentSeedRevision else { return copy }
        if !copy.presentations.contains(where: { $0.name == Presentation.matteus6Name }) {
            copy.presentations.append(Presentation.matteus6())
        }
        copy.seedRevision = Self.currentSeedRevision
        return copy
    }

    var selected: Presentation? {
        guard let selectedID else { return presentations.first }
        return presentations.first(where: { $0.id == selectedID }) ?? presentations.first
    }

    /// Repairs an empty catalog or a dangling selection (e.g. after loading
    /// a hand-edited file).
    func validated() -> PresentationLibrary {
        var copy = self
        if copy.presentations.isEmpty {
            return Self.seeded()
        }
        if copy.selectedID == nil || !copy.presentations.contains(where: { $0.id == copy.selectedID }) {
            copy.selectedID = copy.presentations.first?.id
        }
        return copy
    }

    mutating func select(_ id: UUID) {
        guard presentations.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Adds an untitled deck and selects it.
    @discardableResult
    mutating func addUntitled() -> Presentation {
        var name = "Untitled Deck"
        var number = 1
        while presentations.contains(where: { $0.name == name }) {
            number += 1
            name = "Untitled Deck \(number)"
        }
        let deck = Presentation(name: name)
        presentations.append(deck)
        selectedID = deck.id
        return deck
    }

    mutating func rename(_ id: UUID, name: String) {
        guard let index = presentations.firstIndex(where: { $0.id == id }) else { return }
        presentations[index].name = name
    }

    /// Removes a deck; refuses to remove the last one. Returns the new
    /// selection when the selected deck was removed.
    @discardableResult
    mutating func remove(_ id: UUID) -> UUID? {
        guard presentations.count > 1 else { return nil }
        guard let index = presentations.firstIndex(where: { $0.id == id }) else { return nil }
        presentations.remove(at: index)
        if selectedID == id {
            selectedID = presentations.first?.id
            return selectedID
        }
        return nil
    }

    mutating func updateCards(_ id: UUID, cards: [PresentationCard]) {
        guard let index = presentations.firstIndex(where: { $0.id == id }) else { return }
        presentations[index].cards = cards
    }

    /// Adds an imported deck and selects it.
    mutating func addDeck(_ deck: Presentation) {
        presentations.append(deck)
        selectedID = deck.id
    }

    // MARK: - Persistence

    /// Loads a catalog, or nil when the file is missing or corrupt (the
    /// caller seeds a fresh catalog in that case).
    static func load(from url: URL) -> PresentationLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let library = try? JSONDecoder().decode(PresentationLibrary.self, from: data) else { return nil }
        return library.validated()
    }

    func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

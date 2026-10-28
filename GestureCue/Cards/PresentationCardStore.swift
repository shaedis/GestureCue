import Foundation

/// Holds the card deck, selection, and visibility. Pure value type; advancing
/// wraps around and reveals the card so a "next" gesture always shows feedback.
struct PresentationCardStore: Sendable, Equatable {
    var cards: [PresentationCard]
    var currentIndex: Int = 0
    var isVisible: Bool = false
    /// Fullscreen card in the video; collapsing restores the position preset.
    var isExpanded: Bool = false
    /// Per-card picture zoom (1.0 = fit, up to 4×); session-only, reset on relaunch.
    var zoomScales: [UUID: CGFloat] = [:]

    init(cards: [PresentationCard] = PresentationCard.samples) {
        self.cards = cards
    }

    var currentCard: PresentationCard? {
        guard cards.indices.contains(currentIndex) else { return nil }
        return cards[currentIndex]
    }

    var positionLabel: String {
        guard !cards.isEmpty else { return "No cards" }
        return "\(currentIndex + 1) of \(cards.count)"
    }

    mutating func apply(_ action: CardAction) {
        switch action {
        case .showCard: show()
        case .hideCard: hide()
        case .nextCard: next()
        case .previousCard: previous()
        case .toggleExpand: toggleExpand()
        case .zoomIn: zoomInCurrentCard()
        case .zoomOut: zoomOutCurrentCard()
        }
    }

    mutating func show() {
        isVisible = true
    }

    mutating func hide() {
        isVisible = false
    }

    mutating func next() {
        guard !cards.isEmpty else { return }
        currentIndex = (currentIndex + 1) % cards.count
        isVisible = true
    }

    mutating func previous() {
        guard !cards.isEmpty else { return }
        currentIndex = (currentIndex - 1 + cards.count) % cards.count
        isVisible = true
    }

    mutating func toggleExpand() {
        if !isExpanded { isVisible = true }
        isExpanded.toggle()
    }

    mutating func zoomInCurrentCard() {
        adjustZoomCurrentCard(by: 1.25)
    }

    mutating func zoomOutCurrentCard() {
        adjustZoomCurrentCard(by: 1 / 1.25)
    }

    func zoomScale(for cardID: UUID?) -> CGFloat {
        guard let cardID, let scale = zoomScales[cardID] else { return 1 }
        return scale
    }

    private mutating func adjustZoomCurrentCard(by factor: CGFloat) {
        guard let id = currentCard?.id else { return }
        zoomScales[id] = min(max(zoomScale(for: id) * factor, 1), 4)
    }

    /// Attaches (or with nil, removes) the current card's picture. Paint
    /// strokes are kept: the picture does not change card identity.
    mutating func setCurrentCardImage(_ data: Data?) {
        guard cards.indices.contains(currentIndex) else { return }
        cards[currentIndex].imageData = data
    }

    /// Appends a card and jumps to it.
    mutating func addCard(_ card: PresentationCard) {
        cards.append(card)
        currentIndex = cards.count - 1
    }

    mutating func removeCards(at offsets: IndexSet) {
        cards.remove(atOffsets: offsets)
        currentIndex = min(currentIndex, max(cards.count - 1, 0))
    }

    mutating func updateCard(at index: Int, title: String, message: String, detail: String?) {
        guard cards.indices.contains(index) else { return }
        cards[index].title = title
        cards[index].message = message
        cards[index].detail = detail
    }

    mutating func setCardImage(at index: Int, _ data: Data?) {
        guard cards.indices.contains(index) else { return }
        cards[index].imageData = data
    }
}

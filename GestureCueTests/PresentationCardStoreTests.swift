import XCTest
@testable import GestureCue

final class PresentationCardStoreTests: XCTestCase {
    func testInitialState() {
        let store = PresentationCardStore()
        XCTAssertFalse(store.isVisible)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertEqual(store.currentCard, PresentationCard.samples.first)
        XCTAssertGreaterThanOrEqual(store.cards.count, 3, "milestone 1 needs at least three sample cards")
    }

    func testShowAndHide() {
        var store = PresentationCardStore()
        store.apply(.showCard)
        XCTAssertTrue(store.isVisible)
        store.apply(.hideCard)
        XCTAssertFalse(store.isVisible)
    }

    func testNextAdvancesAndReveals() {
        var store = PresentationCardStore()
        store.apply(.nextCard)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(store.isVisible, "advancing reveals the card so gestures always show feedback")
        XCTAssertEqual(store.currentCard, store.cards[1])
    }

    func testNextWrapsAround() {
        var store = PresentationCardStore()
        store.currentIndex = store.cards.count - 1
        store.apply(.nextCard)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertTrue(store.isVisible)
    }

    func testPreviousGoesBackAndReveals() {
        var store = PresentationCardStore()
        store.apply(.nextCard)
        store.apply(.hideCard)
        store.apply(.previousCard)
        XCTAssertEqual(store.currentIndex, 0)
        XCTAssertTrue(store.isVisible, "going back reveals the card so gestures always show feedback")
    }

    func testPreviousWrapsAround() {
        var store = PresentationCardStore()
        store.apply(.previousCard)
        XCTAssertEqual(store.currentIndex, store.cards.count - 1)
        XCTAssertTrue(store.isVisible)
    }

    func testToggleExpandRevealsAndToggles() {
        var store = PresentationCardStore()
        XCTAssertFalse(store.isExpanded)
        store.apply(.toggleExpand)
        XCTAssertTrue(store.isExpanded)
        XCTAssertTrue(store.isVisible, "expanding reveals the card")
        store.apply(.toggleExpand)
        XCTAssertFalse(store.isExpanded, "same action collapses back")
    }

    func testZoomClamps() {
        var store = PresentationCardStore()
        let id = store.currentCard?.id
        XCTAssertEqual(store.zoomScale(for: id), 1)
        XCTAssertEqual(store.zoomScale(for: nil), 1)
        store.apply(.zoomIn)
        XCTAssertEqual(store.zoomScale(for: id), 1.25, accuracy: 0.001)
        store.apply(.zoomOut)
        XCTAssertEqual(store.zoomScale(for: id), 1, accuracy: 0.001)
        store.apply(.zoomOut)
        XCTAssertEqual(store.zoomScale(for: id), 1, accuracy: 0.001, "zoom out floors at 1×")
        for _ in 0..<10 { store.apply(.zoomIn) }
        XCTAssertEqual(store.zoomScale(for: id), 4, accuracy: 0.001, "zoom in caps at 4×")
    }

    func testZoomIsPerCard() {
        var store = PresentationCardStore()
        let first = store.currentCard?.id
        store.apply(.zoomIn)
        store.apply(.nextCard)
        XCTAssertEqual(store.zoomScale(for: store.currentCard?.id), 1)
        XCTAssertEqual(store.zoomScale(for: first), 1.25, accuracy: 0.001)
    }

    func testPreviousOnEmptyDeckIsSafe() {
        var store = PresentationCardStore(cards: [])
        store.apply(.previousCard)
        XCTAssertNil(store.currentCard)
    }

    func testSetCurrentCardImage() {
        var store = PresentationCardStore()
        store.setCurrentCardImage(Data([1, 2, 3]))
        XCTAssertEqual(store.currentCard?.imageData, Data([1, 2, 3]))
        store.setCurrentCardImage(nil)
        XCTAssertNil(store.currentCard?.imageData)
    }

    func testSampleCardsShipWithPictures() {
        let store = PresentationCardStore()
        XCTAssertGreaterThanOrEqual(store.cards.count, 3)
        for card in store.cards {
            XCTAssertNotNil(card.imageData, "sample card '\(card.title)' should ship with a funny picture")
            XCTAssertGreaterThan(card.imageData?.count ?? 0, 0)
        }
    }

    func testSetCurrentCardImageOnEmptyDeckIsSafe() {
        var store = PresentationCardStore(cards: [])
        store.setCurrentCardImage(Data([1]))
        XCTAssertNil(store.currentCard)
    }

    func testEmptyDeckIsSafe() {
        var store = PresentationCardStore(cards: [])
        store.apply(.nextCard)
        store.apply(.showCard)
        XCTAssertNil(store.currentCard)
        XCTAssertEqual(store.positionLabel, "No cards")
    }

    func testPositionLabel() {
        var store = PresentationCardStore()
        XCTAssertEqual(store.positionLabel, "1 of \(store.cards.count)")
        store.apply(.nextCard)
        XCTAssertEqual(store.positionLabel, "2 of \(store.cards.count)")
    }
}

import CoreGraphics
import XCTest
@testable import GestureCue

final class PresentationLibraryTests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    // MARK: - Catalog CRUD

    func testSeededLibrary() {
        let library = PresentationLibrary.seeded()
        XCTAssertEqual(library.presentations.map(\.name), ["Sample Deck", "Matteus 6"])
        XCTAssertEqual(library.presentations.first?.cards.count, PresentationCard.samples.count)
        XCTAssertEqual(library.selectedID, library.presentations.first?.id)
        XCTAssertEqual(library.selected?.name, "Sample Deck")
    }

    func testMatteusDeckContent() {
        let deck = Presentation.matteus6()
        XCTAssertEqual(deck.name, "Matteus 6")
        XCTAssertEqual(deck.cards.count, 34)
        XCTAssertEqual(deck.cards.map(\.title), (1...34).map { "Matteus 6:\($0)" })
        for card in deck.cards {
            XCTAssertFalse(card.message.isEmpty)
            XCTAssertNil(card.detail, "text-only deck: no detail lines")
            XCTAssertNil(card.imageData, "text-only deck: no pictures")
        }
        XCTAssertTrue(deck.cards.first?.message.hasPrefix("Var noga med") ?? false)
        XCTAssertTrue(deck.cards.last?.message.hasSuffix("egen plåga.") ?? false)
    }

    func testMigrationAddsMatteusOnce() {
        // A pre-revision catalog: only the Sample Deck, no revision stamp.
        let deck = Presentation(name: "Sample Deck", cards: PresentationCard.samples)
        let old = PresentationLibrary(presentations: [deck], selectedID: deck.id)
        let migrated = old.migrated()
        XCTAssertEqual(migrated.presentations.map(\.name), ["Sample Deck", "Matteus 6"])
        XCTAssertEqual(migrated.selectedID, deck.id, "migration keeps the selection")
        XCTAssertEqual(migrated.migrated().presentations.count, 2, "migration is idempotent")
    }

    func testMigrationRespectsDeletion() {
        var library = PresentationLibrary(presentations: [
            Presentation(name: "Sample Deck", cards: PresentationCard.samples)
        ]).migrated()
        let matteusID = library.presentations.first(where: { $0.name == "Matteus 6" })?.id
        XCTAssertNotNil(matteusID)
        library.remove(matteusID!)
        XCTAssertEqual(library.migrated().presentations.map(\.name), ["Sample Deck"])
    }

    func testAddUntitledNumbering() {
        var library = PresentationLibrary.seeded()
        let first = library.addUntitled()
        XCTAssertEqual(first.name, "Untitled Deck")
        XCTAssertEqual(library.selectedID, first.id)
        let second = library.addUntitled()
        XCTAssertEqual(second.name, "Untitled Deck 2")
        XCTAssertEqual(library.selectedID, second.id)
    }

    func testSelectIgnoresUnknownDeck() {
        var library = PresentationLibrary.seeded()
        let before = library.selectedID
        library.select(UUID())
        XCTAssertEqual(library.selectedID, before)
    }

    func testRemoveRefusesLastDeck() {
        let deck = Presentation(name: "Only", cards: [])
        var library = PresentationLibrary(presentations: [deck], selectedID: deck.id)
        let result = library.remove(deck.id)
        XCTAssertNil(result)
        XCTAssertEqual(library.presentations.count, 1)
    }

    func testRemoveReselects() {
        var library = PresentationLibrary.seeded()
        let extra = library.addUntitled()
        XCTAssertEqual(library.selectedID, extra.id)
        let reselected = library.remove(extra.id)
        XCTAssertEqual(reselected, library.presentations.first?.id)
        XCTAssertEqual(library.selected?.name, "Sample Deck")
        // Removing a non-selected deck keeps the selection.
        let other = library.addUntitled()
        library.select(library.presentations[0].id)
        XCTAssertNil(library.remove(other.id))
        XCTAssertEqual(library.selected?.name, "Sample Deck")
    }

    func testUpdateCards() {
        var library = PresentationLibrary.seeded()
        let id = library.presentations[0].id
        let cards = [PresentationCard(title: "A", message: "B")]
        library.updateCards(id, cards: cards)
        XCTAssertEqual(library.selected?.cards, cards)
        library.updateCards(UUID(), cards: [])
        XCTAssertEqual(library.selected?.cards, cards, "unknown deck is a no-op")
    }

    func testAddDeckSelects() {
        var library = PresentationLibrary.seeded()
        let deck = Presentation(name: "Imported", cards: [])
        library.addDeck(deck)
        XCTAssertEqual(library.selectedID, deck.id)
        XCTAssertEqual(library.presentations.count, 3)
    }

    func testValidatedRepairs() {
        let empty = PresentationLibrary(presentations: [], selectedID: nil).validated()
        XCTAssertEqual(empty.presentations.count, 2)
        XCTAssertNotNil(empty.selectedID)
        var library = PresentationLibrary.seeded()
        library.selectedID = UUID()
        XCTAssertEqual(library.validated().selectedID, library.presentations.first?.id)
    }

    // MARK: - Persistence

    func testSaveLoadRoundTrip() throws {
        let cardID = UUID()
        let deckID = UUID()
        let original = PresentationLibrary(
            presentations: [Presentation(
                id: deckID,
                name: "Deck",
                cards: [PresentationCard(
                    id: cardID, title: "T", message: "M", detail: "D",
                    imageData: Data([1, 2, 3, 4])
                )]
            )],
            selectedID: deckID
        )
        let url = workDir.appendingPathComponent("presentations.json")
        try original.save(to: url)
        let loaded = PresentationLibrary.load(from: url)
        XCTAssertEqual(loaded, original)
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(PresentationLibrary.load(from: workDir.appendingPathComponent("nope.json")))
    }

    func testLoadCorruptReturnsNil() throws {
        let url = workDir.appendingPathComponent("broken.json")
        try "not json {{{".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(PresentationLibrary.load(from: url))
    }

    // MARK: - Import

    func testImportPDFFromGeneratedFile() throws {
        let url = workDir.appendingPathComponent("slides.pdf")
        makeTwoPagePDF(at: url)
        let deck = try PresentationImporter().importPDF(at: url)
        XCTAssertEqual(deck.name, "slides")
        XCTAssertEqual(deck.cards.count, 2)
        XCTAssertEqual(deck.cards.map(\.title), ["Slide 1", "Slide 2"])
        for card in deck.cards {
            XCTAssertNotNil(card.imageData)
            XCTAssertGreaterThan(card.imageData?.count ?? 0, 0)
        }
    }

    func testImportPDFMissingThrows() {
        XCTAssertThrowsError(try PresentationImporter().importPDF(at: workDir.appendingPathComponent("nope.pdf"))) { error in
            XCTAssertEqual(error as? PresentationImportError, .unreadableFile)
        }
    }

    func testPowerPointWithoutLibreOfficeThrows() async {
        do {
            _ = try await PresentationImporter().importPowerPoint(
                at: workDir.appendingPathComponent("deck.pptx"), sofficeSearchPaths: []
            )
            XCTFail("expected libreOfficeMissing")
        } catch let error as PresentationImportError {
            XCTAssertEqual(error, .libreOfficeMissing)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSofficeSearch() throws {
        XCTAssertNil(PresentationImporter.sofficeURL(searching: []))
        XCTAssertNil(PresentationImporter.sofficeURL(searching: [workDir.appendingPathComponent("nope").path]))
        let fake = workDir.appendingPathComponent("soffice")
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertNotNil(PresentationImporter.sofficeURL(searching: [fake.path]))
    }

    // MARK: - Helpers

    private func makeTwoPagePDF(at url: URL) {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            XCTFail("cannot create PDF consumer")
            return
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            XCTFail("cannot create PDF context")
            return
        }
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
    }
}

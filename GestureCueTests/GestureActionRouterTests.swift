import XCTest
@testable import GestureCue

final class GestureActionRouterTests: XCTestCase {
    func testDefaultMapping() {
        let router = GestureActionRouter.default
        XCTAssertEqual(router.action(for: .openPalm), .showCard)
        XCTAssertEqual(router.action(for: .thumbsUp), .hideCard)
        XCTAssertEqual(router.action(for: .thumbRight), .nextCard)
        XCTAssertEqual(router.action(for: .thumbLeft), .previousCard)
        XCTAssertNil(router.action(for: .fist), "fist is unassigned by default: too common in signing")
        XCTAssertNil(router.action(for: .indexUp), "index occurs in signing: use thumb-right")
        XCTAssertNil(router.action(for: .twoFingersUp), "two fingers occur in signing: use thumb-left")
        XCTAssertEqual(router.action(for: .threeFingersUp), .toggleExpand)
    }

    func testUnknownNeverMaps() {
        XCTAssertNil(GestureActionRouter.default.action(for: .unknown))
        let router = GestureActionRouter(mapping: [.openPalm: .nextCard])
        XCTAssertNil(router.action(for: .unknown))
    }

    func testCustomMapping() {
        let router = GestureActionRouter(mapping: [
            .openPalm: .nextCard,
            .fist: .showCard,
        ])
        XCTAssertEqual(router.action(for: .openPalm), .nextCard)
        XCTAssertEqual(router.action(for: .fist), .showCard)
        XCTAssertNil(router.action(for: .indexUp), "unmapped gestures trigger nothing")
    }

    func testEmptyMapping() {
        let router = GestureActionRouter(mapping: [:])
        XCTAssertNil(router.action(for: .openPalm))
        XCTAssertNil(router.action(for: .fist))
        XCTAssertNil(router.action(for: .indexUp))
    }
}

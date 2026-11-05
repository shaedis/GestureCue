import Compression
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import XCTest
@testable import GestureCue

/// Canned transport: records requests, replays scripted responses.
/// Keychain is deliberately untested (prompts must never block the suite).
private final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Script {
        var status: Int
        var json: [String: Any]
    }

    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var script = Script(status: 200, json: [:])
    /// FIFO script queue for retry tests; empty falls back to `script`.
    var scripts: [Script] = []
    var failure: Error?

    func post(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        if let failure { throw failure }
        let current = lock.withLock { scripts.isEmpty ? script : scripts.removeFirst() }
        let data = try JSONSerialization.data(withJSONObject: current.json)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: current.status,
            httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }

    func lastBody() -> [String: Any]? {
        guard let body = lock.withLock({ requests.last?.httpBody }) else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

final class MetaModelClientTests: XCTestCase {
    private let planJSON = """
        {"lessonTitle": "Fractions", "cards": [
          {"title": "What is a fraction?", "concept": "Parts of a whole",
           "body": "A fraction names equal parts.", "labels": ["numerator", "denominator"],
           "illustrationPrompt": "A pie cut into slices",
           "diagram": {"kind": "fractionCircle", "caption": "One half",
                       "numbers": [1, 2], "labels": ["1/2"]},
           "sourceReference": "Ch. 3", "presenterNotes": "Point at the slices"}
        ]}
        """

    private func chatScript(content: String) -> MockTransport.Script {
        MockTransport.Script(status: 200, json: [
            "choices": [["message": ["content": content]]],
        ])
    }

    private func client(_ transport: MockTransport, key: String = "test-key") -> MetaModelClient {
        MetaModelClient(baseURL: URL(string: "https://example.test/v1")!, apiKey: key, transport: transport)
    }

    func testPlanLessonPostsChatRequest() async throws {
        let transport = MockTransport()
        transport.script = chatScript(content: planJSON)
        let settings = GenerationSettings(subject: .mathematics, language: "Swedish")
        let plan = try await client(transport).planLesson(source: "fractions text", settings: settings, fidelity: .creative)
        XCTAssertEqual(plan.lessonTitle, "Fractions")
        XCTAssertEqual(plan.cards.count, 1)
        XCTAssertEqual(plan.cards.first?.diagram?.kind, "fractionCircle")

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(transport.lastBody())
        XCTAssertEqual(body["model"] as? String, "muse-spark-1.3")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1]["content"], "fractions text")
        XCTAssertTrue(messages[0]["content"]?.contains("Swedish") ?? false)
    }

    func testPlanLessonStripsFences() async throws {
        let transport = MockTransport()
        transport.script = chatScript(content: "```json\n\(planJSON)\n```")
        let plan = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
        XCTAssertEqual(plan.cards.count, 1)
    }

    func testPlanLessonRejectsGarbage() async throws {
        let transport = MockTransport()
        transport.script = chatScript(content: "not json at all")
        do {
            _ = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
            XCTFail("expected invalidResponse")
        } catch let error as GenerationError {
            guard case .invalidResponse = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testPlanLessonMapsHTTPError() async throws {
        let transport = MockTransport()
        transport.script = MockTransport.Script(status: 401, json: ["error": "bad key"])
        do {
            _ = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
            XCTFail("expected httpStatus")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .httpStatus(code: 401, body: "{\"error\":\"bad key\"}"))
        }
    }

    func testCancellationPassesThroughUnwrapped() async {
        let transport = MockTransport()
        transport.failure = CancellationError()
        do {
            _ = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // Callers report cancellation distinctly from network failures.
        } catch {
            XCTFail("cancellation must not wrap as \(error)")
        }
    }

    func testMissingKeyNeverHitsNetwork() async {
        let transport = MockTransport()
        transport.script = chatScript(content: planJSON)
        do {
            _ = try await client(transport, key: "").planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
            XCTFail("expected missingAPIKey")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testGenerateImagePostsAndDecodes() async throws {
        let transport = MockTransport()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic
        transport.script = MockTransport.Script(status: 200, json: [
            "data": [["b64_json": bytes.base64EncodedString()]],
        ])
        let data = try await client(transport).generateImage(prompt: "a pie", style: "flat vector")
        XCTAssertEqual(data, bytes)
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/v1/images/generations")
        let body = try XCTUnwrap(transport.lastBody())
        XCTAssertEqual(body["model"] as? String, "muse-image-1.0")
        XCTAssertTrue((body["prompt"] as? String)?.contains("flat vector") ?? false)
    }

    func testGenerateImageRejectsBadPayload() async {
        let transport = MockTransport()
        transport.script = MockTransport.Script(status: 200, json: ["data": [["b64_json": "!!!not-base64"]]])
        do {
            _ = try await client(transport).generateImage(prompt: "x", style: "y")
            XCTFail("expected imageDecodingFailed")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .imageDecodingFailed)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSystemPromptCarriesSettingsAndRules() {
        var settings = GenerationSettings()
        settings.audience = .deafChildren
        settings.style = .timeline
        let prompt = MetaModelClient.systemPrompt(settings: settings)
        XCTAssertTrue(prompt.contains("Deaf and hard-of-hearing children"))
        XCTAssertTrue(prompt.contains("timeline"))
        XCTAssertTrue(prompt.contains("Never invent facts"))
        XCTAssertTrue(prompt.contains("diagram spec"))
        XCTAssertTrue(prompt.contains("exactly 5 cards"))
        XCTAssertTrue(prompt.contains("fractionCircle"))
        XCTAssertTrue(prompt.contains("Never invent other kinds"))
        XCTAssertTrue(prompt.contains("220 characters"))
        XCTAssertTrue(prompt.contains("consecutive cards"))
        XCTAssertTrue(prompt.contains("stand alone"))
        XCTAssertTrue(prompt.contains("nothing essential near the edges"))
    }

    func testFaithfulPromptInstructsVerbatimSplit() {
        let prompt = MetaModelClient.systemPrompt(settings: GenerationSettings(), fidelity: .faithful)
        XCTAssertTrue(prompt.contains("splitting and layout task, NOT a creative one"))
        XCTAssertTrue(prompt.contains("quote or\nnear-quote") || prompt.contains("quote or near-quote"))
        XCTAssertTrue(prompt.contains("Never invent facts"))
        XCTAssertTrue(prompt.contains("illustrationPrompt MUST be an empty string"))
        XCTAssertTrue(prompt.contains("diagram MUST be"))
        XCTAssertTrue(prompt.contains("220 characters"))
        XCTAssertFalse(prompt.contains("diagram spec"), "faithful mode offers no diagram catalog")
        XCTAssertFalse(prompt.contains("fractionCircle"))
        XCTAssertFalse(prompt.contains("nothing essential near the edges"))
    }

    func testFaithfulPlanPostsLowerTemperature() async throws {
        let transport = MockTransport()
        transport.script = chatScript(content: planJSON)
        _ = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .faithful)
        let body = try XCTUnwrap(transport.lastBody())
        XCTAssertEqual(body["temperature"] as? Double, 0.1)
        XCTAssertTrue((body["messages"] as? [[String: String]])?.first?["content"]?.contains("NOT a creative one") ?? false)
    }

    func testPlanSchemaStructure() {
        let schema = MetaModelClient.planSchema(cardCount: 4)
        let cards = ((schema["properties"] as? [String: Any])?["cards"] as? [String: Any])
        XCTAssertEqual(cards?["minItems"] as? Int, 4)
        XCTAssertEqual(cards?["maxItems"] as? Int, 4)
        let props = ((cards?["items"] as? [String: Any])?["properties"] as? [String: Any])
        let diagram = props?["diagram"] as? [String: Any]
        let kinds = ((diagram?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(kinds, ["fractionCircle", "numberLine", "timeline", "causeEffect"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = schema["required"] as? [String]
        XCTAssertEqual(required, ["lessonTitle", "cards"])
        let refs = props?["imageRefs"] as? [String: Any]
        XCTAssertEqual(refs?["type"] as? String, "array")
        XCTAssertEqual((refs?["items"] as? [String: Any])?["type"] as? String, "integer")
        let cardRequired = ((cards?["items"] as? [String: Any])?["required"] as? [String]) ?? []
        XCTAssertTrue(cardRequired.contains("imageRefs"))
    }

    func testFaithfulPromptNamesImageRefs() {
        let prompt = MetaModelClient.systemPrompt(settings: GenerationSettings(), fidelity: .faithful)
        XCTAssertTrue(prompt.contains("imageRefs"))
        XCTAssertTrue(prompt.contains("[Image N]"))
    }

    func testCreativePromptNamesImageMarkers() {
        let prompt = MetaModelClient.systemPrompt(settings: GenerationSettings(), fidelity: .creative)
        XCTAssertTrue(prompt.contains("imageRefs"))
    }

    func testBlankInstructionsLeavePromptUnchanged() {
        let settings = GenerationSettings()
        let plain = MetaModelClient.systemPrompt(settings: settings, fidelity: .creative)
        XCTAssertEqual(MetaModelClient.systemPrompt(settings: settings, fidelity: .creative, instructions: ""), plain)
        XCTAssertEqual(MetaModelClient.systemPrompt(settings: settings, fidelity: .creative, instructions: "  \n "), plain)
        let faithful = MetaModelClient.systemPrompt(settings: settings, fidelity: .faithful)
        XCTAssertEqual(MetaModelClient.systemPrompt(settings: settings, fidelity: .faithful, instructions: ""), faithful)
        // Pin rule fragments so future edits can't silently drop them.
        XCTAssertTrue(plain.contains("numberLine"))
        XCTAssertTrue(plain.contains("[fraction text]"))
        XCTAssertTrue(faithful.contains("NOT a creative one"))
    }

    func testInstructionsTravelSeparatelyAndSubordinated() async throws {
        let transport = MockTransport()
        transport.script = chatScript(content: planJSON)
        var settings = GenerationSettings()
        settings.cardCount = 4
        _ = try await client(transport).planLesson(
            source: "source text", settings: settings, fidelity: .creative, instructions: "Use timelines."
        )
        let body = try XCTUnwrap(transport.lastBody())
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[1]["content"], "source text", "user message carries the source only")
        let system = try XCTUnwrap(messages[0]["content"])
        XCTAssertTrue(system.contains("User instructions"))
        XCTAssertTrue(system.contains("Use timelines."))
        XCTAssertTrue(system.contains("never override source accuracy"))
        XCTAssertTrue(system.contains("4-card count"), "explicit card count wins over guidance")
        // The strict schema still enforces the app's count, not the prose.
        let named = try XCTUnwrap((body["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        let cards = (((named["schema"] as? [String: Any])?["properties"] as? [String: Any])?["cards"] as? [String: Any])
        XCTAssertEqual(cards?["minItems"] as? Int, 4)
        XCTAssertEqual(cards?["maxItems"] as? Int, 4)
    }

    func testAdultAudiencesGetAdultProseRule() {
        for audience in [AIAudience.deafAdults, .generalAdults] {
            var settings = GenerationSettings()
            settings.audience = audience
            let prompt = MetaModelClient.systemPrompt(settings: settings, fidelity: .creative)
            XCTAssertTrue(prompt.contains("write adult prose"), "\(audience)")
            XCTAssertTrue(prompt.contains("Never define common knowledge"), "\(audience)")
        }
        for audience in [AIAudience.deafChildren, .children, .custom] {
            var settings = GenerationSettings()
            settings.audience = audience
            let prompt = MetaModelClient.systemPrompt(settings: settings, fidelity: .creative)
            XCTAssertFalse(prompt.contains("write adult prose"), "\(audience) keeps simple words")
        }
        // Faithful quotes the source either way: no creative prose rule.
        var faithful = GenerationSettings()
        faithful.audience = .deafAdults
        XCTAssertFalse(MetaModelClient.systemPrompt(settings: faithful, fidelity: .faithful).contains("write adult prose"))
    }

    func testBeginnerRespectsGeneralKnowledge() {
        XCTAssertFalse(AIEducationLevel.beginner.promptHint.contains("define every term"))
        XCTAssertTrue(AIEducationLevel.beginner.promptHint.contains("never define common terms"))
        XCTAssertTrue(AIAudience.deafAdults.promptHint.contains("never condescending"))
        XCTAssertTrue(AIAudience.deafChildren.promptHint.contains("simple sentences"), "children unchanged")
    }

    func testFaithfulInstructionsCannotRewrite() {
        let prompt = MetaModelClient.systemPrompt(
            settings: GenerationSettings(), fidelity: .faithful, instructions: "Make it fun."
        )
        XCTAssertTrue(prompt.contains("Make it fun."))
        XCTAssertTrue(prompt.contains("still quote the source"))
        XCTAssertTrue(prompt.contains("never authorize rewriting"))
        XCTAssertTrue(prompt.contains("illustrationPrompt MUST be an empty string"))
    }

    func testDecodePlanReadsImageRefs() throws {
        let json = """
            {"lessonTitle": "T", "cards": [
              {"title": "A", "concept": "", "body": "B", "labels": [],
               "illustrationPrompt": "", "diagram": null, "imageRefs": [2, 1]},
              {"title": "B", "concept": "", "body": "C", "labels": [],
               "illustrationPrompt": "P", "diagram": null}
            ]}
            """
        let plan = try MetaModelClient.decodePlan(from: json)
        XCTAssertEqual(plan.cards[0].imageRefs, [2, 1])
        XCTAssertEqual(plan.cards[1].imageRefs, [], "missing refs decode leniently")
    }

    func testPlanPostsStrictSchema() async throws {
        let transport = MockTransport()
        transport.script = chatScript(content: planJSON)
        var settings = GenerationSettings()
        settings.cardCount = 3
        _ = try await client(transport).planLesson(source: "x", settings: settings, fidelity: .creative)
        let body = try XCTUnwrap(transport.lastBody())
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let named = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(named["strict"] as? Bool, true)
        let schemaCards = (((named["schema"] as? [String: Any])?["properties"] as? [String: Any])?["cards"] as? [String: Any])
        XCTAssertEqual(schemaCards?["minItems"] as? Int, 3)
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.timeoutInterval, MetaModelClient.planTimeout)
    }

    func testImageTimeoutSet() async throws {
        let transport = MockTransport()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        transport.script = MockTransport.Script(status: 200, json: ["data": [["b64_json": bytes.base64EncodedString()]]])
        _ = try await client(transport).generateImage(prompt: "p", style: "s")
        XCTAssertEqual(transport.requests.last?.timeoutInterval, MetaModelClient.imageTimeout)
    }

    func testRetryAfterRateLimitThenSucceeds() async throws {
        let transport = MockTransport()
        transport.scripts = [
            MockTransport.Script(status: 429, json: ["error": "slow down"]),
            chatScript(content: planJSON),
        ]
        let plan = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
        XCTAssertEqual(plan.cards.count, 1)
        XCTAssertEqual(transport.requests.count, 2, "one retry after 429")
    }

    func testRetryExhaustedSurfacesRealStatus() async {
        let transport = MockTransport()
        transport.scripts = [
            MockTransport.Script(status: 503, json: ["error": "a"]),
            MockTransport.Script(status: 503, json: ["error": "b"]),
        ]
        do {
            _ = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
            XCTFail("expected httpStatus")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .httpStatus(code: 503, body: "{\"error\":\"b\"}"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 2, "exactly one retry")
    }

    func testNoRetryOnClientError() async {
        let transport = MockTransport()
        transport.script = MockTransport.Script(status: 400, json: ["error": "bad"])
        do {
            _ = try await client(transport).planLesson(source: "x", settings: GenerationSettings(), fidelity: .creative)
            XCTFail("expected httpStatus")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .httpStatus(code: 400, body: "{\"error\":\"bad\"}"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(transport.requests.count, 1, "client errors never retry")
    }

    func testStatusMessages() {
        XCTAssertTrue(GenerationError.httpStatus(code: 429, body: nil).localizedDescription.contains("rate-limiting"))
        XCTAssertTrue(GenerationError.httpStatus(code: 503, body: nil).localizedDescription.contains("server error"))
        XCTAssertTrue(GenerationError.httpStatus(code: 401, body: nil).localizedDescription.contains("rejected the key"))
    }

    func testSuggestCollectionPostsAndParses() async throws {
        let transport = MockTransport()
        transport.script = chatScript(content: "{\"collection\":\"  Space Travel \"}")
        let name = try await client(transport).suggestCollection(title: "T", excerpt: "rockets", collections: ["History"])
        XCTAssertEqual(name, "Space Travel", "suggestion is trimmed")
        let body = try XCTUnwrap(transport.lastBody())
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages.first?["content"]?.contains("History") ?? false)
        XCTAssertTrue(messages.last?["content"]?.contains("rockets") ?? false)
    }

    func testSuggestCollectionRejectsEmpty() async {
        let transport = MockTransport()
        transport.script = chatScript(content: "{\"collection\":\"   \"}")
        do {
            _ = try await client(transport).suggestCollection(title: "T", excerpt: "x", collections: [])
            XCTFail("expected invalidResponse")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .invalidResponse("Collection suggestion is not {\"collection\": string}"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCollectionCatalogResolves() {
        var catalog = CollectionCatalog()
        let known = catalog.resolve("history")
        XCTAssertEqual(known.name, "History", "case-insensitive canonical match")
        XCTAssertFalse(known.isNew)
        XCTAssertFalse(catalog.resolve("Bible").isNew)
        let fresh = catalog.resolve(" Space Travel ")
        XCTAssertEqual(fresh.name, "Space Travel")
        XCTAssertTrue(fresh.isNew)
        XCTAssertEqual(catalog.resolve("   ").name, "")
        catalog.addCustom("Space Travel")
        XCTAssertTrue(catalog.all.contains("Space Travel"))
        let again = catalog.resolve("space travel")
        XCTAssertEqual(again.name, "Space Travel", "customs match too")
        XCTAssertFalse(again.isNew)
        catalog.addCustom("SPACE TRAVEL")
        XCTAssertEqual(catalog.custom.count, 1, "no duplicate buckets")
    }

    func testSettingsRoundTrip() throws {
        var settings = GenerationSettings()
        settings.audience = .custom
        settings.audienceCustom = "Evening class"
        settings.cardCount = 99
        XCTAssertEqual(settings.clampedCardCount, 30)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(GenerationSettings.self, from: data), settings)
    }
}

final class CredentialStoreTests: XCTestCase {
    func testInMemoryRoundTrip() {
        let store = InMemoryCredentialStore()
        XCTAssertNil(store.apiKey())
        store.setAPIKey("secret")
        XCTAssertEqual(store.apiKey(), "secret")
        store.setAPIKey(nil)
        XCTAssertNil(store.apiKey())
    }
}

// MARK: - Image fixtures

/// 64×48 solid PNG for composer/renderer/generator tests.
private func tinyPNG(red: CGFloat = 1, green: CGFloat = 0, blue: CGFloat = 0) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(
        data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: bitmapInfo
    ) else { return nil }
    ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

private func decodedSize(_ data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return CGSize(width: width, height: height)
}

final class SourceImporterTests: XCTestCase {
    private let importer = SourceImporter()

    private func tempFile(named name: String, contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(URL(fileURLWithPath: name).pathExtension)
        try contents.write(to: url)
        return url
    }

    func testTextFile() throws {
        let url = try tempFile(named: "lesson.md", contents: Data("# Fractions\nHalf of a pie.".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try importer.importFile(at: url)
        XCTAssertEqual(source.title, url.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(source.text.contains("Fractions"))
        XCTAssertFalse(source.truncated)
    }

    func testNotebookJoinsCellsAsData() throws {
        let json = """
            {"cells": [
              {"cell_type": "markdown", "source": ["# Title\\n", "Intro."]},
              {"cell_type": "code", "source": "x = 1 + 1"},
              {"cell_type": "raw", "source": "ignored"}
            ]}
            """
        let url = try tempFile(named: "nb.ipynb", contents: Data(json.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try importer.importFile(at: url)
        XCTAssertTrue(source.text.contains("## Cell 1 (markdown)"))
        XCTAssertTrue(source.text.contains("Intro."))
        XCTAssertTrue(source.text.contains("## Cell 2 (code)"))
        XCTAssertTrue(source.text.contains("x = 1 + 1"))
        XCTAssertFalse(source.text.contains("ignored"))
    }

    func testNotebookRejectsGarbage() throws {
        let url = try tempFile(named: "bad.ipynb", contents: Data("not json".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try importer.importFile(at: url))
    }

    func testUnsupportedType() throws {
        let url = try tempFile(named: "deck.key", contents: Data([0, 1, 2]))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try importer.importFile(at: url)) { error in
            XCTAssertEqual(error as? SourceImporter.ImportError, .unsupportedType(".key"))
        }
    }

    func testLegacyPowerPointPointsToPptx() throws {
        let url = try tempFile(named: "old.ppt", contents: Data([0xD0, 0xCF, 0x11, 0xE0]))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try importer.importFile(at: url)) { error in
            XCTAssertEqual(
                (error as? SourceImporter.ImportError)?.localizedDescription.contains(".pptx"),
                true
            )
        }
    }

    func testPowerPointExtractsSlidesInOrder() throws {
        // Minimal 2.5-slide deck (slide 3 empty, plus a master that must
        // be ignored), deflated like real PowerPoint output.
        let blob = "UEsDBBQAAAAIAEJWXl1O5n7rrQAAAEIBAAAVAAAAcHB0L3NsaWRlcy9zbGlkZTEueG1sjZA7DsIwDIavEvUAdcXAEIUODFyAXiA0bhspDysxotyehoIqBAPL5/jx27+iSGZnxOxdyFIfqomZJEDuJ/Q615EwLL0hJq95SdMIJumbDaN3sGuaPXhtQ/XS0z96SpgxsGYbw8eSVpHsz86UmKlLiOurkOdjNPdWaUkFqYDbk7Y8DVcnOssOFZRaYXqSvsZtyiyyswbFZVknGGeuf8hgOwirA9gswdslPL+ufQBQSwMEFAAAAAgAQlZeXSKVEOO0AAAASwEAABUAAABwcHQvc2xpZGVzL3NsaWRlMi54bWyNkLsOwjAMRX8lYmCsoQNDKB0YEDv8gJUEGikPK7YE/D1NASEQA8tx/Lj2VTrSHKy6xpBY42Y2iJAGYDO4iNxkcmnsnXKJKGNazmALXnw6xwDtYrGCiD7Nnnr6R0/FsUuC4nP6WNJ3pM0h2BqZjsW5x6tSrttsb32HmipKhfQHZ3Kyau/Qjo46qLXKMpG+x3eeBzXHSGtlBk+sTGZRSzUPslZt80MP78vwsAJvb/CyC9Mf9ndQSwMEFAAAAAgAQlZeXXvm2byBAAAA3AAAABUAAABwcHQvc2xpZGVzL3NsaWRlMy54bWyNj0sOwjAMRK+CegBcsWARhS64AlzAakwbKXGs2BLl9jR8hLpjY48180ayF6cp7JacWB2eutlMHICOM2XUfRHi1buVmtHWs04QKt4jTznBoe+PkDFy9+HlH14qKbGhxcKbksGLGy8ptK1yrURv1aYt5xIeg4eNbB78wvDl4fXU8ARQSwMEFAAAAAgAQlZeXQxw2HipAAAAFQEAACEAAABwcHQvc2xpZGVNYXN0ZXJzL3NsaWRlTWFzdGVyMS54bWyNkE0KwjAQha9SegCnuHARYqBiwYXa0tYDhCbaQn6GJGC9vU2rFHduvpnh8d6DoUi8EsmolfGE79M+BCQAvuul5n5jUZpJu1uneZhO9wDh+HMwD61gm2U70Hww6ceP//jRSS9N4GGw5ieEUSRdo0ScHlsn5bJFhvFgxYtRTjDCRQR2yZu2qJPmVN7Ox+RatkleVUVeU4hqpJs5eWDNgCUU1hb4FsP8DfYGUEsBAhQDFAAAAAgAQlZeXU7mfuutAAAAQgEAABUAAAAAAAAAAAAAAIABAAAAAHBwdC9zbGlkZXMvc2xpZGUxLnhtbFBLAQIUAxQAAAAIAEJWXl0ilRDjtAAAAEsBAAAVAAAAAAAAAAAAAACAAeAAAABwcHQvc2xpZGVzL3NsaWRlMi54bWxQSwECFAMUAAAACABCVl5de+bZvIEAAADcAAAAFQAAAAAAAAAAAAAAgAHHAQAAcHB0L3NsaWRlcy9zbGlkZTMueG1sUEsBAhQDFAAAAAgAQlZeXQxw2HipAAAAFQEAACEAAAAAAAAAAAAAAIABewIAAHBwdC9zbGlkZU1hc3RlcnMvc2xpZGVNYXN0ZXIxLnhtbFBLBQYAAAAABAAEABgBAABjAwAAAAA="
        let data = try XCTUnwrap(Data(base64Encoded: blob))
        let url = try tempFile(named: "talk.pptx", contents: data)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try importer.importFile(at: url)
        XCTAssertEqual(source.kind, .presentation)
        XCTAssertTrue(source.text.contains("## Slide 1"))
        XCTAssertTrue(source.text.contains("Faithful Title"))
        XCTAssertTrue(source.text.contains("First slide body text."))
        XCTAssertTrue(source.text.contains("## Slide 2"))
        XCTAssertTrue(source.text.contains("Second Heading"))
        XCTAssertTrue(source.text.contains("Fish & chips cost 1 < 2."))
        XCTAssertFalse(source.text.contains("Slide 3"), "empty slides are skipped")
        XCTAssertFalse(source.text.contains("MASTER"), "masters/layouts are ignored")
        let first = try XCTUnwrap(source.text.range(of: "## Slide 1"))
        let second = try XCTUnwrap(source.text.range(of: "## Slide 2"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
    }

    func testPowerPointEmitsImageMarkers() throws {
        let art = try XCTUnwrap(tinyPNG())
        let zip = pptxStoredZip([
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["Caption"], blips: ["rId2"]), 0),
            ("ppt/slides/slide2.xml", pptxSlideXMLWithBlips(runs: [], blips: ["rId3"]), 0),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([("rId2", "../media/image1.png", pptxImageType)]), 0),
            ("ppt/slides/_rels/slide2.xml.rels", pptxRelsXML([("rId3", "../media/image2.png", pptxImageType)]), 0),
            ("ppt/media/image1.png", art, 0),
            ("ppt/media/image2.png", art, 0),
        ])
        let url = try tempFile(named: "pics.pptx", contents: zip)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try importer.importFile(at: url)
        XCTAssertEqual(source.kind, .presentation)
        XCTAssertTrue(source.text.contains("[Image 1]"))
        XCTAssertTrue(source.text.contains("[Image 2]"))
        XCTAssertTrue(source.text.contains("(no extractable text)"), "image-only slide stays readable")
        XCTAssertEqual(source.images.count, 2)
        XCTAssertEqual(source.images.map(\.index), [1, 2])
        XCTAssertEqual(source.images.map(\.slide), [1, 2])
        XCTAssertEqual(source.images.first?.data, art)
    }

    func testPDFEmitsImageMarkers() throws {
        let red = try XCTUnwrap(flateEncode(Data([255, 0, 0])))
        let blue = try XCTUnwrap(flateEncode(Data([0, 0, 255])))
        let pdf = tinyPDF(pages: [
            PDFTestPage(text: "Alpha", images: [
                PDFTestImage(name: "Im1", width: 1, height: 1, bits: 8,
                             colorSpace: "/DeviceRGB", filter: "/FlateDecode", bytes: red),
            ]),
            PDFTestPage(images: [
                PDFTestImage(name: "Im2", width: 1, height: 1, bits: 8,
                             colorSpace: "/DeviceRGB", filter: "/FlateDecode", bytes: blue),
            ]),
        ])
        let url = try tempFile(named: "pics.pdf", contents: pdf)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try importer.importFile(at: url)
        XCTAssertEqual(source.kind, .presentation)
        XCTAssertTrue(source.text.contains("## Page 1"))
        XCTAssertTrue(source.text.contains("Alpha"))
        XCTAssertTrue(source.text.contains("[Image 1]"))
        XCTAssertTrue(source.text.contains("## Page 2"), "image-only page survives")
        XCTAssertTrue(source.text.contains("(no extractable text)"))
        XCTAssertTrue(source.text.contains("[Image 2]"))
        XCTAssertEqual(source.images.count, 2)
        XCTAssertEqual(source.images.map(\.index), [1, 2])
        XCTAssertEqual(source.images.map(\.slide), [1, 2])
        XCTAssertEqual(rgbaPixels(source.images[0].data)?.bytes, [255, 0, 0, 255])
        XCTAssertEqual(rgbaPixels(source.images[1].data)?.bytes, [0, 0, 255, 255])
    }

    func testPowerPointRejectsGarbage() throws {
        let url = try tempFile(named: "bad.pptx", contents: Data("not a zip".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try importer.importFile(at: url)) { error in
            XCTAssertEqual(error as? SourceImporter.ImportError, .unreadable(url.lastPathComponent))
        }
    }

    func testPdfMarksPresentationKind() throws {
        // One-page PDF rendered in-test (no fixture file needed).
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            throw XCTSkip("no pdf context")
        }
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(gray: 0, alpha: 1))
        pdf.textMatrix = .identity
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "Alpha Bravo", attributes: [.font: CTFontCreateUIFontForLanguage(.system, 24, nil)!]
        ))
        pdf.textPosition = CGPoint(x: 40, y: 200)
        CTLineDraw(line, pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        let url = try tempFile(named: "doc.pdf", contents: data as Data)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try importer.importFile(at: url)
        XCTAssertEqual(source.kind, .presentation)
        XCTAssertTrue(source.text.contains("## Page 1"))
        XCTAssertTrue(source.text.contains("Alpha Bravo"))
    }

    func testFreeformKinds() throws {
        let md = try tempFile(named: "n.md", contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(at: md) }
        XCTAssertEqual(try importer.importFile(at: md).kind, .freeform)
        XCTAssertEqual(try importer.importText("hi").kind, .freeform)
    }

    func testEmptyTextRejected() {
        XCTAssertThrowsError(try importer.importText("  \n "))
    }

    func testLongSourceTruncatedAndFlagged() throws {
        let source = try importer.importText(String(repeating: "a", count: 25_000))
        XCTAssertTrue(source.truncated)
        XCTAssertTrue(source.text.hasSuffix("[…truncated…]"))
        XCTAssertLessThan(source.text.count, 25_000)
    }

    func testDeckSourceJoinsCards() throws {
        let deck = Presentation(name: "Deck", cards: [
            PresentationCard(title: "T1", message: "M1", detail: "D1"),
            PresentationCard(title: "T2", message: "M2"),
        ])
        let source = try importer.importPresentation(deck)
        XCTAssertEqual(source.title, "Deck")
        XCTAssertTrue(source.text.contains("## T1"))
        XCTAssertTrue(source.text.contains("M2"))
        XCTAssertTrue(source.text.contains("D1"))
    }
}

private func pptxLe16(_ value: Int) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
}

private func pptxLe32(_ value: Int) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
}

private func pptxSlideXML(_ runs: String...) -> Data {
    pptxSlideXMLWithBlips(runs: runs, blips: [])
}

/// Slide carrying text runs plus picture blips (embed ids in document
/// order); shape/container wrappers omitted — the extractor only reads
/// a:t runs and a:blip embed attributes.
private func pptxSlideXMLWithBlips(runs: [String], blips: [String]) -> Data {
    let blipXML = blips.map {
        "<a:blip xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" r:embed=\"\($0)\"/>"
    }.joined()
    return Data("""
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>\(runs.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined())</p:txBody></p:sp>\(blipXML)</p:spTree></p:cSld></p:sld>
        """.utf8)
}

private func pptxRelsXML(_ mappings: [(id: String, target: String, type: String)]) -> Data {
    Data("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(mappings.map { "<Relationship Id=\"\($0.id)\" Type=\"\($0.type)\" Target=\"\($0.target)\"/>" }.joined())</Relationships>
        """.utf8)
}

private let pptxImageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

/// Stored-entry zip builder (no compression needed for these tests).
private func pptxStoredZip(_ entries: [(name: String, bytes: Data, method: UInt16)]) -> Data {
    var zip = Data()
    var central = Data()
    for (name, bytes, method) in entries {
        let nameData = Data(name.utf8)
        let offset = zip.count
        for part in [pptxLe32(0x0403_4B50), pptxLe16(20), pptxLe16(0), pptxLe16(Int(method)), pptxLe16(0), pptxLe16(0),
                     pptxLe32(0), pptxLe32(bytes.count), pptxLe32(bytes.count), pptxLe16(nameData.count), pptxLe16(0)] {
            zip.append(part)
        }
        zip.append(nameData)
        zip.append(bytes)
        for part in [pptxLe32(0x0201_4B50), pptxLe16(20), pptxLe16(20), pptxLe16(0), pptxLe16(Int(method)), pptxLe16(0), pptxLe16(0),
                     pptxLe32(0), pptxLe32(bytes.count), pptxLe32(bytes.count), pptxLe16(nameData.count), pptxLe16(0), pptxLe16(0),
                     pptxLe16(0), pptxLe16(0), pptxLe32(0), pptxLe32(offset)] {
            central.append(part)
        }
        central.append(nameData)
    }
    let dirStart = zip.count
    zip.append(central)
    for part in [pptxLe32(0x0605_4B50), pptxLe16(0), pptxLe16(0), pptxLe16(entries.count), pptxLe16(entries.count),
                 pptxLe32(central.count), pptxLe32(dirStart), pptxLe16(0)] {
        zip.append(part)
    }
    return zip
}

final class SourceSegmentsTests: XCTestCase {
    func testCountsSlidesAndPages() {
        let text = """
            ## Slide 1
            Intro
            ## Slide 3
            Skipped numbering still counts
            ## Page 2
            Mixed kinds count together
            """
        XCTAssertEqual(SourceSegments.count(in: text), 3)
    }

    func testIgnoresProseAndNearMarkers() {
        XCTAssertEqual(SourceSegments.count(in: ""), 0)
        XCTAssertEqual(SourceSegments.count(in: "Just pasted text\nno markers here"), 0)
        // Near-markers: no trailing space, wrong case, markdown headings.
        XCTAssertEqual(SourceSegments.count(in: "## Slide\n## Slideshow\n## slide 1\n## Pager\n## History"), 0)
        XCTAssertEqual(SourceSegments.count(in: "See ## Slide 1 inline"), 0, "mid-line mentions don't count")
    }

    func testToleratesIndentedMarkers() {
        XCTAssertEqual(SourceSegments.count(in: "  ## Slide 1\n\t## Page 2"), 2)
    }
}

final class PptxSecurityTests: XCTestCase {
    func testStoredSlideExtracts() {
        let zip = pptxStoredZip([("ppt/slides/slide1.xml", pptxSlideXML("Hello"), 0)])
        let slides = PptxTextExtractor.slides(from: zip)
        XCTAssertEqual(slides?.count, 1)
        XCTAssertEqual(slides?.first?.number, 1)
        XCTAssertTrue(slides?.first?.text.contains("Hello") ?? false)
    }

    func testEntryCountCapRejectsFlood() {
        let entries = (0 ..< 4100).map { ("f\($0).txt", Data([65]), UInt16(0)) }
        XCTAssertNil(PptxTextExtractor.slides(from: pptxStoredZip(entries)))
    }

    func testSlideCountCap() {
        let entries = (1 ... 3).map { ("ppt/slides/slide\($0).xml", pptxSlideXML("T\($0)"), UInt16(0)) }
        XCTAssertNil(PptxTextExtractor.slides(from: pptxStoredZip(entries), limits: .init(maxSlides: 2)))
        XCTAssertEqual(PptxTextExtractor.slides(from: pptxStoredZip(entries))?.count, 3)
    }

    func testTotalBytesCap() {
        let zip = pptxStoredZip([("ppt/slides/slide1.xml", pptxSlideXML(String(repeating: "w", count: 100)), 0)])
        XCTAssertNil(PptxTextExtractor.slides(from: zip, limits: .init(maxTotalBytes: 10)))
    }

    func testEntryBytesCap() {
        let zip = pptxStoredZip([("ppt/slides/slide1.xml", pptxSlideXML("Hello"), 0)])
        XCTAssertNil(PptxTextExtractor.slides(from: zip, limits: .init(maxEntryBytes: 10)))
    }

    func testTraversalNamesIgnored() {
        let zip = pptxStoredZip([
            ("ppt/slides/../../evil.xml", pptxSlideXML("EVIL"), 0),
            ("ppt/slides/slide1.xml", pptxSlideXML("GOOD"), 0),
        ])
        let slides = PptxTextExtractor.slides(from: zip)
        XCTAssertEqual(slides?.count, 1)
        XCTAssertTrue(slides?.first?.text.contains("GOOD") ?? false)
    }

    func testDoctypeRejected() {
        var xml = pptxSlideXML("boom")
        let marker = "<p:sld".data(using: .utf8)!
        let range = xml.range(of: marker)!
        xml.insert(contentsOf: "<!DOCTYPE p:sld [<!ENTITY x \"boom\">]>".utf8, at: range.lowerBound)
        let zip = pptxStoredZip([("ppt/slides/slide1.xml", xml, 0)])
        XCTAssertNil(PptxTextExtractor.slides(from: zip))
    }

    func testTruncatedZipFailsCleanly() {
        let zip = pptxStoredZip([("ppt/slides/slide1.xml", pptxSlideXML("Hello"), 0)])
        XCTAssertNil(PptxTextExtractor.slides(from: zip.dropLast(zip.count / 2)))
        XCTAssertNil(PptxTextExtractor.slides(from: Data("not a zip".utf8)))
        XCTAssertNil(PptxTextExtractor.slides(from: Data()))
    }

    func testUnsupportedMethodSkipped() {
        let zip = pptxStoredZip([("ppt/slides/slide1.xml", pptxSlideXML("Hello"), 99)])
        XCTAssertNil(PptxTextExtractor.slides(from: zip))
    }
}

final class PptxImageTests: XCTestCase {
    private func deck(entries: [(name: String, bytes: Data)]) -> Data {
        pptxStoredZip(entries.map { ($0.name, $0.bytes, UInt16(0)) })
    }

    func testSlideImageExtractsWithMarker() throws {
        let art = try XCTUnwrap(tinyPNG())
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["Caption"], blips: ["rId2"])),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([("rId2", "../media/image1.png", pptxImageType)])),
            ("ppt/media/image1.png", art),
        ])
        let result = try XCTUnwrap(PptxTextExtractor.slidesAndImages(from: zip))
        XCTAssertEqual(result.slides.count, 1)
        XCTAssertEqual(result.slides[0].number, 1)
        XCTAssertTrue(result.slides[0].text.contains("Caption"))
        XCTAssertEqual(result.slides[0].images, [1])
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.images[0].index, 1)
        XCTAssertEqual(result.images[0].slide, 1)
        XCTAssertEqual(result.images[0].data, art)
    }

    func testEmbedOrderPreserved() throws {
        let first = try XCTUnwrap(tinyPNG(red: 1, green: 0, blue: 0))
        let second = try XCTUnwrap(tinyPNG(red: 0, green: 0, blue: 1))
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["T"], blips: ["rId2", "rId3"])),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([
                ("rId2", "../media/a.png", pptxImageType),
                ("rId3", "../media/b.png", pptxImageType),
            ])),
            ("ppt/media/a.png", first),
            ("ppt/media/b.png", second),
        ])
        let result = try XCTUnwrap(PptxTextExtractor.slidesAndImages(from: zip))
        XCTAssertEqual(result.slides[0].images, [1, 2])
        XCTAssertEqual(result.images.map(\.data), [first, second])
    }

    func testSharedMediaDeduped() throws {
        let art = try XCTUnwrap(tinyPNG())
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["One"], blips: ["rId2"])),
            ("ppt/slides/slide2.xml", pptxSlideXMLWithBlips(runs: ["Two"], blips: ["rId5"])),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([("rId2", "../media/shared.png", pptxImageType)])),
            ("ppt/slides/_rels/slide2.xml.rels", pptxRelsXML([("rId5", "../media/shared.png", pptxImageType)])),
            ("ppt/media/shared.png", art),
        ])
        let result = try XCTUnwrap(PptxTextExtractor.slidesAndImages(from: zip))
        XCTAssertEqual(result.images.count, 1)
        XCTAssertEqual(result.slides.map(\.images), [[1], [1]])
    }

    func testImageOnlySlideSurvivesEmptySkipped() throws {
        let art = try XCTUnwrap(tinyPNG())
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: [], blips: ["rId2"])),
            ("ppt/slides/slide2.xml", pptxSlideXML()),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([("rId2", "../media/image1.png", pptxImageType)])),
            ("ppt/media/image1.png", art),
        ])
        let result = try XCTUnwrap(PptxTextExtractor.slidesAndImages(from: zip))
        XCTAssertEqual(result.slides.count, 1)
        XCTAssertEqual(result.slides[0].number, 1)
        XCTAssertEqual(result.slides[0].text, "")
        XCTAssertEqual(result.slides[0].images, [1])
    }

    func testMissingRelsKeepsText() {
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["Alone"], blips: ["rId2"])),
        ])
        let result = PptxTextExtractor.slidesAndImages(from: zip)
        XCTAssertEqual(result?.slides[0].images, [])
        XCTAssertTrue(result?.slides[0].text.contains("Alone") ?? false)
        XCTAssertEqual(result?.images.count, 0)
    }

    func testForeignTargetsRejected() throws {
        let art = try XCTUnwrap(tinyPNG())
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["T"], blips: ["rId2", "rId3", "rId4"])),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([
                ("rId2", "https://evil.test/x.png", pptxImageType),
                ("rId3", "../../media/escape.png", pptxImageType),
                ("rId4", "../media/ok.png", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"),
            ])),
            ("ppt/media/ok.png", art),
        ])
        let result = PptxTextExtractor.slidesAndImages(from: zip)
        XCTAssertEqual(result?.slides[0].images, [])
        XCTAssertEqual(result?.images.count, 0)
    }

    func testCorruptAndVectorMediaSkipped() {
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["T"], blips: ["rId2", "rId3"])),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([
                ("rId2", "../media/broken.png", pptxImageType),
                ("rId3", "../media/art.svg", pptxImageType),
            ])),
            ("ppt/media/broken.png", Data([1, 2, 3])),
            ("ppt/media/art.svg", Data("<svg/>".utf8)),
        ])
        let result = PptxTextExtractor.slidesAndImages(from: zip)
        XCTAssertTrue(result?.slides[0].text.contains("T") ?? false)
        XCTAssertEqual(result?.slides[0].images, [])
        XCTAssertEqual(result?.images.count, 0)
    }

    func testMediaBudgetRejectsFile() throws {
        let art = try XCTUnwrap(tinyPNG())
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["Big"], blips: ["rId2"])),
            ("ppt/slides/_rels/slide1.xml.rels", pptxRelsXML([("rId2", "../media/image1.png", pptxImageType)])),
            ("ppt/media/image1.png", art),
        ])
        XCTAssertNil(PptxTextExtractor.slidesAndImages(from: zip, limits: .init(maxTotalBytes: 10)))
    }

    func testRelsDoctypeKeepsTextDropsImages() throws {
        let art = try XCTUnwrap(tinyPNG())
        var rels = pptxRelsXML([("rId2", "../media/image1.png", pptxImageType)])
        rels.insert(contentsOf: "<!DOCTYPE Relationships>".utf8, at: 0)
        let zip = deck(entries: [
            ("ppt/slides/slide1.xml", pptxSlideXMLWithBlips(runs: ["Safe"], blips: ["rId2"])),
            ("ppt/slides/_rels/slide1.xml.rels", rels),
            ("ppt/media/image1.png", art),
        ])
        let result = PptxTextExtractor.slidesAndImages(from: zip)
        XCTAssertTrue(result?.slides[0].text.contains("Safe") ?? false)
        XCTAssertEqual(result?.slides[0].images, [])
        XCTAssertEqual(result?.images.count, 0)
    }
}

// MARK: - Hand-crafted PDF fixtures (xref offsets exact)

private struct PDFTestImage {
    var name: String
    var width: Int
    var height: Int
    var bits: Int
    /// PDF fragment, e.g. "/DeviceRGB" or "[/Indexed /DeviceRGB 1 <FF0000 0000FF>]".
    var colorSpace: String
    var filter: String?
    var decodeParms: String?
    var bytes: Data
}

private struct PDFTestForm {
    var name: String
    var images: [PDFTestImage]
}

private struct PDFTestPage {
    var text: String?
    var images: [PDFTestImage]
    var forms: [PDFTestForm] = []
}

private func pdfDict(_ inner: String) -> Data {
    Data("<<\(inner)>>".utf8)
}

private func pdfStream(dict: String, bytes: Data) -> Data {
    var out = Data("<<\(dict) /Length \(bytes.count)>>\nstream\n".utf8)
    out.append(bytes)
    out.append(Data("\nendstream".utf8))
    return out
}

private func pdfImageObject(_ image: PDFTestImage) -> Data {
    var dict = "/Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height) /BitsPerComponent \(image.bits) /ColorSpace \(image.colorSpace)"
    if let filter = image.filter {
        dict += " /Filter \(filter)"
    }
    if let parms = image.decodeParms {
        dict += " /DecodeParms \(parms)"
    }
    return pdfStream(dict: dict, bytes: image.bytes)
}

private func pdfRefDict(_ entries: [(String, Int)]) -> String {
    "<<\(entries.map { "/\($0.0) \($0.1) 0 R" }.joined(separator: " "))>>"
}

/// Minimal multi-page PDF with image (and nested Form) XObjects.
/// ASCII text only; keep names simple (`Im1`, `Fm1`).
private func tinyPDF(pages: [PDFTestPage]) -> Data {
    var bodies: [Data] = []
    func reserve() -> Int {
        bodies.append(Data())
        return bodies.count
    }
    func emit(_ number: Int, _ body: Data) {
        bodies[number - 1] = body
    }
    let catalog = reserve()
    let kids = reserve()
    let font = reserve()
    emit(font, pdfDict("/Type /Font /Subtype /Type1 /BaseFont /Helvetica"))
    var pageNumbers: [Int] = []
    for page in pages {
        let pageNumber = reserve()
        pageNumbers.append(pageNumber)
        var xentries: [(String, Int)] = []
        for form in page.forms {
            var nested: [(String, Int)] = []
            for image in form.images {
                let number = reserve()
                emit(number, pdfImageObject(image))
                nested.append((image.name, number))
            }
            let formNumber = reserve()
            let shown = form.images.first?.name ?? "Im0"
            emit(formNumber, pdfStream(
                dict: "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources <</XObject \(pdfRefDict(nested))>>",
                bytes: Data("/\(shown) Do".utf8)
            ))
            xentries.append((form.name, formNumber))
        }
        for image in page.images {
            let number = reserve()
            emit(number, pdfImageObject(image))
            xentries.append((image.name, number))
        }
        let contentNumber = reserve()
        let text = page.text.map { "BT /F1 12 Tf 72 100 Td (\($0)) Tj ET" } ?? ""
        emit(contentNumber, pdfStream(dict: "", bytes: Data(text.utf8)))
        let xobjects = xentries.isEmpty ? "" : " /XObject \(pdfRefDict(xentries))"
        emit(pageNumber, pdfDict(
            "/Type /Page /Parent \(kids) 0 R /MediaBox [0 0 200 200] /Resources <</Font <</F1 \(font) 0 R>>\(xobjects)>> /Contents \(contentNumber) 0 R"
        ))
    }
    emit(kids, pdfDict("/Type /Pages /Kids [\(pageNumbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageNumbers.count)"))
    emit(catalog, pdfDict("/Type /Catalog /Pages \(kids) 0 R"))
    var pdf = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = []
    for (index, body) in bodies.enumerated() {
        offsets.append(pdf.count)
        pdf.append(Data("\(index + 1) 0 obj\n".utf8))
        pdf.append(body)
        pdf.append(Data("\nendobj\n".utf8))
    }
    let xrefStart = pdf.count
    pdf.append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8))
    for offset in offsets {
        pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    pdf.append(Data("trailer\n<</Size \(bodies.count + 1) /Root \(catalog) 0 R>>\nstartxref\n\(xrefStart)\n%%EOF\n".utf8))
    return pdf
}

/// zlib framing around the one-shot API's raw deflate core.
private func flateEncode(_ data: Data) -> Data? {
    guard !data.isEmpty else { return nil }
    let cap = data.count + 64
    var output = Data(count: cap)
    let encoded: Int = output.withUnsafeMutableBytes { dst in
        data.withUnsafeBytes { src in
            guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
            return compression_encode_buffer(
                d, cap, s.assumingMemoryBound(to: UInt8.self), data.count, nil, COMPRESSION_ZLIB
            )
        }
    }
    guard encoded > 0, encoded <= cap else { return nil }
    var framed = Data([0x78, 0x9C])
    framed.append(output.prefix(encoded))
    let check = adler32Encode(data)
    framed.append(contentsOf: [
        UInt8((check >> 24) & 0xFF), UInt8((check >> 16) & 0xFF),
        UInt8((check >> 8) & 0xFF), UInt8(check & 0xFF),
    ])
    return framed
}

private func adler32Encode(_ data: Data) -> UInt32 {
    var low: UInt32 = 1, high: UInt32 = 0
    for byte in data {
        low = (low + UInt32(byte)) % 65_521
        high = (high + low) % 65_521
    }
    return high * 65_536 + low
}

private func ascii85Encode(_ data: Data) -> Data {
    var out = ""
    let bytes = [UInt8](data)
    var index = 0
    while index < bytes.count {
        let remaining = min(4, bytes.count - index)
        var value: UInt32 = 0
        for offset in 0 ..< 4 {
            value <<= 8
            if offset < remaining {
                value |= UInt32(bytes[index + offset])
            }
        }
        if remaining == 4, value == 0 {
            out.append("z")
        } else {
            var digits = ""
            for _ in 0 ..< 5 {
                digits.append(Character(UnicodeScalar(33 + value % 85)!))
                value /= 85
            }
            out.append(String(digits.reversed().prefix(remaining + 1)))
        }
        index += remaining
    }
    return Data((out + "~>").utf8)
}

/// Re-encodes PNG bytes as JPEG (for DCT fixtures).
private func jpegBytes(fromPNG png: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

/// Decodes PNG/JPEG bytes to RGBA pixels for exact comparison.
private func rgbaPixels(_ data: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let width = image.width, height = image.height
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    return (width, height, Array(UnsafeBufferPointer(start: bytes, count: width * height * 4)))
}

private func pdfDocument(_ pdf: Data) -> CGPDFDocument? {
    guard let provider = CGDataProvider(data: pdf as CFData) else { return nil }
    return CGPDFDocument(provider)
}

final class PdfImageTests: XCTestCase {
    private func rgb(_ name: String, _ pixels: [UInt8], flated: Bool = true) throws -> PDFTestImage {
        let bytes = try XCTUnwrap(flated ? flateEncode(Data(pixels)) : Data(pixels))
        return PDFTestImage(name: name, width: pixels.count / 3, height: 1, bits: 8,
                            colorSpace: "/DeviceRGB", filter: flated ? "/FlateDecode" : nil, bytes: bytes)
    }

    private func extract(_ pdf: Data, limits: PdfImageExtractor.Limits = .init()) throws -> [[SourceImage]] {
        let document = try XCTUnwrap(pdfDocument(pdf))
        return PdfImageExtractor.imagesPerPage(from: document, limits: limits)
    }

    func testFlateRGBDecodesToPNG() throws {
        let image = try rgb("Im1", [255, 0, 0, 0, 0, 255])
        let pages = try extract(tinyPDF(pages: [PDFTestPage(text: "Hi", images: [image])]))
        XCTAssertEqual(pages.count, 1)
        let found = try XCTUnwrap(pages[0].first)
        XCTAssertEqual(found.index, 1)
        XCTAssertEqual(found.slide, 1)
        let pixels = try XCTUnwrap(rgbaPixels(found.data))
        XCTAssertEqual(pixels.width, 2)
        XCTAssertEqual(pixels.height, 1)
        XCTAssertEqual(pixels.bytes, [255, 0, 0, 255, 0, 0, 255, 255])
    }

    func testUnfilteredSamplesDecode() throws {
        let image = try rgb("Im1", [0, 255, 0], flated: false)
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertEqual(pixels.bytes, [0, 255, 0, 255])
    }

    func testDCTImageShipsVerbatim() throws {
        let png = try XCTUnwrap(tinyPNG())
        let jpeg = try XCTUnwrap(jpegBytes(fromPNG: png))
        let image = PDFTestImage(name: "Im1", width: 64, height: 48, bits: 8,
                                 colorSpace: "/DeviceRGB", filter: "/DCTDecode", bytes: jpeg)
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        XCTAssertEqual(pages[0].count, 1)
        XCTAssertEqual(pages[0].first?.data, jpeg, "original JPEG bytes ship untouched")
    }

    func testPredictorRowsUnfilter() throws {
        // 2x3 RGB, PNG optimum: row filter bytes 0 (raw), 2 (up), 1 (sub).
        let row0 = [10, 20, 30, 40, 50, 60]
        let row1 = [15, 25, 35, 45, 60, 70].enumerated().map { UInt8(($0.element - row0[$0.offset]) & 0xFF) }
        let raw2 = [20, 30, 40, 100, 110, 120]
        let row2 = [20, 30, 40, 80, 80, 80]
        var rows: [UInt8] = [0] + row0.map(UInt8.init)
        rows += [2] + row1
        rows += [1] + row2.map(UInt8.init)
        let bytes = try XCTUnwrap(flateEncode(Data(rows)))
        let image = PDFTestImage(name: "Im1", width: 2, height: 3, bits: 8,
                                 colorSpace: "/DeviceRGB", filter: "/FlateDecode",
                                 decodeParms: "<</Predictor 12 /Colors 3 /Columns 2>>", bytes: bytes)
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertEqual(pixels.width, 2)
        XCTAssertEqual(pixels.height, 3)
        let expected = (row0 + [15, 25, 35, 45, 60, 70] + raw2).map(UInt8.init)
        var rgba: [UInt8] = []
        for index in stride(from: 0, to: expected.count, by: 3) {
            rgba += [expected[index], expected[index + 1], expected[index + 2], 255]
        }
        XCTAssertEqual(pixels.bytes, rgba)
    }

    func testIndexedExpandsPalette() throws {
        let image = PDFTestImage(name: "Im1", width: 2, height: 1, bits: 8,
                                 colorSpace: "[/Indexed /DeviceRGB 1 <FF0000 0000FF>]",
                                 bytes: Data([0, 1]))
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertEqual(pixels.bytes, [255, 0, 0, 255, 0, 0, 255, 255])
    }

    func testGray1BitUnpacks() throws {
        let image = PDFTestImage(name: "Im1", width: 8, height: 1, bits: 1,
                                 colorSpace: "/DeviceGray", bytes: Data([0xA5]))
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        // 0xA5 = 10100101, MSB first, scaled to 0/255.
        let bits: [UInt8] = [255, 0, 255, 0, 0, 255, 0, 255]
        XCTAssertEqual(pixels.bytes, bits.flatMap { [$0, $0, $0, 255] })
    }

    func testASCII85WrappedFlate() throws {
        let flated = try XCTUnwrap(flateEncode(Data([255, 0, 0])))
        let image = PDFTestImage(name: "Im1", width: 1, height: 1, bits: 8,
                                 colorSpace: "/DeviceRGB",
                                 filter: "[/ASCII85Decode /FlateDecode]",
                                 bytes: ascii85Encode(flated))
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertEqual(pixels.bytes, [255, 0, 0, 255])
    }

    func testRunLengthDecodes() throws {
        // Literal 10, then repeat 20 twice, then end-of-data.
        let image = PDFTestImage(name: "Im1", width: 3, height: 1, bits: 8,
                                 colorSpace: "/DeviceGray",
                                 filter: "/RunLengthDecode",
                                 bytes: Data([0x00, 10, 0xFF, 20, 0x80]))
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertEqual(pixels.bytes, [10, 10, 10, 255, 20, 20, 20, 255, 20, 20, 20, 255])
    }

    func testCMYKConvertsToRGB() throws {
        // C0 M255 Y255 K0 ≈ red.
        let flated = try XCTUnwrap(flateEncode(Data([0, 255, 255, 0])))
        let image = PDFTestImage(name: "Im1", width: 1, height: 1, bits: 8,
                                 colorSpace: "/DeviceCMYK", filter: "/FlateDecode", bytes: flated)
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [image])]))
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertGreaterThan(pixels.bytes[0], 200)
        XCTAssertLessThan(pixels.bytes[1], 100)
        XCTAssertLessThan(pixels.bytes[2], 100)
    }

    func testMalformedSkippedSiblingSurvives() throws {
        // Fax without parms, Lab colorspace, garbage LZW: undecodable
        // or unsupported, all skipped while the valid sibling survives.
        // (Well-formed fax/LZW ride the same Quartz path as flate.)
        let fax = PDFTestImage(name: "ImFax", width: 8, height: 8, bits: 1,
                               colorSpace: "/DeviceGray", filter: "/CCITTFaxDecode",
                               bytes: Data([0x00, 0x01]))
        let lab = PDFTestImage(name: "ImLab", width: 1, height: 1, bits: 8,
                               colorSpace: "[/Lab <</WhitePoint [0.95 1 1.09]>>]",
                               bytes: Data([128, 128, 128]))
        let lzw = PDFTestImage(name: "ImLZW", width: 1, height: 1, bits: 8,
                               colorSpace: "/DeviceGray", filter: "/LZWDecode",
                               bytes: Data([0x80, 0x0B]))
        let good = try rgb("ImGood", [1, 2, 3])
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [fax, lab, lzw, good])]))
        XCTAssertEqual(pages[0].count, 1)
        XCTAssertEqual(pages[0].first?.index, 1)
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertEqual(pixels.bytes, [1, 2, 3, 255])
    }

    func testCorruptFlateSkipped() throws {
        let bad = PDFTestImage(name: "ImBad", width: 2, height: 1, bits: 8,
                               colorSpace: "/DeviceRGB", filter: "/FlateDecode",
                               bytes: Data("not deflated!!!".utf8))
        let good = try rgb("ImGood", [9, 9, 9])
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [bad, good])]))
        XCTAssertEqual(pages[0].count, 1)
        XCTAssertEqual(pages[0].first?.index, 1)
    }

    func testAbsurdDimensionsSkipped() throws {
        let bomb = PDFTestImage(name: "ImBomb", width: 100_000, height: 100_000, bits: 8,
                                colorSpace: "/DeviceRGB", filter: "/FlateDecode",
                                bytes: Data([0x78, 0x9C, 0x03, 0x00]))
        let good = try rgb("ImGood", [7, 8, 9])
        let pages = try extract(tinyPDF(pages: [PDFTestPage(images: [bomb, good])]))
        XCTAssertEqual(pages[0].count, 1)
        XCTAssertEqual(pages[0].first?.index, 1)
    }

    func testNestedFormImageFound() throws {
        let nested = try rgb("Im7", [255, 255, 0])
        let page = PDFTestPage(images: [], forms: [PDFTestForm(name: "Fm1", images: [nested])])
        let pages = try extract(tinyPDF(pages: [page]))
        XCTAssertEqual(pages[0].count, 1)
        let pixels = try XCTUnwrap(pages[0].first.flatMap { rgbaPixels($0.data) })
        XCTAssertEqual(pixels.bytes, [255, 255, 0, 255])
    }

    func testMultiPageOrderingAndIndices() throws {
        // File order Im2, Im1 — resource-name sort must win.
        let red = try rgb("Im1", [255, 0, 0])
        let blue = try rgb("Im2", [0, 0, 255])
        let green = try rgb("Im9", [0, 255, 0])
        let pages = try extract(tinyPDF(pages: [
            PDFTestPage(images: [blue, red]),
            PDFTestPage(images: [green]),
        ]))
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].map(\.index), [1, 2])
        XCTAssertEqual(pages[1].map(\.index), [3])
        XCTAssertEqual(pages[1].first?.slide, 2)
        XCTAssertEqual(pages[0].first.flatMap { rgbaPixels($0.data) }?.bytes, [255, 0, 0, 255])
        XCTAssertEqual(pages[0].dropFirst().first.flatMap { rgbaPixels($0.data) }?.bytes, [0, 0, 255, 255])
        XCTAssertEqual(pages[1].first.flatMap { rgbaPixels($0.data) }?.bytes, [0, 255, 0, 255])
    }

    func testImageCountCap() throws {
        let images = try [rgb("Im1", [1, 0, 0]), rgb("Im2", [0, 1, 0]), rgb("Im3", [0, 0, 1])]
        let pages = try extract(
            tinyPDF(pages: [PDFTestPage(images: images)]),
            limits: PdfImageExtractor.Limits(maxImages: 2)
        )
        XCTAssertEqual(pages[0].count, 2)
        XCTAssertEqual(pages[0].map(\.index), [1, 2])
    }
}

final class IllustrationComposerTests: XCTestCase {
    func testNilBasePassesThrough() {
        XCTAssertNil(IllustrationComposer.compose(imageData: nil, title: "T", labels: []))
    }

    func testBadBytesReturnNil() {
        XCTAssertNil(IllustrationComposer.compose(imageData: Data([1, 2, 3]), title: "T", labels: []))
    }

    func testComposes169PNG() throws {
        let base = try XCTUnwrap(tinyPNG())
        let composed = try XCTUnwrap(IllustrationComposer.compose(
            imageData: base, title: "Fractions", labels: ["half", "quarter"]
        ))
        XCTAssertEqual(decodedSize(composed), CGSize(width: 1280, height: 720))
    }
}

final class DiagramRendererTests: XCTestCase {
    private func renders(_ spec: DiagramSpec, file: StaticString = #filePath, line: UInt = #line) {
        guard let png = DiagramRenderer.render(spec) else {
            return XCTFail("kind \(spec.kind) must render", file: file, line: line)
        }
        XCTAssertEqual(decodedSize(png), CGSize(width: 1280, height: 720), file: file, line: line)
    }

    func testFractionCircle() {
        renders(DiagramSpec(kind: "fractionCircle", caption: "One half", numbers: [1, 2], labels: ["1/2"]))
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "fractionCircle", numbers: [2, 1])))
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "fractionCircle", numbers: [1, 0])))
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "fractionCircle", numbers: [1])))
    }

    func testNumberLine() {
        renders(DiagramSpec(kind: "numberLine", numbers: [0, 10, 5], labels: ["half"]))
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "numberLine", numbers: [10, 0])))
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "numberLine", numbers: [5])))
    }

    func testTimeline() {
        renders(DiagramSpec(kind: "timeline", numbers: [1789, 1799, 1804], labels: ["Storming", "Coup", "Empire"]))
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "timeline", numbers: [1789])))
    }

    func testCauseEffect() {
        renders(DiagramSpec(kind: "causeEffect", labels: ["Taxes", "Hunger", "Revolt"]))
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "causeEffect", labels: ["Only"])))
    }

    func testUnknownKindFallsBack() {
        XCTAssertNil(DiagramRenderer.render(DiagramSpec(kind: "noSuchKind")))
    }
}

final class DraftCardTests: XCTestCase {
    func testLabelsTextRoundTrip() {
        var draft = DraftCard(planned: PlannedCard(title: "T", concept: "C", body: "B", illustrationPrompt: "P"))
        draft.labelsText = "alpha, beta , , gamma"
        XCTAssertEqual(draft.labels, ["alpha", "beta", "gamma"])
        XCTAssertEqual(draft.labelsText, "alpha, beta, gamma")
    }

    func testCardConversionCarriesFields() {
        var draft = DraftCard(planned: PlannedCard(title: "T", concept: "C", body: "B", illustrationPrompt: "P"))
        draft.sourceReference = "Ch.1"
        draft.presenterNotes = "Point here"
        let card = makePresentationCard(from: draft)
        XCTAssertEqual(card.title, "T")
        XCTAssertEqual(card.message, "B")
        XCTAssertTrue(card.detail?.contains("Concept: C") ?? false)
        XCTAssertTrue(card.detail?.contains("Ch.1") ?? false)
        XCTAssertTrue(card.detail?.contains("Point here") ?? false)
    }

    func testBibleSubjectDemandsVersePrecision() {
        XCTAssertTrue(AISubject.bible.promptHint.contains("word-for-word"))
        var settings = GenerationSettings()
        settings.subject = .bible
        XCTAssertTrue(MetaModelClient.systemPrompt(settings: settings).contains("word-for-word"))
    }

    func testLabelsFoldIntoTextWhenImageless() {
        var draft = DraftCard(planned: PlannedCard(
            title: "T", concept: "C", body: "B", labels: ["a", "b"], illustrationPrompt: "P"
        ))
        draft.imageData = nil
        XCTAssertTrue(makePresentationCard(from: draft).message.contains("a • b"))
    }

    func testPromptChangedTracksEdits() {
        var draft = DraftCard(planned: PlannedCard(title: "T", concept: "C", body: "B", illustrationPrompt: "P"))
        draft.renderedIllustrationPrompt = "P"
        XCTAssertFalse(draft.promptChanged)
        draft.illustrationPrompt = "P, but bluer"
        XCTAssertTrue(draft.promptChanged)
        draft.illustrationPrompt = "  "
        XCTAssertFalse(draft.promptChanged, "empty prompt never regenerates")
    }

    func testDeckRoundTripPreservesArtworkAndPrompt() throws {
        let art = try XCTUnwrap(tinyPNG())
        let base = try XCTUnwrap(tinyPNG(red: 0, green: 0, blue: 1))
        let card = PresentationCard(
            title: "T", message: "B", detail: "Concept: C\nSource: S\nNotes: N",
            imageData: art, illustrationPrompt: "P", originalImageData: base
        )
        let draft = DraftCard(from: card)
        XCTAssertEqual(draft.title, "T")
        XCTAssertEqual(draft.body, "B")
        XCTAssertEqual(draft.imageData, art)
        XCTAssertEqual(draft.baseImageData, base)
        XCTAssertEqual(draft.illustrationPrompt, "P")
        XCTAssertEqual(draft.imageSource, .imported)
        XCTAssertFalse(draft.promptChanged, "untouched re-import must not regenerate")
        XCTAssertEqual(draft.concept, "C")
        XCTAssertEqual(draft.sourceReference, "S")
        XCTAssertEqual(draft.presenterNotes, "N")
        let back = makePresentationCard(from: draft)
        XCTAssertEqual(back.title, "T")
        XCTAssertEqual(back.message, "B")
        XCTAssertEqual(back.imageData, art)
        XCTAssertEqual(back.illustrationPrompt, "P")
        XCTAssertEqual(back.originalImageData, base)
        XCTAssertTrue(back.detail?.contains("Concept: C") ?? false)
    }

    func testLegacyCardReimportHasNoPromptOrBase() {
        let card = PresentationCard(title: "T", message: "B", imageData: Data([9]))
        let draft = DraftCard(from: card)
        XCTAssertEqual(draft.illustrationPrompt, "")
        XCTAssertFalse(draft.promptChanged)
        XCTAssertNil(draft.baseImageData)
        XCTAssertEqual(draft.imageSource, .imported)
    }

    func testLegacyCardJSONDecodesNewFieldsAsNil() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"title\":\"T\",\"message\":\"M\"}"
        let card = try JSONDecoder().decode(PresentationCard.self, from: Data(json.utf8))
        XCTAssertNil(card.illustrationPrompt)
        XCTAssertNil(card.originalImageData)
        XCTAssertNil(card.diagramKind)
    }

    func testDiagramRoundTripSkipsTitleBand() throws {
        // A diagram deck survives save → reopen → title edit without the
        // composer's band covering its edge labels.
        let raw = try XCTUnwrap(DiagramRenderer.render(
            DiagramSpec(kind: "fractionCircle", numbers: [2, 4], labels: ["2/4 = 1/2"])
        ))
        var draft = DraftCard(planned: PlannedCard(
            title: "Half", concept: "C", body: "B", illustrationPrompt: "P",
            diagram: DiagramSpec(kind: "fractionCircle", numbers: [2, 4], labels: ["2/4 = 1/2"])
        ))
        draft.baseImageData = raw
        draft.imageData = raw
        draft.imageSource = .diagram
        let card = makePresentationCard(from: draft)
        XCTAssertEqual(card.diagramKind, "fractionCircle")
        let stored = try JSONDecoder().decode(PresentationCard.self, from: JSONEncoder().encode(card))
        var back = DraftCard(from: stored)
        XCTAssertEqual(back.imageSource, .diagram)
        back.title = "Half, retitled"
        back.refreshDisplayArtwork()
        XCTAssertEqual(back.imageData, raw, "refresh must not burn a band over diagrams")
    }

    func testRefreshComposesGeneratedArt() throws {
        let base = try XCTUnwrap(tinyPNG())
        var draft = DraftCard(planned: PlannedCard(
            title: "T", concept: "C", body: "B", labels: ["a"], illustrationPrompt: "P"
        ))
        draft.baseImageData = base
        draft.imageData = base
        draft.imageSource = .generated
        draft.refreshDisplayArtwork()
        XCTAssertNotEqual(draft.imageData, base, "generated art keeps the title band on refresh")
    }

    func testFidelityCheckMeasuresVerbatimMatch() {
        let source = "Plants make food from sunlight. Leaves are green because of chlorophyll."
        let verbatim = FidelityCheck.verify(
            body: "Plants make food from sunlight! Leaves are green because of chlorophyll?",
            against: source
        )
        XCTAssertTrue(verbatim.matchesSource, "case/punctuation differences are not rewrites")
        XCTAssertEqual(verbatim.total, 2)
        let rewritten = FidelityCheck.verify(
            body: "Plants make food from sunlight. Photosynthesis was discovered in 1779 by Jan Ingenhousz.",
            against: source
        )
        XCTAssertFalse(rewritten.matchesSource)
        XCTAssertEqual(rewritten.matched, 1)
        XCTAssertEqual(rewritten.total, 2)
        XCTAssertEqual(FidelityCheck.verify(body: "", against: source).total, 0)
        XCTAssertEqual(FidelityCheck.verify(body: "Anything at all here.", against: "").matched, 0)
    }
}

final class PresentationCollectionTests: XCTestCase {
    func testLegacyDecksDecodeWithoutCollection() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"D\",\"cards\":[]}"
        let deck = try JSONDecoder().decode(Presentation.self, from: Data(json.utf8))
        XCTAssertNil(deck.collection)
        XCTAssertEqual(deck.name, "D")
    }

    func testCollectionRoundTrip() throws {
        let deck = Presentation(name: "D", collection: "History")
        let back = try JSONDecoder().decode(Presentation.self, from: JSONEncoder().encode(deck))
        XCTAssertEqual(back, deck)
    }

    func testStudioDeckDetection() {
        let studio = Presentation(name: "AI", cards: [
            PresentationCard(title: "T", message: "B", illustrationPrompt: "P"),
        ])
        XCTAssertTrue(studio.isStudioDeck)
        XCTAssertFalse(Presentation(name: "Hand", cards: [PresentationCard(title: "T", message: "B")]).isStudioDeck)
        XCTAssertFalse(Presentation(name: "Empty").isStudioDeck)
        XCTAssertFalse(Presentation.matteus6().isStudioDeck, "bundled decks are not Studio decks")
    }

    func testInstructionsRoundTrip() throws {
        let deck = Presentation(name: "AI", cards: [], studioOrigin: true, aiInstructions: "Use timelines.")
        let data = try JSONEncoder().encode(deck)
        let restored = try JSONDecoder().decode(Presentation.self, from: data)
        XCTAssertEqual(restored.aiInstructions, "Use timelines.")
    }

    func testLegacyDeckDecodesWithoutInstructions() throws {
        let json = """
            {"id": "\(UUID().uuidString)", "name": "Old", "cards": []}
            """
        let restored = try JSONDecoder().decode(Presentation.self, from: Data(json.utf8))
        XCTAssertNil(restored.aiInstructions)
        XCTAssertNil(restored.studioOrigin)
    }
}

private final class MockService: GenerationService, @unchecked Sendable {
    var plan: LessonPlan
    var imageData: Data
    var imagePrompts: [String] = []
    var imageStyles: [String] = []
    var planError: Error?
    var planFidelity: Fidelity?
    var planInstructions: String?

    init(plan: LessonPlan, imageData: Data) {
        self.plan = plan
        self.imageData = imageData
    }

    func planLesson(source: String, settings: GenerationSettings, fidelity: Fidelity, instructions: String) async throws -> LessonPlan {
        if let planError { throw planError }
        planFidelity = fidelity
        planInstructions = instructions
        return plan
    }

    var singleCard: PlannedCard?
    var singleCardError: Error?

    func planSingleCard(topic: String, settings: GenerationSettings) async throws -> PlannedCard {
        if let singleCardError { throw singleCardError }
        if let singleCard { return singleCard }
        guard let first = plan.cards.first else {
            throw GenerationError.invalidResponse("The model returned no card")
        }
        return first
    }

    func generateImage(prompt: String, style: String) async throws -> Data {
        imagePrompts.append(prompt)
        imageStyles.append(style)
        return imageData
    }

    var suggestion = "History"

    func suggestCollection(title: String, excerpt: String, collections: [String]) async throws -> String {
        suggestion
    }
}

private final class ProgressBox: @unchecked Sendable {
    var events: [GenerationProgress] = []
}

final class LessonGeneratorTests: XCTestCase {
    private func plan() -> LessonPlan {
        LessonPlan(lessonTitle: "L", cards: [
            PlannedCard(title: "Diagram card", concept: "C", body: "B", illustrationPrompt: "P1",
                        diagram: DiagramSpec(kind: "fractionCircle", numbers: [1, 2], labels: ["1/2"])),
            PlannedCard(title: "Art card", concept: "C", body: "B", illustrationPrompt: "P2"),
        ])
    }

    func testGeneratePrefersDiagramsAndReportsProgress() async throws {
        let art = try XCTUnwrap(tinyPNG())
        let service = MockService(plan: plan(), imageData: art)
        let box = ProgressBox()
        let drafts = try await LessonGenerator(service: service).generate(
            source: "x", settings: GenerationSettings()
        ) { progress in
            // Serial executor: generator awaits each step, no race.
            Task { @MainActor in box.events.append(progress) }
        }
        // Progress lands on the main actor; flush before asserting.
        await MainActor.run {}
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].imageSource, .diagram)
        XCTAssertEqual(drafts[1].imageSource, .generated)
        XCTAssertEqual(service.imagePrompts, ["P2"], "diagram card skips the image API")
        XCTAssertTrue(drafts.allSatisfy { $0.imageData != nil })
        let events = await MainActor.run { box.events }
        XCTAssertEqual(events.first, .planning)
        XCTAssertEqual(events.last, .finished)
        XCTAssertTrue(events.contains(.renderingImages(done: 0, total: 2)))
        XCTAssertTrue(events.contains(.renderingImages(done: 1, total: 2)))
    }

    func testDiagramShipsWithoutTitleBand() async throws {
        // The composer's bottom band covers diagram edge labels (e.g. the
        // fraction line), so diagrams ship as rendered; only free-form
        // art gets the title + label band.
        let art = try XCTUnwrap(tinyPNG())
        let service = MockService(plan: plan(), imageData: art)
        let drafts = try await LessonGenerator(service: service).generate(
            source: "x", settings: GenerationSettings(), onProgress: { _ in }
        )
        let raw = try XCTUnwrap(DiagramRenderer.render(
            DiagramSpec(kind: "fractionCircle", numbers: [1, 2], labels: ["1/2"])
        ))
        XCTAssertEqual(drafts[0].imageData, raw)
        XCTAssertNotEqual(drafts[1].imageData, art, "generated art keeps the composed band")
    }

    func testEmptyPromptSkipsImageAPIAndStaysTextOnly() async throws {
        // Faithful splits carry no illustration prompts: no image call,
        // no invented art, text-only draft.
        let plan = LessonPlan(lessonTitle: "L", cards: [
            PlannedCard(title: "T", concept: "C", body: "B", illustrationPrompt: "  "),
        ])
        let service = MockService(plan: plan, imageData: Data([9]))
        let drafts = try await LessonGenerator(service: service).generate(
            source: "x", settings: GenerationSettings(), fidelity: .faithful, onProgress: { _ in }
        )
        XCTAssertTrue(service.imagePrompts.isEmpty, "no prompt → no image API call")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].imageSource, .none)
        XCTAssertNil(drafts[0].imageData)
        XCTAssertNil(drafts[0].baseImageData)
        XCTAssertEqual(service.planFidelity, .faithful)
    }

    func testSourceImageAttachSkipsImageAPI() async throws {
        // Faithful-style card (empty prompt, imageRef): the original
        // artwork ships — no image call, no invented pixels.
        let art = try XCTUnwrap(tinyPNG())
        let plan = LessonPlan(lessonTitle: "L", cards: [
            PlannedCard(title: "T", concept: "C", body: "B", illustrationPrompt: "  ", imageRefs: [2]),
        ])
        let service = MockService(plan: plan, imageData: Data([9]))
        let sources = [SourceImage(index: 2, slide: 1, data: art)]
        let drafts = try await LessonGenerator(service: service).generate(
            source: "x", settings: GenerationSettings(), fidelity: .faithful,
            sourceImages: sources, onProgress: { _ in }
        )
        XCTAssertTrue(service.imagePrompts.isEmpty, "attached art needs no image call")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].imageSource, .imported)
        XCTAssertEqual(drafts[0].baseImageData, art)
        XCTAssertNotNil(drafts[0].imageData)
    }

    func testFirstResolvableRefWinsDanglingFallsBack() async throws {
        let art = try XCTUnwrap(tinyPNG())
        let plan = LessonPlan(lessonTitle: "L", cards: [
            PlannedCard(title: "A", concept: "", body: "B", illustrationPrompt: "", imageRefs: [9, 1]),
            PlannedCard(title: "B", concept: "", body: "C", illustrationPrompt: "", imageRefs: [9]),
        ])
        let service = MockService(plan: plan, imageData: Data([9]))
        let sources = [SourceImage(index: 1, slide: 1, data: art)]
        let drafts = try await LessonGenerator(service: service).generate(
            source: "x", settings: GenerationSettings(), fidelity: .faithful,
            sourceImages: sources, onProgress: { _ in }
        )
        XCTAssertEqual(drafts[0].imageSource, .imported)
        XCTAssertEqual(drafts[0].baseImageData, art)
        XCTAssertEqual(drafts[1].imageSource, .none, "dangling refs fall back to text-only")
        XCTAssertNil(drafts[1].imageData)
        XCTAssertTrue(service.imagePrompts.isEmpty)
    }

    func testInstructionsReachThePlanner() async throws {
        let plan = LessonPlan(lessonTitle: "L", cards: [
            PlannedCard(title: "T", concept: "C", body: "B", illustrationPrompt: "P"),
        ])
        let service = MockService(plan: plan, imageData: Data([9]))
        _ = try await LessonGenerator(service: service).generate(
            source: "x", settings: GenerationSettings(), instructions: "Use timelines.",
            onProgress: { _ in }
        )
        XCTAssertEqual(service.planInstructions, "Use timelines.")
    }

    func testPlanErrorPropagates() async {
        let service = MockService(plan: plan(), imageData: Data())
        service.planError = GenerationError.httpStatus(code: 500, body: nil)
        do {
            _ = try await LessonGenerator(service: service).generate(
                source: "x", settings: GenerationSettings(), onProgress: { _ in }
            )
            XCTFail("expected error")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .httpStatus(code: 500, body: nil))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

final class LiveCardComposerTests: XCTestCase {
    private func planned(
        title: String = "Sky",
        body: String = "Blue light scatters most.",
        illustrationPrompt: String = "Blue sky over hills",
        diagram: DiagramSpec? = nil
    ) -> PlannedCard {
        PlannedCard(
            title: title, concept: "Scattering", body: body,
            illustrationPrompt: illustrationPrompt, diagram: diagram
        )
    }

    private func service(singleCard: PlannedCard? = nil) throws -> MockService {
        let art = try XCTUnwrap(tinyPNG())
        let service = MockService(plan: LessonPlan(lessonTitle: "L", cards: []), imageData: art)
        service.singleCard = singleCard ?? planned()
        return service
    }

    func testTextAndPictureMapsTextAndGeneratesArt() async throws {
        let service = try service()
        let card = try await LiveCardComposer(service: service).generate(
            prompt: "why is the sky blue", mode: .textAndPicture, settings: GenerationSettings()
        )
        XCTAssertEqual(card.title, "Sky")
        XCTAssertTrue(card.message.hasPrefix("Blue light scatters most."))
        XCTAssertNotNil(card.imageData)
        XCTAssertEqual(card.illustrationPrompt, "Blue sky over hills")
        XCTAssertEqual(service.imagePrompts, ["Blue sky over hills"])
    }

    func testTextOnlySkipsImageAPI() async throws {
        let service = try service()
        let card = try await LiveCardComposer(service: service).generate(
            prompt: "why is the sky blue", mode: .textOnly, settings: GenerationSettings()
        )
        XCTAssertEqual(card.title, "Sky")
        XCTAssertNil(card.imageData)
        XCTAssertTrue(service.imagePrompts.isEmpty)
    }

    func testPictureOnlyUsesPromptAsArtPrompt() async throws {
        let service = try service()
        let card = try await LiveCardComposer(service: service).generate(
            prompt: "a red boat", mode: .pictureOnly, settings: GenerationSettings()
        )
        XCTAssertEqual(card.title, "", "no prompt text on a picture-only card")
        XCTAssertEqual(card.message, "")
        XCTAssertEqual(card.illustrationPrompt, "a red boat")
        XCTAssertNotNil(card.imageData)
        XCTAssertNotNil(card.originalImageData)
        XCTAssertEqual(service.imagePrompts, ["a red boat"])
    }

    func testDiagramPreferredOverImageAPI() async throws {
        let service = try service(singleCard: planned(
            illustrationPrompt: "P", diagram: DiagramSpec(kind: "fractionCircle", numbers: [1, 2], labels: ["1/2"])
        ))
        let card = try await LiveCardComposer(service: service).generate(
            prompt: "half", mode: .textAndPicture, settings: GenerationSettings()
        )
        XCTAssertNotNil(card.imageData)
        XCTAssertEqual(card.diagramKind, "fractionCircle")
        XCTAssertTrue(service.imagePrompts.isEmpty)
    }

    func testEmptyIllustrationPromptStaysTextOnly() async throws {
        let service = try service(singleCard: planned(illustrationPrompt: "  "))
        let card = try await LiveCardComposer(service: service).generate(
            prompt: "quiet", mode: .textAndPicture, settings: GenerationSettings()
        )
        XCTAssertNil(card.imageData)
        XCTAssertTrue(service.imagePrompts.isEmpty)
    }

    func testEmptyPromptThrows() async throws {
        let service = try service()
        do {
            _ = try await LiveCardComposer(service: service).generate(
                prompt: "  ", mode: .textOnly, settings: GenerationSettings()
            )
            XCTFail("expected invalidResponse")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .invalidResponse("Empty live prompt"))
        }
    }

    func testPlanErrorPropagates() async throws {
        let service = try service()
        service.singleCardError = GenerationError.network("down")
        do {
            _ = try await LiveCardComposer(service: service).generate(
                prompt: "x", mode: .textOnly, settings: GenerationSettings()
            )
            XCTFail("expected network error")
        } catch let error as GenerationError {
            XCTAssertEqual(error, .network("down"))
        }
    }

    func testSingleCardPromptContractsOneFittedCard() {
        let prompt = MetaModelClient.singleCardPrompt(settings: GenerationSettings())
        XCTAssertTrue(prompt.contains("exactly ONE card"))
        XCTAssertTrue(prompt.contains("at most 220 characters"))
        XCTAssertTrue(prompt.contains("at most 40 characters"))
    }

    func testSingleCardSchemaRequiresExactlyOneCard() {
        let schema = MetaModelClient.planSchema(cardCount: 1)
        let properties = schema["properties"] as? [String: Any]
        let cards = properties?["cards"] as? [String: Any]
        XCTAssertEqual(cards?["minItems"] as? Int, 1)
        XCTAssertEqual(cards?["maxItems"] as? Int, 1)
    }

    func testArtStylePresetsAreDistinctAndVectorIsLegacyDefault() {
        let names = AIArtStyle.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "display names must be distinct")
        let prompts = AIArtStyle.allCases.map(\.stylePrompt)
        XCTAssertTrue(prompts.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(prompts).count, prompts.count, "style prompts must be distinct")
        XCTAssertEqual(AIArtStyle.vector.stylePrompt, GenerationSettings().illustrationStyle)
    }

    func testComposerPassesIllustrationStyleToImageCall() async throws {
        let service = try service()
        var settings = GenerationSettings()
        settings.illustrationStyle = AIArtStyle.photorealistic.stylePrompt
        _ = try await LiveCardComposer(service: service).generate(
            prompt: "a red boat", mode: .pictureOnly, settings: settings
        )
        XCTAssertEqual(service.imageStyles, [AIArtStyle.photorealistic.stylePrompt])
    }
}

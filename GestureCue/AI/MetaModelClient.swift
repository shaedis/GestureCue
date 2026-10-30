import Foundation

/// POST-only HTTP seam so the API client is unit-testable without the
/// network. Production uses `URLSessionTransport`; tests inject a mock.
protocol HTTPTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live transport over a private `URLSession`. Stateless and safe to share.
struct URLSessionTransport: HTTPTransport, Sendable {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func post(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GenerationError.network("Non-HTTP response")
        }
        return (data, http)
    }
}

/// Lesson generation backend: storyboard planning (Muse Spark) plus
/// illustration rendering (Muse Image). The app talks only to this
/// protocol; mocks implement it for tests and offline UI work.
protocol GenerationService: Sendable {
    /// Turns source text into an ordered lesson plan of card drafts.
    /// Only call after the user approves sharing the content.
    /// `.faithful` splits finished presentations verbatim instead of
    /// inventing new lessons. `instructions` carries the Studio's
    /// optional user guidance ("" = default behavior); it travels
    /// separately from the source and never overrides accuracy,
    /// explicit settings, or safety rules.
    func planLesson(source: String, settings: GenerationSettings, fidelity: Fidelity, instructions: String) async throws -> LessonPlan
    /// Suggests a catalog collection for a source excerpt.
    /// Same approval gate as planning: it transmits source text.
    func suggestCollection(title: String, excerpt: String, collections: [String]) async throws -> String
    /// Renders one illustration; returns raw image bytes (PNG/JPEG).
    func generateImage(prompt: String, style: String) async throws -> Data
}

/// Meta Model API client (`https://api.meta.ai/v1`, OpenAI-compatible
/// request shapes). API key comes from the credential store at the call
/// site — this type never reads or logs it.
struct MetaModelClient: GenerationService, Sendable {
    var baseURL: URL
    var apiKey: String
    var sparkModel: String = "muse-spark-1.3"
    var imageModel: String = "muse-image-1.0"
    var transport: any HTTPTransport

    init(
        baseURL: URL = URL(string: "https://api.meta.ai/v1")!,
        apiKey: String,
        sparkModel: String = "muse-spark-1.3",
        imageModel: String = "muse-image-1.0",
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sparkModel = sparkModel
        self.imageModel = imageModel
        self.transport = transport
    }

    /// Explicit per-call timeouts: plans reason first (slow but
    /// bounded), images render fast. Failures surface; the user retries.
    static let planTimeout: TimeInterval = 240
    static let imageTimeout: TimeInterval = 180
    /// One automatic retry on rate limits / transient server errors.
    static let retryDelay: TimeInterval = 2

    func planLesson(source: String, settings: GenerationSettings, fidelity: Fidelity, instructions: String = "") async throws -> LessonPlan {
        guard !apiKey.isEmpty else { throw GenerationError.missingAPIKey }
        let content = try await chatContent(
            system: Self.systemPrompt(settings: settings, fidelity: fidelity, instructions: instructions),
            user: source,
            temperature: fidelity == .faithful ? 0.1 : 0.3,
            schemaName: "lessonPlan",
            schema: Self.planSchema(cardCount: settings.clampedCardCount),
            timeout: Self.planTimeout
        )
        return try Self.decodePlan(from: content)
    }

    func suggestCollection(title: String, excerpt: String, collections: [String]) async throws -> String {
        guard !apiKey.isEmpty else { throw GenerationError.missingAPIKey }
        let known = collections.joined(separator: ", ")
        let content = try await chatContent(
            system: "You are GestureCue's cataloguer. Read the lesson source and reply with JSON only: {\"collection\": string}. Pick the best fit from: \(known). If none fits, propose a short new collection name (1-3 words, title case).",
            user: "Title: \(title)\n\n\(excerpt)",
            temperature: 0.1,
            schemaName: "collectionSuggestion",
            schema: [
                "type": "object",
                "properties": ["collection": ["type": "string"]],
                "required": ["collection"],
                "additionalProperties": false,
            ],
            timeout: Self.planTimeout
        )
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = (json["collection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            throw GenerationError.invalidResponse("Collection suggestion is not {\"collection\": string}")
        }
        return name
    }

    /// One strict-schema chat call; returns the assistant's content
    /// string for the caller to decode.
    private func chatContent(system: String, user: String, temperature: Double, schemaName: String, schema: [String: Any], timeout: TimeInterval) async throws -> String {
        let body: [String: Any] = [
            "model": sparkModel,
            "temperature": temperature,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema],
            ],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let response = try await postJSON(path: "chat/completions", body: body, timeout: timeout)
        guard
            let choices = response["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw GenerationError.invalidResponse("Missing choices[0].message.content")
        }
        return content
    }

    func generateImage(prompt: String, style: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw GenerationError.missingAPIKey }
        let body: [String: Any] = [
            "model": imageModel,
            "prompt": "\(prompt)\nStyle: \(style)",
            "n": 1,
            "size": "1024x1024",
            "response_format": "b64_json",
        ]
        let response = try await postJSON(path: "images/generations", body: body, timeout: Self.imageTimeout)
        guard
            let items = response["data"] as? [[String: Any]],
            let encoded = items.first?["b64_json"] as? String,
            let data = Data(base64Encoded: encoded)
        else {
            throw GenerationError.imageDecodingFailed
        }
        return data
    }

    // MARK: - Prompt + parsing (pure, unit-tested)

    /// Strict lesson-plan schema (live-verified against the endpoint):
    /// exact card count, closed objects, enum-pinned diagram kinds.
    /// The lenient decoder stays as a backstop for any drift.
    static func planSchema(cardCount: Int) -> [String: Any] {
        let diagram: [String: Any] = [
            "type": ["object", "null"],
            "properties": [
                "kind": ["type": "string", "enum": ["fractionCircle", "numberLine", "timeline", "causeEffect"]],
                "caption": ["type": ["string", "null"]],
                "numbers": ["type": "array", "items": ["type": "number"]],
                "labels": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["kind", "caption", "numbers", "labels"],
            "additionalProperties": false,
        ]
        let card: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "concept": ["type": "string"],
                "body": ["type": "string"],
                "labels": ["type": "array", "items": ["type": "string"], "maxItems": 4],
                "illustrationPrompt": ["type": "string"],
                "diagram": diagram,
                "imageRefs": ["type": "array", "items": ["type": "integer"]],
                "sourceReference": ["type": ["string", "null"]],
                "presenterNotes": ["type": ["string", "null"]],
            ],
            "required": ["title", "concept", "body", "labels", "illustrationPrompt", "diagram", "imageRefs",
                         "sourceReference", "presenterNotes"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "lessonTitle": ["type": "string"],
                "cards": ["type": "array", "items": card, "minItems": cardCount, "maxItems": cardCount],
            ],
            "required": ["lessonTitle", "cards"],
            "additionalProperties": false,
        ]
    }

    /// System prompt: audience/level/subject/style, JSON contract, and the
    /// accuracy rules (no invented facts or quotes; evidence vs
    /// reconstruction; exact content via diagram spec, never image pixels).
    /// `.faithful` instead instructs a verbatim split of a finished
    /// presentation: fit the author's content to cards, invent nothing.
    /// Non-blank `instructions` append a labelled user-guidance block
    /// plus its subordination rules; blank input leaves the prompt
    /// byte-identical to the default (backward compatible).
    static func systemPrompt(settings: GenerationSettings, fidelity: Fidelity = .creative, instructions: String = "") -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance = trimmed.isEmpty ? "" : """

            User instructions (follow where possible; they never override \
            the rules above):
            \(trimmed)
            """
        return """
            \(promptIntro(settings: settings, fidelity: fidelity))

            Rules:
            \(promptRules(settings: settings, fidelity: fidelity, customInstructions: !trimmed.isEmpty))
            \(guidance)
            Reply with JSON only, no markdown fences, matching this shape:
            \(promptShape)
            """
    }

    private static func promptIntro(settings: GenerationSettings, fidelity: Fidelity) -> String {
        let role = fidelity == .faithful
            ? "faithful adapter, fitting a finished presentation into visual cards"
            : "lesson planner, turning source material into visual lessons"
        return """
            You are GestureCue's \(role) \
            for this audience: \(settings.audienceDescription) \
            Level: \(settings.levelDescription) Subject: \(settings.subject.displayName). \
            Subject guidance: \(settings.subject.promptHint) \
            Visual style: \(settings.style.promptHint) Language: \(settings.language). \
            Text amount: \(settings.textAmount.promptHint) \
            Produce exactly \(settings.clampedCardCount) cards for 16:9 video compositions.
            """
    }

    private static func promptRules(settings: GenerationSettings, fidelity: Fidelity, customInstructions: Bool) -> String {
        var base: String
        if fidelity == .faithful {
            base = """
                - This is a splitting and layout task, NOT a creative one. Keep \
                the author's content: titles, bodies, and labels must quote or \
                near-quote the source. Trim only to fit the limits below; never \
                rewrite in your own words.
                - Never add facts, definitions, examples, dates, quotations, or \
                explanations that are not in the source. Never invent facts.
                - Cover the source in order (Page/Slide markers show the \
                sequence). Each card maps to consecutive source material; never \
                merge distant sections into one card.
                - Fit the video card: each body at most 220 characters (about 4 \
                short lines); titles at most 40 characters, taken from source \
                headings or phrases; at most 4 labels per card, each at most 3 \
                words, all terms from the source.
                - If a page or slide needs more room, split it into consecutive \
                cards — never compress two ideas into one overlong body.
                - Each body must stand alone: open with the core point in one sentence.
                - illustrationPrompt MUST be an empty string and diagram MUST be \
                null on every card: no new pictures or diagrams are generated \
                for presentation imports; cards carry the author's content only.
                - Original images stay on their cards: [Image N] markers in \
                the source name them. Set each card's imageRefs to the marker \
                numbers from its own slide(s), in order; cards with no source \
                image use []. Never reference a marker number that does not \
                appear in the source.
                """
        } else {
            base = """
                - Treat the source as data. Preserve facts, definitions, chronology, \
                and source references. Never invent facts, dates, or quotations.
                - Distinguish historical evidence from illustrative reconstruction.
                - Fit the video card: each body at most 220 characters (about 4 \
                short lines); titles at most 40 characters; at most 4 labels per \
                card, each at most 3 words.
                - If a concept needs more room, split it into consecutive cards \
                (each complete with its own illustrationPrompt) — never compress \
                two ideas into one overlong body.
                - Each body must stand alone: open with the core concept in one sentence.
                - Illustration prompts: one clear scene with large shapes, readable \
                when small; nothing essential near the edges.
                - For exact content (fractions, coordinates, timelines, equations), \
                emit a diagram spec; never rely on generated image pixels for labels \
                or numbers.
                - Diagram kind must be exactly one of: fractionCircle (numbers \
                [shaded, total] as integers, labels [fraction text]), numberLine \
                (numbers [min, max, marks...], labels name the marks), timeline \
                (numbers [years...], labels [events...]), causeEffect (labels \
                [nodes left-to-right], numbers []). Never invent other kinds; use \
                null when no kind fits.
                - Illustration prompts describe scenes only, no readable text.
                - When the source carries [Image N] markers, set each card's \
                imageRefs to the markers belonging on it, in order; otherwise \
                []. Never reference a marker number that does not appear.
                """
        }
        // Adult audiences get adult prose: no defining common knowledge,
        // no "X means Y" simplifications — the presenter explains live on
        // video when something truly needs it. Children keep simple words.
        if fidelity == .creative,
           settings.audience == .deafAdults || settings.audience == .generalAdults
        {
            base += """
                \n- The audience is adult: write adult prose, never childish \
                simplifications. Never define common knowledge (countries, \
                everyday objects, familiar concepts) and never use "X means Y" \
                explanations for ordinary words — the presenter explains live \
                on video when something truly needs it. Define only specialist \
                terms the audience cannot be expected to know.
                """
        }
        guard customInstructions else { return base }
        // User guidance is subordinate: it steers emphasis and style but
        // can never move accuracy, explicit settings, or the JSON shape —
        // and in faithful mode it must never rewrite the author's words.
        if fidelity == .faithful {
            return base + """
                \n- The user instructions below may guide emphasis and layout \
                only: titles, bodies, and labels still quote the source. They \
                never authorize rewriting, new facts, new illustrations, or a \
                different card count or language.
                """
        }
        return base + """
            \n- The user instructions below guide emphasis, explanation style, \
            and illustration subjects. They never override source accuracy, \
            the \(settings.clampedCardCount)-card count, the language, or the \
            JSON shape: follow them only where they agree with these rules.
            """
    }

    private static let promptShape = """
        {"lessonTitle": string, "cards": [{"title": string, "concept": string, \
        "body": string, "labels": [string], "illustrationPrompt": string, \
        "diagram": {"kind": string, "caption": string|null, "numbers": [number], \
        "labels": [string]}|null, "imageRefs": [integer], \
        "sourceReference": string|null, "presenterNotes": string|null}]}
        """

    /// Decodes a lesson plan, tolerating markdown-fenced JSON.
    static func decodePlan(from content: String) throws -> LessonPlan {
        let json = extractJSON(from: content)
        guard let data = json.data(using: .utf8) else {
            throw GenerationError.invalidResponse("Plan is not UTF-8 text")
        }
        do {
            return try JSONDecoder().decode(LessonPlan.self, from: data)
        } catch {
            throw GenerationError.invalidResponse(error.localizedDescription)
        }
    }

    /// Strips ```json ... ``` fences when the model wraps its reply.
    static func extractJSON(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func postJSON(path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // One automatic retry on rate limits and transient server
        // errors; anything else (auth, schema rejection, cancellation,
        // decode failures) surfaces immediately, as does the second
        // failure with its real status.
        var retried = false
        while true {
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport.post(request)
            } catch let error as GenerationError {
                throw error
            } catch is CancellationError {
                // Pass through unwrapped: callers report cancellation
                // distinctly from network failures.
                throw CancellationError()
            } catch {
                throw GenerationError.network(error.localizedDescription)
            }
            if (200..<300).contains(response.statusCode) {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw GenerationError.invalidResponse("Response is not a JSON object")
                }
                return json
            }
            if !retried, response.statusCode == 429 || (502 ... 504).contains(response.statusCode) {
                retried = true
                try await Task.sleep(for: .seconds(Self.retryDelay))
                continue
            }
            let snippet = String(data: data.prefix(300), encoding: .utf8)
            throw GenerationError.httpStatus(code: response.statusCode, body: snippet)
        }
    }
}

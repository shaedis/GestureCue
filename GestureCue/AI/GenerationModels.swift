import Foundation

/// Target audience for generated lessons. Audience shapes vocabulary,
/// pacing, and visual density — never assume identical needs.
enum AIAudience: String, CaseIterable, Codable, Sendable {
    case deafAdults
    case deafChildren
    case children
    case generalAdults
    case custom

    var displayName: String {
        switch self {
        case .deafAdults: "Deaf / hard-of-hearing adults"
        case .deafChildren: "Deaf / hard-of-hearing children"
        case .children: "Children (general education)"
        case .generalAdults: "General adult education"
        case .custom: "Custom audience"
        }
    }

    /// One-line audience guidance for the generation prompt.
    var promptHint: String {
        switch self {
        case .deafAdults: "Deaf and hard-of-hearing adults; clear adult written language, visual-first explanations, respectful and never condescending."
        case .deafChildren: "Deaf and hard-of-hearing children; simple sentences, friendly visuals, one idea per card."
        case .children: "Children in general education; playful tone, concrete everyday examples."
        case .generalAdults: "General adult education; concise, respectful, no condescension."
        case .custom: "Custom audience"
        }
    }
}

/// Educational level for generated lessons.
enum AIEducationLevel: String, CaseIterable, Codable, Sendable {
    case beginner
    case intermediate
    case advanced
    case custom

    var displayName: String {
        switch self {
        case .beginner: "Beginner"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        case .custom: "Custom age / grade"
        }
    }

    var promptHint: String {
        switch self {
        case .beginner: "Beginner: explain difficult ideas in plain words; assume everyday general knowledge and never define common terms such as countries or everyday objects."
        case .intermediate: "Intermediate: some background assumed, connect to known concepts."
        case .advanced: "Advanced: precise terminology, relationships and edge cases."
        case .custom: "Custom level"
        }
    }
}

/// Lesson subject. History, mathematics, and Bible get dedicated visual
/// treatment (timelines, deterministic diagrams, verse-accurate cards);
/// the rest share the general illustrated-lesson pipeline.
enum AISubject: String, CaseIterable, Codable, Sendable {
    case history
    case mathematics
    case science
    case geography
    case bible
    case other

    var displayName: String {
        switch self {
        case .history: "History"
        case .mathematics: "Mathematics"
        case .science: "Science"
        case .geography: "Geography"
        case .bible: "Bible / Religious"
        case .other: "Other"
        }
    }

    /// Subject-specific accuracy guidance for the generation prompt.
    var promptHint: String {
        switch self {
        case .history:
            "Keep chronology exact; separate historical evidence from illustrative reconstruction."
        case .mathematics:
            "State every number exactly; put exact content in diagram specs."
        case .science:
            "Define terms before use; causes before effects."
        case .geography:
            "Name places precisely; favor spatial relations over lists."
        case .bible:
            "Quote verse text word-for-word exactly as given in the source, citing book, chapter, and verse; clearly separate Scripture quotation from explanation; reverent tone; illustrations are reverent reconstructions, never presented as documentary."
        case .other:
            "Follow the source closely."
        }
    }
}

/// Render style for generated pictures: presets so presenters get a
/// good look without writing style prompts themselves. The prompt
/// travels as the image call's style line; scenes stay edge-safe
/// (side panels crop) and carry no readable text.
enum AIArtStyle: String, CaseIterable, Codable, Sendable {
    case vector
    case photorealistic
    case animated
    case watercolor
    case comic
    case pencil

    var displayName: String {
        switch self {
        case .vector: "Flat vector"
        case .photorealistic: "Photorealistic"
        case .animated: "Animated 3D"
        case .watercolor: "Watercolor"
        case .comic: "Comic book"
        case .pencil: "Pencil sketch"
        }
    }

    var stylePrompt: String {
        switch self {
        case .vector:
            "Warm flat vector illustration, consistent characters and palette"
        case .photorealistic:
            "Photorealistic photo, natural light, sharp focus, balanced composition with margin around the subject"
        case .animated:
            "Cheerful 3D animated film still, soft volumetric light, expressive characters"
        case .watercolor:
            "Soft watercolor illustration, gentle washes, light background"
        case .comic:
            "Bold comic-book illustration, clean ink lines, flat colors"
        case .pencil:
            "Detailed pencil sketch, soft shading, light paper background"
        }
    }
}

/// Visual presentation style for the lesson.
enum AIVisualStyle: String, CaseIterable, Codable, Sendable {
    case story
    case timeline
    case mathSteps
    case process
    case comparison
    case conceptMap
    case infographic
    case mixed

    var displayName: String {
        switch self {
        case .story: "Illustrated story"
        case .timeline: "Historical timeline"
        case .mathSteps: "Step-by-step math"
        case .process: "Process diagram"
        case .comparison: "Comparison diagram"
        case .conceptMap: "Concept map"
        case .infographic: "Infographic"
        case .mixed: "Mixed visual lesson"
        }
    }

    var promptHint: String {
        switch self {
        case .story: "Tell it as an illustrated story with scenes."
        case .timeline: "Organize along a visual timeline."
        case .mathSteps: "Build understanding one visual step at a time."
        case .process: "Show the process as a diagram with stages."
        case .comparison: "Contrast with before/after or side-by-side views."
        case .conceptMap: "Map concepts and their relationships."
        case .infographic: "Dense, poster-like facts with icons."
        case .mixed: "Mix styles per card as each concept demands."
        }
    }
}

/// How much accompanying text each card carries.
enum AITextAmount: String, CaseIterable, Codable, Sendable {
    case concise
    case balanced
    case detailed

    var displayName: String {
        switch self {
        case .concise: "Concise"
        case .balanced: "Balanced"
        case .detailed: "Detailed"
        }
    }

    var promptHint: String {
        switch self {
        case .concise: "Minimal text: labels and one short paragraph per card."
        case .balanced: "A few short paragraphs per card plus labels."
        case .detailed: "Fuller explanations; still readable at video size."
        }
    }
}

/// One image extracted from a presentation import. Plans reference
/// these by index so original artwork lands on the right cards.
struct SourceImage: Sendable, Equatable {
    /// 1-based global order, as shown in `[Image N]` source markers.
    var index: Int
    /// Originating slide/page number.
    var slide: Int
    var data: Data
}

/// How strictly the plan must stick to the source. Finished
/// presentations (PDF/PowerPoint) import as `.faithful`: the model
/// splits and fits the author's content instead of inventing new
/// lessons. Derived from the source kind per import, never persisted.
enum Fidelity: String, CaseIterable, Sendable, Equatable {
    case creative
    case faithful

    var displayName: String {
        switch self {
        case .creative: "Visual Educational"
        case .faithful: "Faithful Presentation"
        }
    }

    var caption: String {
        switch self {
        case .creative:
            "Transforms source into an illustrated lesson: new explanations, diagrams, and artwork."
        case .faithful:
            "Splits the source verbatim into video cards: no rewritten text, no new art."
        }
    }
}

/// Catalog collections: built-in buckets plus user/model-created ones.
/// Resolving is case-insensitive so "bible" and "Bible" stay one bucket.
struct CollectionCatalog: Sendable, Equatable {
    static let builtin = ["History", "Mathematics", "Science", "Bible", "Children's Education", "Deaf Education", "Diverse"]
    var custom: [String] = []

    var all: [String] { Self.builtin + custom }

    /// Canonical bucket for a suggestion: the existing entry when it
    /// matches (any case), otherwise the trimmed suggestion itself as a
    /// new bucket. Empty suggestions resolve to "" (caller ignores).
    func resolve(_ suggestion: String) -> (name: String, isNew: Bool) {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", false) }
        if let known = all.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return (known, false)
        }
        return (trimmed, true)
    }

    mutating func addCustom(_ name: String) {
        guard !name.isEmpty,
              !all.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        custom.append(name)
    }
}

/// Counts presentation segments ("## Slide N" / "## Page N" markers)
/// in source text so the Studio can warn when the card count would
/// merge slides. Exact marker match only: pasted prose never trips it.
/// Pure for testing.
enum SourceSegments: Sendable {
    static func count(in text: String) -> Int {
        var count = 0
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## Slide ") || trimmed.hasPrefix("## Page ") {
                count += 1
            }
        }
        return count
    }
}

/// Complete generation request configuration, as chosen in the Studio.
/// Persisted between launches; every field feeds the system prompt.
struct GenerationSettings: Codable, Sendable, Equatable {
    var audience: AIAudience = .deafAdults
    var audienceCustom: String = ""
    var level: AIEducationLevel = .beginner
    var levelCustom: String = ""
    var subject: AISubject = .history
    var style: AIVisualStyle = .mixed
    var language: String = "English"
    var cardCount: Int = 5
    var illustrationStyle: String = "Warm flat vector illustration, consistent characters and palette"
    var textAmount: AITextAmount = .balanced

    /// Clamped card count for the request (3...30).
    var clampedCardCount: Int { min(max(cardCount, 3), 30) }

    var audienceDescription: String {
        audience == .custom && !audienceCustom.isEmpty ? audienceCustom : audience.promptHint
    }

    var levelDescription: String {
        level == .custom && !levelCustom.isEmpty ? levelCustom : level.promptHint
    }
}

/// One planned card, as returned by Muse Spark in the lesson plan.
/// The app turns these into editable drafts; nothing is final until the
/// user reviews and approves it.
struct PlannedCard: Codable, Sendable, Equatable {
    var title: String
    var concept: String
    var body: String
    var labels: [String]
    /// Image prompt for Muse Image (contextual artwork, never the source
    /// of exact labels or numbers).
    var illustrationPrompt: String
    /// Deterministic diagram for exact content (math); nil = illustration only.
    var diagram: DiagramSpec?
    /// Original-extracted image indices (`[Image N]` markers) belonging
    /// on this card; the first resolvable one ships as its artwork.
    var imageRefs: [Int]
    var sourceReference: String?
    var presenterNotes: String?

    init(
        title: String, concept: String, body: String, labels: [String] = [],
        illustrationPrompt: String, diagram: DiagramSpec? = nil,
        imageRefs: [Int] = [], sourceReference: String? = nil,
        presenterNotes: String? = nil
    ) {
        self.title = title
        self.concept = concept
        self.body = body
        self.labels = labels
        self.illustrationPrompt = illustrationPrompt
        self.diagram = diagram
        self.imageRefs = imageRefs
        self.sourceReference = sourceReference
        self.presenterNotes = presenterNotes
    }

    /// Lenient decode: the model may omit optional arrays/strings.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        title = try box.decode(String.self, forKey: .title)
        concept = try box.decodeIfPresent(String.self, forKey: .concept) ?? ""
        body = try box.decodeIfPresent(String.self, forKey: .body) ?? ""
        labels = try box.decodeIfPresent([String].self, forKey: .labels) ?? []
        illustrationPrompt = try box.decodeIfPresent(String.self, forKey: .illustrationPrompt) ?? ""
        diagram = try box.decodeIfPresent(DiagramSpec.self, forKey: .diagram)
        imageRefs = try box.decodeIfPresent([Int].self, forKey: .imageRefs) ?? []
        sourceReference = try box.decodeIfPresent(String.self, forKey: .sourceReference)
        presenterNotes = try box.decodeIfPresent(String.self, forKey: .presenterNotes)
    }
}

/// Full lesson plan: an ordered set of card drafts.
struct LessonPlan: Codable, Sendable, Equatable {
    var lessonTitle: String
    var cards: [PlannedCard]
}

/// Programmatic diagram specification: exact content (fractions,
/// number lines, timelines) is drawn deterministically by the app, never
/// trusted to image pixels. `kind` is an open string so new renderers
/// can be added without breaking stored plans; unknown kinds render as
/// illustration-only.
struct DiagramSpec: Codable, Sendable, Equatable {
    /// e.g. "fractionCircle", "numberLine", "barModel", "timeline".
    var kind: String
    var caption: String?
    var numbers: [Double]
    var labels: [String]

    init(kind: String, caption: String? = nil, numbers: [Double] = [], labels: [String] = []) {
        self.kind = kind
        self.caption = caption
        self.numbers = numbers
        self.labels = labels
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        kind = try box.decode(String.self, forKey: .kind)
        caption = try box.decodeIfPresent(String.self, forKey: .caption)
        numbers = try box.decodeIfPresent([Double].self, forKey: .numbers) ?? []
        labels = try box.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}

/// Generation pipeline failures. Never carries the API key.
enum GenerationError: Error, Sendable, Equatable {
    case missingAPIKey
    case httpStatus(code: Int, body: String?)
    case network(String)
    case invalidResponse(String)
    case imageDecodingFailed
    case keychain(String)
}

extension GenerationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No Meta API key set. Add one in the Studio to generate lessons."
        case let .httpStatus(code, _):
            switch code {
            case 401, 403:
                "The Meta API rejected the key (status \(code)). Check the key and try again."
            case 429:
                "The Meta API is rate-limiting requests (status 429, retried once). Wait a minute and try again."
            case 502, 503, 504:
                "The Meta API had a server error (status \(code), retried once). Try again shortly."
            default:
                "The Meta API returned status \(code). Check the key and try again."
            }
        case let .network(message):
            "Network error: \(message)"
        case let .invalidResponse(message):
            "The model returned unusable data: \(message)"
        case .imageDecodingFailed:
            "The generated illustration could not be decoded."
        case let .keychain(message):
            "Keychain error: \(message)"
        }
    }
}

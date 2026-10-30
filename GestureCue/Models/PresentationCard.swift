import Foundation

/// A short, accessible message shown to the audience on a large presentation card.
struct PresentationCard: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var message: String
    var detail: String?
    /// Optional picture (PNG/JPEG bytes) shown below the texts.
    var imageData: Data?
    /// Prompt that produced the artwork (nil for legacy/imported cards).
    /// Round-trips through the Studio so only edited prompts regenerate.
    var illustrationPrompt: String? = nil
    /// Raw artwork before title/label composition (nil for legacy cards).
    /// Lets text edits re-compose locally without a new API call.
    var originalImageData: Data? = nil
    /// Diagram kind when the artwork is a programmatic diagram (nil
    /// otherwise). Round-trips so re-imported diagrams skip the title
    /// band, which would cover their edge labels. Optional, so legacy
    /// catalog files without the key still decode.
    var diagramKind: String? = nil

    init(id: UUID = UUID(), title: String, message: String, detail: String? = nil, imageData: Data? = nil, illustrationPrompt: String? = nil, originalImageData: Data? = nil, diagramKind: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.detail = detail
        self.imageData = imageData
        self.illustrationPrompt = illustrationPrompt
        self.originalImageData = originalImageData
        self.diagramKind = diagramKind
    }

    /// Manually authored sample cards for milestone 1 (no AI generation yet).
    /// A constant so card identities stay stable across accesses. Each card
    /// ships with a bundled funny picture; missing resources degrade to no picture.
    static let samples: [PresentationCard] = {
        [
            PresentationCard(
                title: "Please watch the interpreter",
                message: "The next section is best followed in sign language.",
                detail: "Slides will pause briefly.",
                imageData: sampleArt(named: "sample-art-watch")
            ),
            PresentationCard(
                title: "Captions are on",
                message: "Live captions are showing on the side screen.",
                detail: "Please tell us if you cannot see them.",
                imageData: sampleArt(named: "sample-art-captions")
            ),
            PresentationCard(
                title: "Question time",
                message: "Raise your hand if you have a question.",
                detail: "The roaming microphone is coming to you.",
                imageData: sampleArt(named: "sample-art-questions")
            ),
            PresentationCard(
                title: "Break in 5 minutes",
                message: "We will pause for 10 minutes after this section.",
                detail: "Restrooms are down the hall on the left.",
                imageData: sampleArt(named: "sample-art-break")
            ),
        ]
    }()

    private static func sampleArt(named name: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
        return try? Data(contentsOf: url)
    }
}

import Foundation

/// A short, accessible message shown to the audience on a large presentation card.
struct PresentationCard: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var message: String
    var detail: String?
    /// Optional picture (PNG/JPEG bytes) shown below the texts.
    var imageData: Data?

    init(id: UUID = UUID(), title: String, message: String, detail: String? = nil, imageData: Data? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.detail = detail
        self.imageData = imageData
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

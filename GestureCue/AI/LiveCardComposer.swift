import Foundation

/// What a live prompt produces: generated text with a generated
/// picture, generated text alone, or a generated picture carrying the
/// prompt as its title (message stays empty so the picture takes the
/// card's image area).
enum LiveCardMode: String, CaseIterable, Sendable {
    case textAndPicture
    case textOnly
    case pictureOnly

    var displayName: String {
        switch self {
        case .textAndPicture: "Text + Picture"
        case .textOnly: "Text only"
        case .pictureOnly: "Picture only"
        }
    }
}

/// Builds one presentation-ready card from a live presenter prompt:
/// a single planned card (text modes) plus artwork — exact local
/// diagrams first, then one Muse Image call composed with the title —
/// or a bare picture from the prompt itself. Pure service logic; the
/// caller owns approval, progress, and showing the card.
struct LiveCardComposer: Sendable {
    var service: any GenerationService

    func generate(prompt: String, mode: LiveCardMode, settings: GenerationSettings) async throws -> PresentationCard {
        let topic = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            throw GenerationError.invalidResponse("Empty live prompt")
        }
        switch mode {
        case .pictureOnly:
            return try await pictureCard(topic: topic, settings: settings)
        case .textOnly, .textAndPicture:
            return try await plannedCard(
                topic: topic, withPicture: mode == .textAndPicture, settings: settings
            )
        }
    }

    private func pictureCard(topic: String, settings: GenerationSettings) async throws -> PresentationCard {
        let raw = try await service.generateImage(prompt: topic, style: settings.illustrationStyle)
        // No title or message: the video shows the picture alone. The
        // prompt survives only as illustration metadata (Studio
        // round-trip + regeneration); deck rows label it "Picture".
        return PresentationCard(
            title: "",
            message: "",
            imageData: IllustrationComposer.compose(imageData: raw, title: "", labels: []) ?? raw,
            illustrationPrompt: topic,
            originalImageData: raw
        )
    }

    private func plannedCard(topic: String, withPicture: Bool, settings: GenerationSettings) async throws -> PresentationCard {
        let planned = try await service.planSingleCard(topic: topic, settings: settings)
        var draft = DraftCard(planned: planned)
        if withPicture {
            if let spec = planned.diagram, let png = DiagramRenderer.render(spec) {
                draft.baseImageData = png
                draft.imageData = png
                draft.imageSource = .diagram
            } else if !planned.illustrationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let raw = try await service.generateImage(
                    prompt: planned.illustrationPrompt, style: settings.illustrationStyle
                )
                draft.baseImageData = raw
                draft.imageData = IllustrationComposer.compose(
                    imageData: raw, title: planned.title, labels: planned.labels
                ) ?? raw
                draft.imageSource = .generated
            } else {
                draft.imageSource = .none
            }
            draft.renderedIllustrationPrompt = planned.illustrationPrompt
        }
        return makePresentationCard(from: draft)
    }
}

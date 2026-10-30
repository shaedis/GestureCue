import Foundation

/// Generation pipeline progress for the Studio UI.
enum GenerationProgress: Sendable, Equatable {
    case planning
    case renderingImages(done: Int, total: Int)
    case finished
}

/// Runs one lesson generation: storyboard plan → per-card artwork →
/// editable drafts. Exact diagram specs render locally (no API cost,
/// always correct) and ship unmodified (self-labeled); cards whose plan
/// references extracted source images reattach the originals; the rest
/// get a Muse Image illustration composed with title + labels into one
/// cohesive visual — unless the plan carries no illustration prompt
/// (faithful presentation splits), which ship text-only with no image
/// call. Cooperative cancellation.
actor LessonGenerator {
    private let service: any GenerationService

    init(service: any GenerationService) {
        self.service = service
    }

    func generate(
        source: String, settings: GenerationSettings, fidelity: Fidelity = .creative,
        sourceImages: [SourceImage] = [], instructions: String = "",
        onProgress: @Sendable (GenerationProgress) -> Void
    ) async throws -> [DraftCard] {
        onProgress(.planning)
        try Task.checkCancellation()
        let plan = try await service.planLesson(source: source, settings: settings, fidelity: fidelity, instructions: instructions)
        var drafts: [DraftCard] = []
        drafts.reserveCapacity(plan.cards.count)
        for (index, planned) in plan.cards.enumerated() {
            try Task.checkCancellation()
            onProgress(.renderingImages(done: index, total: plan.cards.count))
            var draft = DraftCard(planned: planned)
            if let spec = planned.diagram, let png = DiagramRenderer.render(spec) {
                // Diagrams carry their own exact labels: never burn the
                // composer's title band over them (it covers edge labels
                // like the fraction line). Only free-form art is composed.
                draft.baseImageData = png
                draft.imageData = png
                draft.imageSource = .diagram
            } else if let attached = planned.imageRefs.lazy.compactMap({ ref in sourceImages.first(where: { $0.index == ref }) }).first {
                // Original artwork travels with its card (no image API
                // call): composed with the card's own title + labels like
                // any free-form art. Dangling refs resolve to nothing.
                draft.baseImageData = attached.data
                draft.imageData = IllustrationComposer.compose(
                    imageData: attached.data, title: planned.title, labels: planned.labels
                ) ?? attached.data
                draft.imageSource = .imported
            } else if planned.illustrationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // No prompt, no art: faithful splits (and any prompt-less
                // card) stay text-only instead of calling the image API
                // with nothing to draw.
                draft.imageSource = .none
            } else {
                let raw = try await service.generateImage(
                    prompt: planned.illustrationPrompt, style: settings.illustrationStyle
                )
                try Task.checkCancellation()
                draft.baseImageData = raw
                draft.imageData = IllustrationComposer.compose(
                    imageData: raw, title: planned.title, labels: planned.labels
                ) ?? raw
                draft.imageSource = .generated
            }
            draft.renderedIllustrationPrompt = planned.illustrationPrompt
            drafts.append(draft)
        }
        onProgress(.finished)
        return drafts
    }
}

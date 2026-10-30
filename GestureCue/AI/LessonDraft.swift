import Foundation

/// One editable draft card: a reviewed-then-approved copy of a planned
/// card plus its rendered artwork. Drafts live only in the Studio until
/// the user saves the lesson to the catalog; nothing here persists.
struct DraftCard: Identifiable, Sendable, Equatable {
    enum ImageSource: String, Sendable {
        case none
        case generated
        case diagram
        case imported
    }

    var id = UUID()
    var title: String
    var concept: String
    var body: String
    var labels: [String]
    var illustrationPrompt: String
    var diagram: DiagramSpec?
    var sourceReference: String
    var presenterNotes: String
    var imageData: Data?
    var imageSource: ImageSource = .none
    /// Raw artwork before composition (for free local text refresh).
    var baseImageData: Data?
    /// Prompt that produced the current artwork; compared for dirty tracking.
    var renderedIllustrationPrompt: String?

    /// True when the prompt was edited since the artwork was rendered (and
    /// is non-empty): exactly the cards "Regenerate changed" refreshes.
    var promptChanged: Bool {
        !illustrationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && illustrationPrompt != (renderedIllustrationPrompt ?? "")
    }

    /// Rebuilds display artwork from the stored base: diagrams are
    /// self-labeled and ship raw (the title band would cover edge
    /// labels like the fraction line); other art gets the composed
    /// title + label band. Pure so it stays unit-testable.
    mutating func refreshDisplayArtwork() {
        guard let base = baseImageData else { return }
        if imageSource == .diagram {
            imageData = base
        } else {
            imageData = IllustrationComposer.compose(
                imageData: base, title: title, labels: labels
            ) ?? base
        }
    }

    init(planned: PlannedCard) {
        title = planned.title
        concept = planned.concept
        body = planned.body
        labels = planned.labels
        illustrationPrompt = planned.illustrationPrompt
        diagram = planned.diagram
        sourceReference = planned.sourceReference ?? ""
        presenterNotes = planned.presenterNotes ?? ""
    }

    /// Re-imports a catalog card for adjustment: artwork and prompt travel
    /// along (when present) so untouched cards keep their pixels and only
    /// edited prompts regenerate. Detail lines parse back best-effort.
    init(from card: PresentationCard) {
        title = card.title
        body = card.message
        imageData = card.imageData
        baseImageData = card.originalImageData
        illustrationPrompt = card.illustrationPrompt ?? ""
        renderedIllustrationPrompt = card.illustrationPrompt
        if card.diagramKind != nil {
            imageSource = .diagram
        } else {
            imageSource = card.imageData == nil ? .none : .imported
        }
        concept = ""
        labels = []
        diagram = nil
        sourceReference = ""
        presenterNotes = ""
        var leftovers: [String] = []
        for line in (card.detail ?? "").components(separatedBy: .newlines) {
            if let value = line.removingPrefix("Concept: ") { concept = value }
            else if let value = line.removingPrefix("Source: ") { sourceReference = value }
            else if let value = line.removingPrefix("Notes: ") { presenterNotes = value }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { leftovers.append(line) }
        }
        if !leftovers.isEmpty {
            presenterNotes = (presenterNotes.isEmpty ? leftovers : [presenterNotes] + leftovers).joined(separator: "\n")
        }
    }

    /// Comma-joined labels for the single-line editor.
    var labelsText: String {
        get { labels.joined(separator: ", ") }
        set {
            labels = newValue.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }
    }
}

/// Converts an approved draft into a catalog card. Title/body/image flow
/// into the video composition; labels are burned into the artwork by the
/// composer (or appended to the message when there is no image); concept,
/// source, and notes travel in the panel-only detail field so nothing the
/// model wrote is lost.
func makePresentationCard(from draft: DraftCard) -> PresentationCard {
    var message = draft.body
    if draft.imageData == nil, !draft.labels.isEmpty {
        message += "\n" + draft.labels.joined(separator: " • ")
    }
    var detail: [String] = []
    if !draft.concept.isEmpty {
        detail.append("Concept: \(draft.concept)")
    }
    if !draft.sourceReference.isEmpty {
        detail.append("Source: \(draft.sourceReference)")
    }
    if !draft.presenterNotes.isEmpty {
        detail.append("Notes: \(draft.presenterNotes)")
    }
    return PresentationCard(
        title: draft.title,
        message: message,
        detail: detail.isEmpty ? nil : detail.joined(separator: "\n"),
        imageData: draft.imageData,
        illustrationPrompt: draft.illustrationPrompt.isEmpty ? nil : draft.illustrationPrompt,
        originalImageData: draft.baseImageData,
        diagramKind: draft.imageSource == .diagram ? draft.diagram?.kind : nil
    )
}

private extension String {
    /// Value after a "Prefix: " marker, or nil when absent.
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Verdict of a faithful card body against its source. Verbatim status
/// is MEASURED (sentence containment in the extracted source), never
/// assumed from the low sampling temperature.
struct FidelityVerdict: Sendable, Equatable {
    var matched: Int
    var total: Int
    var matchesSource: Bool { matched == total }
}

enum FidelityCheck: Sendable {
    /// Sentences (≥12 normalized characters) of `body` found verbatim
    /// in `source`. Comparison is case- and punctuation-insensitive so
    /// trimming quotes never counts as a rewrite.
    static func verify(body: String, against source: String) -> FidelityVerdict {
        let normSource = normalize(source)
        let sentences = body.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map(normalize).filter { $0.count >= 12 }
        guard !sentences.isEmpty else {
            return FidelityVerdict(matched: 0, total: 0)
        }
        let matched = sentences.filter { normSource.contains($0) }.count
        return FidelityVerdict(matched: matched, total: sentences.count)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

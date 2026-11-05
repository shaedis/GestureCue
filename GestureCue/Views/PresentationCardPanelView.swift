import AppKit
import SwiftUI

/// Deck/panel title: picture-only live cards carry no title text, so
/// rows and VoiceOver label them "Picture" instead of going blank.
private func displayTitle(_ card: PresentationCard) -> String {
    card.title.isEmpty ? "Picture" : card.title
}

/// Large readable presentation card with equivalent mouse and keyboard controls
/// (Show ↑, Hide Esc, Next →, Expand E) for every gesture action.
@MainActor
struct PresentationCardPanelView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox("Presentation Card") {
            VStack(spacing: 12) {
                presentationPicker
                cardArea
                controls
                pictureControls
                positionLine
                Divider()
                liveCardSection
            }
        }
        .sheet(isPresented: $viewModel.showingLibrary) {
            PresentationLibrarySheet(viewModel: viewModel)
                .frame(minWidth: 680, minHeight: 440)
        }
    }

    private var presentationPicker: some View {
        HStack {
            Picker("Presentation", selection: presentationSelection) {
                ForEach(viewModel.library.presentations) { deck in
                    Text(deck.name).tag(deck.id as UUID?)
                }
            }
            Button("Manage…") { viewModel.showingLibrary = true }
        }
    }

    private var presentationSelection: Binding<UUID?> {
        Binding(
            get: { viewModel.library.selectedID },
            set: { if let id = $0 { viewModel.selectPresentation(id) } }
        )
    }

    @ViewBuilder
    private var cardArea: some View {
        if viewModel.store.isVisible, let card = viewModel.store.currentCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(card.title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.black)
                Text(card.message)
                    .font(.system(size: 22))
                    .foregroundColor(.black.opacity(0.85))
                if let detail = card.detail {
                    Text(detail)
                        .font(.system(size: 17))
                        .foregroundColor(.black.opacity(0.65))
                }
                if let imageData = card.imageData, let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180)
                        .cornerRadius(8)
                        .accessibilityLabel("Card picture")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white)
                    .shadow(radius: 6)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Visible card: \(displayTitle(card)). \(card.message)")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Card hidden")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Show it with the \(showGestureName) gesture or the Show button.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.12))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Card hidden")
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { viewModel.perform(.showCard) } label: {
                Label("Show", systemImage: "eye")
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .buttonStyle(.borderedProminent)

            Button { viewModel.perform(.hideCard) } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button { viewModel.perform(.previousCard) } label: {
                Label("Previous", systemImage: "arrow.left.circle")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button { viewModel.perform(.nextCard) } label: {
                Label("Next", systemImage: "arrow.right.circle")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button { viewModel.perform(.toggleExpand) } label: {
                Label(viewModel.store.isExpanded ? "Collapse" : "Expand", systemImage: CardAction.toggleExpand.systemImage)
            }
            .keyboardShortcut("e", modifiers: [])
        }
    }

    private var pictureControls: some View {
        HStack(spacing: 10) {
            Button("Add Picture…") { viewModel.attachPictureViaPanel() }
            if viewModel.currentCardHasPicture {
                Button("Remove Picture") { viewModel.removePictureFromCurrentCard() }
            }
            Spacer()
            Button { viewModel.perform(.zoomOut) } label: {
                Label("Zoom out picture", systemImage: CardAction.zoomOut.systemImage)
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("-", modifiers: [])
            .disabled(!viewModel.currentCardHasPicture)
            Text(zoomPercentLabel)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(minWidth: 44)
            Button { viewModel.perform(.zoomIn) } label: {
                Label("Zoom in picture", systemImage: CardAction.zoomIn.systemImage)
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("+", modifiers: [])
            .disabled(!viewModel.currentCardHasPicture)
        }
    }

    private var zoomPercentLabel: String {
        let scale = viewModel.store.zoomScale(for: viewModel.store.currentCard?.id)
        return "\(Int(round(scale * 100)))%"
    }

    private var positionLine: some View {
        HStack {
            Text(viewModel.store.positionLabel)
            Spacer()
            Text(viewModel.store.isVisible ? "Visible" : "Hidden")
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Card \(viewModel.store.positionLabel), \(viewModel.store.isVisible ? "visible" : "hidden")")
    }

    /// Live composer: generate a card from a prompt (appended to the
    /// active deck and shown at once, Bottom flips to Left) or type
    /// a transient subtitle overlay live (deck untouched).
    private var liveCardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Card")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Prompt, e.g. why the sky is blue (Return generates, Shift+Return adds a line)")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $viewModel.livePrompt)
                .frame(height: 56)
                .disabled(viewModel.isLiveGenerating)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                .accessibilityLabel("Live generation prompt")
                .onKeyPress(.return) {
                    guard viewModel.canLiveGenerate else { return .ignored }
                    viewModel.liveGenerate()
                    return .handled
                }
            Picker("Live mode", selection: $viewModel.liveMode) {
                ForEach(LiveCardMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isLiveGenerating)
            Picker("Picture style", selection: $viewModel.liveArtStyle) {
                ForEach(AIArtStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)
            .disabled(viewModel.isLiveGenerating || viewModel.liveMode == .textOnly)
            HStack {
                if viewModel.isLiveGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") { viewModel.cancelLiveGeneration() }
                } else {
                    Button("Generate & Show") { viewModel.liveGenerate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canLiveGenerate)
                }
            }
            if let liveError = viewModel.liveError {
                Text(liveError)
                    .font(.callout)
                    .foregroundColor(.red)
            }
            Text("Generate sends this prompt to the Meta Model API (key from AI Studio).")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            Text("Type text to show live (Return for a new line)")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $viewModel.liveText)
                .frame(height: 48)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                .accessibilityLabel("Direct live text")
            HStack {
                Text("Size")
                Slider(
                    value: $viewModel.subtitleStyle.scale,
                    in: SubtitleStyle.minScale ... SubtitleStyle.maxScale, step: 0.05
                )
                .accessibilityLabel("Subtitle size")
                Text("\(Int(round(viewModel.subtitleStyle.scale * 100)))%")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 44)
            }
            HStack {
                ColorPicker("Text color", selection: subtitleColorBinding(\.textColor), supportsOpacity: true)
                ColorPicker("Background", selection: subtitleColorBinding(\.backgroundColor), supportsOpacity: true)
            }
            if viewModel.liveSubtitle != nil {
                Button("Clear") { viewModel.clearLiveSubtitle() }
            }
            Text("Typing shows live in the video as you type, without touching the deck or the shown card.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Bridges a style color to the ColorPickers (sRGB both ways).
    private func subtitleColorBinding(_ keyPath: WritableKeyPath<SubtitleStyle, SubtitleRGBA>) -> Binding<Color> {
        Binding(
            get: {
                let rgba = viewModel.subtitleStyle[keyPath: keyPath]
                return Color(red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
            },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                viewModel.subtitleStyle[keyPath: keyPath] = SubtitleRGBA(
                    red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha)
                )
            }
        )
    }

    private var showGestureName: String {
        viewModel.gestureMapping.first(where: { $0.value == .showCard })?.key.displayName ?? "assigned"
    }
}

/// Presentation catalog manager: decks on the left, the selected deck's
/// cards + editor on the right. Selecting a deck presents it immediately.
struct PresentationLibrarySheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCardID: UUID?

    var body: some View {
        HSplitView {
            deckList
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
            cardDetail
                .frame(minWidth: 400)
        }
        .padding(12)
    }

    private var deckList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presentations")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Selecting a deck presents it immediately.")
                .font(.caption)
                .foregroundColor(.secondary)
            List(viewModel.library.presentations, selection: deckSelection) { deck in
                VStack(alignment: .leading) {
                    Text(deck.name)
                    Text(collectionLine(for: deck))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .tag(deck.id)
            }
            HStack {
                Button("New Deck") { viewModel.addPresentation() }
                Button("Import…") { viewModel.importDeckViaPanel() }
                    .disabled(viewModel.isImporting)
                Spacer()
                Button("Delete") {
                    if let id = viewModel.library.selectedID {
                        viewModel.deletePresentation(id)
                    }
                }
                .disabled(viewModel.library.presentations.count <= 1)
            }
            if viewModel.isImporting {
                Text("Importing…")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else if let error = viewModel.importError {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
            }
        }
    }

    private var deckSelection: Binding<UUID?> {
        Binding(
            get: { viewModel.library.selectedID },
            set: { if let id = $0 { viewModel.selectPresentation(id) } }
        )
    }

    private func collectionLine(for deck: Presentation) -> String {
        if let collection = deck.collection, !collection.isEmpty {
            "\(deck.cards.count) cards · \(collection)"
        } else {
            "\(deck.cards.count) cards"
        }
    }

    private var cardDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let deck = viewModel.library.selected {
                HStack {
                    TextField("Deck name", text: deckName(deck))
                        .font(.headline)
                    Button("Done") { dismiss() }
                }
                TextField("Collection (optional)", text: deckCollection(deck))
                    .font(.callout)
                    .foregroundColor(.secondary)
                HStack {
                    Text("Cards")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Add Card") {
                        viewModel.addCardToActiveDeck()
                        selectedCardID = viewModel.store.currentCard?.id
                    }
                }
                List(selection: $selectedCardID) {
                    ForEach(viewModel.store.cards) { card in
                        VStack(alignment: .leading) {
                            Text(displayTitle(card))
                                .fontWeight(.semibold)
                            Text(card.message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .tag(card.id)
                    }
                    .onDelete { viewModel.removeActiveCards(at: $0) }
                }
                cardEditor
            } else {
                Text("No presentation selected.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func deckName(_ deck: Presentation) -> Binding<String> {
        Binding(
            get: { deck.name },
            set: { viewModel.renamePresentation(deck.id, name: $0) }
        )
    }

    private func deckCollection(_ deck: Presentation) -> Binding<String> {
        Binding(
            get: { deck.collection ?? "" },
            set: { viewModel.setPresentationCollection(deck.id, collection: $0) }
        )
    }

    @ViewBuilder
    private var cardEditor: some View {
        if let selectedCardID,
           let index = viewModel.store.cards.firstIndex(where: { $0.id == selectedCardID })
        {
            let card = viewModel.store.cards[index]
            VStack(alignment: .leading, spacing: 6) {
                Text("Edit Card")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                TextField("Title", text: Binding(
                    get: { card.title },
                    set: { viewModel.updateActiveCard(at: index, title: $0, message: card.message, detail: card.detail) }
                ))
                TextField("Message", text: Binding(
                    get: { card.message },
                    set: { viewModel.updateActiveCard(at: index, title: card.title, message: $0, detail: card.detail) }
                ))
                TextField("Detail (optional)", text: Binding(
                    get: { card.detail ?? "" },
                    set: {
                        viewModel.updateActiveCard(
                            at: index, title: card.title, message: card.message,
                            detail: $0.isEmpty ? nil : $0
                        )
                    }
                ))
                HStack {
                    Button(card.imageData == nil ? "Attach Picture…" : "Replace Picture…") {
                        viewModel.attachPictureToCard(at: index)
                    }
                    if card.imageData != nil {
                        Button("Remove Picture") { viewModel.removePictureFromCard(at: index) }
                    }
                    Spacer()
                    if card.imageData != nil {
                        Text("Picture attached")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

}

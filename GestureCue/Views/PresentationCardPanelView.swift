import AppKit
import SwiftUI

/// Large readable presentation card with equivalent mouse and keyboard controls
/// (Show ↑, Hide Esc, Next →, Expand E) for every gesture action.
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
            .accessibilityLabel("Visible card: \(card.title). \(card.message)")
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
                    Text("\(deck.cards.count) cards")
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

    private var cardDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let deck = viewModel.library.selected {
                HStack {
                    TextField("Deck name", text: deckName(deck))
                        .font(.headline)
                    Button("Done") { dismiss() }
                }
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
                            Text(card.title)
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
                TextField("Title", text: cardField(
                    get: { card.title },
                    set: { viewModel.updateActiveCard(at: index, title: $0, message: card.message, detail: card.detail) }
                ))
                TextField("Message", text: cardField(
                    get: { card.message },
                    set: { viewModel.updateActiveCard(at: index, title: card.title, message: $0, detail: card.detail) }
                ))
                TextField("Detail (optional)", text: cardField(
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

    private func cardField(get: @escaping () -> String, set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: get, set: set)
    }
}

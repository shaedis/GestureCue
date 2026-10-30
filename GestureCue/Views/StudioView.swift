import AppKit
import SwiftUI

/// AI Visual Education Studio: import source material, configure the
/// lesson, review editable AI drafts, and save the approved lesson to
/// the Presentation Catalog. Network happens only after explicit
/// per-source approval; drafts stay local until saved.
struct StudioView: View {
    @ObservedObject var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    /// Green "Saved" confirmation between a successful save and the
    /// window closing itself.
    @State private var savedFlash = false
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceSection
                Divider()
                settingsSection
                Divider()
                keySection
                Divider()
                generateSection
                Divider()
                draftsSection
                Divider()
                saveSection
            }
            .padding(16)
        }
        .onDisappear { closeTask?.cancel() }
    }

    // MARK: - Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. Source Material")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Paste text, import a file, or reuse a catalog deck. Source is treated as data; nothing is sent anywhere until you approve below.")
                .font(.caption)
                .foregroundColor(.secondary)
            if viewModel.fidelity == .faithful {
                Text("Faithful mode: the model splits your source to fit video cards without rewriting or new illustrations.")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            TextEditor(text: $viewModel.sourceText)
                .frame(minHeight: 110)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("Source text")
            HStack {
                Button("New") { viewModel.requestNew() }
                    .accessibilityLabel("Start new source material")
                Button("Import File…") { viewModel.importFileViaPanel() }
                Button("Use Pasted Text") { viewModel.usePastedText() }
                Menu("Use Existing Deck…") {
                    if viewModel.studioDecks.isEmpty {
                        Text("No AI-generated decks yet")
                    }
                    ForEach(viewModel.studioDecks) { deck in
                        Button(deck.name) { viewModel.useDeck(deck) }
                    }
                }
                Menu("Edit Existing Deck…") {
                    if viewModel.studioDecks.isEmpty {
                        Text("No AI-generated decks yet")
                    }
                    ForEach(viewModel.studioDecks) { deck in
                        Button(deck.name) { viewModel.editDeck(deck) }
                    }
                }
                Spacer()
                Text("\(viewModel.sourceText.count) characters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .alert("Start new source material?", isPresented: $viewModel.confirmNew) {
                if viewModel.canSave {
                    Button("Save") {
                        if viewModel.saveToCatalog() {
                            viewModel.resetWorkspace()
                        } else {
                            viewModel.confirmNew = false
                        }
                    }
                }
                Button(viewModel.canSave ? "Discard Without Saving" : "Discard", role: .destructive) {
                    viewModel.resetWorkspace()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(viewModel.canSave
                    ? "Unsaved drafts will be lost unless you save them to the catalog."
                    : "The workspace will be cleared. There are no generated drafts to save yet.")
            }
            .alert("Import new source material?", isPresented: $viewModel.confirmImport) {
                if viewModel.canSave {
                    Button("Save") {
                        if viewModel.saveToCatalog() {
                            viewModel.adoptPendingSource()
                        } else {
                            viewModel.cancelPendingSource()
                        }
                    }
                }
                Button("Discard Drafts", role: .destructive) {
                    viewModel.adoptPendingSource()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.cancelPendingSource()
                }
            } message: {
                Text("Review Drafts still holds material from the previous source. Save it first, or discard it and continue with the new source.")
            }
            if let note = viewModel.sourceNote {
                Text(note).font(.callout).foregroundColor(.orange)
            }
            if let error = viewModel.importError {
                Text(error).font(.callout).foregroundColor(.red)
            }
            Text("AI Instructions (Optional)")
                .font(.headline)
            Text("Guide the planner: emphasis, explanation style, timelines, diagrams, labels. Empty means default behavior. Guidance never overrides source accuracy, card count, or language.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $viewModel.aiInstructions)
                .frame(minHeight: 60)
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("AI Instructions")
            HStack {
                Spacer()
                Text("\(viewModel.aiInstructions.count) characters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("2. Lesson Settings")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker("Mode", selection: $viewModel.fidelity) {
                ForEach(Fidelity.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Generation mode")
            Text(viewModel.fidelity.caption)
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("Audience", selection: $viewModel.settings.audience) {
                ForEach(AIAudience.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if viewModel.settings.audience == .custom {
                TextField("Describe the audience", text: $viewModel.settings.audienceCustom)
            }
            Picker("Level", selection: $viewModel.settings.level) {
                ForEach(AIEducationLevel.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if viewModel.settings.level == .custom {
                TextField("Age or grade", text: $viewModel.settings.levelCustom)
            }
            Picker("Subject", selection: $viewModel.settings.subject) {
                ForEach(AISubject.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Visual style", selection: $viewModel.settings.style) {
                ForEach(AIVisualStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Text amount", selection: $viewModel.settings.textAmount) {
                ForEach(AITextAmount.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            HStack {
                Text("Language")
                TextField("Language", text: $viewModel.settings.language)
                    .frame(maxWidth: 200)
                Spacer()
                Stepper("Cards: \(viewModel.settings.cardCount)", value: $viewModel.settings.cardCount, in: 3...10)
            }
            TextField("Illustration style", text: $viewModel.settings.illustrationStyle)
                .accessibilityLabel("Illustration style")
        }
    }

    // MARK: - Key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3. Meta API Key")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Stored in the Keychain, never anywhere else. Get one at dev.meta.ai.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Circle()
                    .fill(viewModel.keyPresent ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(viewModel.keyPresent ? "Key saved" : "No key saved")
                    .font(.callout)
                    .fontWeight(.semibold)
                Spacer()
                if viewModel.keyPresent {
                    Button("Clear Key") { viewModel.clearKey() }
                }
            }
            .accessibilityElement(children: .combine)
            HStack {
                SecureField("Paste API key", text: $viewModel.keyInput)
                    .frame(maxWidth: 340)
                    .accessibilityLabel("API key")
                Button("Save Key") { viewModel.saveKey() }
                    .disabled(viewModel.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = viewModel.keyMessage {
                Text(message).font(.callout).foregroundColor(.red)
            }
        }
    }

    // MARK: - Generate

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("4. Generate")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("I approve sending this source to Meta for generation", isOn: $viewModel.approvalGiven)
                .accessibilityLabel("Approve sharing source with Meta")
            HStack {
                if viewModel.isGenerating {
                    Button("Cancel") { viewModel.cancelGeneration() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Generate Lesson") { viewModel.generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canGenerate)
                }
                if viewModel.isGenerating {
                    ProgressView()
                        .accessibilityLabel("Generating lesson")
                }
            }
            if !viewModel.progressLine.isEmpty {
                Text(viewModel.progressLine)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            if let error = viewModel.progressError {
                Text(error).font(.callout).foregroundColor(.red)
            }
        }
        .alert("Generate fewer cards than slides?", isPresented: $viewModel.confirmCardCount) {
            Button("Generate") { viewModel.generateAfterConfirm() }
            Button("Cancel", role: .cancel) { viewModel.cancelCardCountConfirm() }
        } message: {
            let warning = viewModel.cardCountWarning
            Text("The source holds \(warning?.segments ?? 0) slides/pages but Cards is set to \(warning?.cards ?? 0). Content will be merged to fit — raise Cards (up to 10) or generate anyway.")
        }
    }

    // MARK: - Drafts

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("5. Review Drafts (\(viewModel.drafts.count))")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if viewModel.changedPromptCount > 0 {
                    Button("Regenerate Changed (\(viewModel.changedPromptCount))") {
                        viewModel.regenerateChanged()
                    }
                    .disabled(viewModel.isGenerating)
                    .accessibilityLabel("Regenerate only changed prompts")
                }
            }
            Text("Drafts until you save: check facts, dates, equations, spelling, and age-appropriateness. Generated scenes are illustrative reconstructions, not photographs.")
                .font(.caption)
                .foregroundColor(.secondary)
            if viewModel.drafts.isEmpty {
                Text("No drafts yet — generate a lesson first.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            ForEach(viewModel.drafts.indices, id: \.self) { index in
                DraftCardView(draft: $viewModel.drafts[index],
                              fidelity: viewModel.fidelity,
                              sourceText: viewModel.sourceText,
                              isRegenerating: viewModel.regeneratingIDs.contains(viewModel.drafts[index].id),
                              regenBusy: viewModel.isGenerating || !viewModel.regeneratingIDs.isEmpty,
                              onRegenerate: { viewModel.regenerateImage(for: viewModel.drafts[index].id) },
                              onRefresh: { viewModel.refreshArtwork(for: viewModel.drafts[index].id) },
                              onRemove: { viewModel.removeDraft(viewModel.drafts[index].id) })
            }
        }
    }

    // MARK: - Save

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("6. Save to Catalog")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack {
                TextField("Lesson title", text: $viewModel.lessonTitle)
                    .frame(maxWidth: 300)
                    .accessibilityLabel("Lesson title")
                TextField("Collection", text: $viewModel.collection)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Collection")
                Menu("Collections…") {
                    ForEach(viewModel.catalog.all, id: \.self) { name in
                        Button(name) { viewModel.collection = name }
                    }
                }
                Button("Suggest") { viewModel.suggestCollection() }
                    .disabled(!viewModel.canSuggestCollection)
                    .accessibilityLabel("Suggest collection from source")
                if viewModel.isSuggestingCollection {
                    ProgressView()
                        .scaleEffect(0.6)
                        .accessibilityLabel("Suggesting collection")
                }
            }
            if let error = viewModel.collectionSuggestError {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Button(savedFlash ? "Saved ✓" : "Save Approved Lesson") {
                if viewModel.saveToCatalog() {
                    savedFlash = true
                    closeTask?.cancel()
                    closeTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(savedFlash ? .green : .accentColor)
            .disabled(!viewModel.canSave || savedFlash)
            .onChange(of: viewModel.drafts) { savedFlash = false }
            .onChange(of: viewModel.lessonTitle) { savedFlash = false }
            if let message = viewModel.saveMessage {
                Text(message).font(.callout).foregroundColor(.green)
            }
        }
    }
}

/// One editable draft: artwork preview, editable texts, prompt editing
/// with selective regenerate, free text refresh, and remove.
private struct DraftCardView: View {
    @Binding var draft: DraftCard
    var fidelity: Fidelity = .creative
    var sourceText = ""
    var isRegenerating = false
    var regenBusy = false
    var onRegenerate: () -> Void
    var onRefresh: () -> Void
    var onRemove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    if let data = draft.imageData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(width: 220)
                            .cornerRadius(6)
                            .accessibilityLabel("Draft illustration for \(draft.title)")
                    } else {
                        Text("No image")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 220, height: 124)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Title", text: $draft.title)
                            .font(.headline)
                            .accessibilityLabel("Draft title")
                        Text("Artwork: \(sourceLine)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if fidelity == .faithful {
                            Text(fidelityLine)
                                .font(.caption)
                                .foregroundColor(fidelityColor)
                        }
                        HStack {
                            Button("Regenerate Image") { onRegenerate() }
                                .font(.callout)
                                .disabled(draft.illustrationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRegenerating || regenBusy)
                            if isRegenerating {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .accessibilityLabel("Regenerating image")
                                Text("Regenerating…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if draft.baseImageData != nil {
                                Button("Refresh Text") { onRefresh() }
                                    .font(.callout)
                                    .accessibilityLabel("Refresh artwork text without new image")
                            }
                            Button("Remove Card") { onRemove() }
                                .font(.callout)
                                .foregroundColor(.red)
                        }
                    }
                }
                Text("Concept").font(.caption).foregroundColor(.secondary)
                TextField("Concept", text: $draft.concept)
                Text("Body").font(.caption).foregroundColor(.secondary)
                TextEditor(text: $draft.body)
                    .frame(minHeight: 60)
                    .border(Color.secondary.opacity(0.3))
                Text("Labels (comma-separated)").font(.caption).foregroundColor(.secondary)
                TextField("Labels", text: labelsBinding)
                Text("Source reference").font(.caption).foregroundColor(.secondary)
                TextField("Source", text: $draft.sourceReference)
                Text("Presenter notes").font(.caption).foregroundColor(.secondary)
                TextField("Notes", text: $draft.presenterNotes)
                HStack(spacing: 4) {
                    Text("Image prompt").font(.caption).foregroundColor(.secondary)
                    if draft.promptChanged {
                        Text("• edited — Regenerate to apply")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .accessibilityLabel("Prompt edited")
                    }
                }
                TextEditor(text: $draft.illustrationPrompt)
                    .frame(minHeight: 44)
                    .border(Color.secondary.opacity(0.3))
                    .accessibilityLabel("Image prompt")
            }
        }
    }

    private var sourceLine: String {
        switch draft.imageSource {
        case .none: "none"
        case .generated: "Muse Image"
        case .diagram: "programmatic diagram"
        case .imported: "imported artwork"
        }
    }

    /// Measured verbatim status for faithful review: green when every
    /// passage is found in the source, amber otherwise. Advisory only —
    /// the human reviewer decides.
    private var fidelityVerdict: FidelityVerdict {
        FidelityCheck.verify(body: draft.body, against: sourceText)
    }

    private var fidelityLine: String {
        let verdict = fidelityVerdict
        if verdict.total == 0 {
            return "Fidelity: no text to verify"
        }
        if verdict.matchesSource {
            return "Fidelity: matches source"
        }
        return "Fidelity: \(verdict.total - verdict.matched) of \(verdict.total) passages differ from source"
    }

    private var fidelityColor: Color {
        fidelityVerdict.matchesSource && fidelityVerdict.total > 0 ? .green : .orange
    }

    private var labelsBinding: Binding<String> {
        Binding(
            get: { draft.labelsText },
            set: { draft.labelsText = $0 }
        )
    }
}

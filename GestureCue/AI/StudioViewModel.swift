import AppKit
import Foundation
import UniformTypeIdentifiers

/// AI Visual Education Studio state: source material, generation settings,
/// API key, the generation job, editable drafts, and catalog saving.
/// Network happens only after explicit per-source approval; the key lives
/// in the Keychain and never in logs or UserDefaults.
@MainActor
final class StudioViewModel: ObservableObject {
    /// Custom collections created by model suggestions (persisted).
    @Published var catalog = CollectionCatalog()
    private static let customCollectionsKey = "StudioCustomCollections"

    @Published var sourceTitle = "" {
        didSet {
            if sourceTitle != oldValue {
                approvalGiven = false
                dirty = true
            }
        }
    }
    @Published var sourceText = "" {
        didSet {
            if sourceText != oldValue {
                approvalGiven = false
                dirty = true
            }
        }
    }
    /// Optional user guidance for the planner ("use timelines", "simpler
    /// words"). Transmitted with the source, so edits reset approval;
    /// sticky across imports like settings, cleared only by New. Editing
    /// it never touches drafts, artwork, or annotations.
    @Published var aiInstructions = "" {
        didSet {
            if aiInstructions != oldValue {
                approvalGiven = false
                dirty = true
            }
        }
    }
    @Published var sourceNote: String?
    @Published var importError: String?
    @Published var settings: GenerationSettings {
        didSet { Self.saveSettings(settings) }
    }
    @Published var keyInput = ""
    @Published var keyPresent = false
    @Published var keyMessage: String?
    @Published var approvalGiven = false
    @Published var isGenerating = false
    /// Drafts with an image call in flight (single or batch regen):
    /// their cards spin until the artwork lands.
    @Published var regeneratingIDs: Set<DraftCard.ID> = []
    @Published var progress: GenerationProgress?
    @Published var progressError: String?
    @Published var drafts: [DraftCard] = [] {
        didSet { dirty = true }
    }
    @Published var lessonTitle = "" {
        didSet { if lessonTitle != oldValue { dirty = true } }
    }
    @Published var collection = ""
    @Published var saveMessage: String?
    @Published var confirmNew = false
    @Published var confirmImport = false
    /// Card-count confirmation: source holds more slides/pages than the
    /// Card setting would generate. `cardCountWarning` carries the numbers
    /// for the alert message.
    @Published var confirmCardCount = false
    var cardCountWarning: (segments: Int, cards: Int)?
    /// Plan fidelity for the current source. Imports default it
    /// (presentations split faithfully, everything else generates
    /// freely); the user can switch modes for any source before
    /// generating.
    @Published var fidelity: Fidelity = .creative
    /// Unsaved workspace changes (source or drafts differ from the last
    /// save/load). Set by content didSets; cleared by save, deck load,
    /// and New. Read only on the main thread at New-press time.
    private(set) var dirty = false
    /// Imported source awaiting the save/discard confirmation.
    private var pendingSource: SourceImporter.Source?
    /// Original images of the adopted source (PowerPoint imports);
    /// generation reattaches them to cards via the plan's imageRefs.
    private var sourceImages: [SourceImage] = []

    private let app: AppViewModel
    private let credentials: CredentialStore
    private let importer = SourceImporter()
    private var task: Task<Void, Never>?
    private var suggestTask: Task<Void, Never>?
    @Published var isSuggestingCollection = false
    @Published var collectionSuggestError: String?

    /// `service` override is for previews; nil builds a live client from
    /// the Keychain key at generate time.
    private let serviceOverride: (any GenerationService)?

    init(app: AppViewModel, credentials: CredentialStore? = nil, service: (any GenerationService)? = nil) {
        self.app = app
        self.credentials = credentials ?? KeychainCredentialStore()
        self.serviceOverride = service
        self.settings = Self.loadSettings()
        if let saved = UserDefaults.standard.stringArray(forKey: Self.customCollectionsKey) {
            self.catalog.custom = saved.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        refreshKeyStatus()
    }

    var decks: [Presentation] { app.library.presentations }

    /// AI Studio decks only: the Studio menus must not offer hand-made
    /// or imported decks (editing those would silently AI-ify them).
    var studioDecks: [Presentation] { decks.filter(\.isStudioDeck) }

    var canGenerate: Bool {
        !isGenerating && keyPresent && approvalGiven && !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var progressLine: String {
        switch progress {
        case .planning: "Planning the lesson with Muse Spark…"
        case let .renderingImages(done, total): "Rendering illustrations… \(done)/\(total)"
        case .finished: "Done — review the drafts below."
        case nil: isGenerating ? "Working…" : ""
        }
    }

    // MARK: - Source

    func importFileViaPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.pdf, .plainText]
        for ext in ["md", "markdown", "text", "ipynb", "pptx", "ppsx"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.message = "Choose source material (PDF, PowerPoint, Markdown, TXT, Jupyter notebook)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let source = try importer.importFile(at: url)
            adoptGuarded(source: source)
        } catch {
            importError = error.localizedDescription
        }
    }

    func usePastedText() {
        do {
            let source = try importer.importText(sourceText)
            adoptGuarded(source: source)
        } catch {
            importError = error.localizedDescription
        }
    }

    func useDeck(_ deck: Presentation) {
        do {
            let source = try importer.importPresentation(deck)
            adoptGuarded(source: source)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Re-imports a catalog deck as editable drafts: artwork and prompts
    /// travel along so untouched cards keep their pixels and only edited
    /// prompts regenerate; the deck's saved guidance returns to the
    /// instructions field. No network involved; approval resets only
    /// when the restored guidance differs from the field.
    func editDeck(_ deck: Presentation) {
        cancelGeneration()
        aiInstructions = deck.aiInstructions ?? ""
        drafts = deck.cards.map(DraftCard.init(from:))
        lessonTitle = deck.name
        collection = deck.collection ?? ""
        progress = nil
        progressError = nil
        saveMessage = nil
        importError = nil
        dirty = false
    }

    /// Starts a fresh workspace: unsaved work raises a save/discard
    /// confirmation first; a clean workspace resets immediately.
    func requestNew() {
        if dirty {
            confirmNew = true
        } else {
            resetWorkspace()
        }
    }

    /// Clears source, drafts, and status for new material. Generation is
    /// cancelled first; settings and the API key are kept.
    func resetWorkspace() {
        cancelGeneration()
        sourceTitle = ""
        sourceText = ""
        aiInstructions = ""
        sourceNote = nil
        importError = nil
        approvalGiven = false
        isGenerating = false
        progress = nil
        progressError = nil
        drafts = []
        lessonTitle = ""
        collection = ""
        saveMessage = nil
        collectionSuggestError = nil
        confirmNew = false
        pendingSource = nil
        confirmImport = false
        confirmCardCount = false
        cardCountWarning = nil
        regeneratingIDs = []
        fidelity = .creative
        dirty = false
        sourceImages = []
    }

    /// Re-composes the stored base artwork with the current title/labels.
    /// Free and instant; for text tweaks without new API art.
    func refreshArtwork(for id: DraftCard.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].refreshDisplayArtwork()
    }

    var changedPromptCount: Int { drafts.filter(\.promptChanged).count }

    /// Regenerates ONLY drafts whose prompt was edited since render.
    func regenerateChanged() {
        let ids = drafts.filter(\.promptChanged).map(\.id)
        guard !ids.isEmpty, task == nil, let service = activeService() else { return }
        isGenerating = true
        progressError = nil
        let style = settings.illustrationStyle
        task = Task { [weak self] in
            guard let self else { return }
            var done = 0
            do {
                for id in ids {
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        self?.progress = .renderingImages(done: done, total: ids.count)
                        self?.regeneratingIDs.insert(id)
                    }
                    guard let draft = await MainActor.run(body: { [weak self] in
                        self?.drafts.first(where: { $0.id == id })
                    }), !draft.illustrationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        await MainActor.run { [weak self] in self?.regeneratingIDs.remove(id) }
                        continue
                    }
                    let raw = try await service.generateImage(prompt: draft.illustrationPrompt, style: style)
                    let composed = IllustrationComposer.compose(
                        imageData: raw, title: draft.title, labels: draft.labels
                    ) ?? raw
                    await MainActor.run { [weak self] in
                        guard let self, let at = self.drafts.firstIndex(where: { $0.id == id }) else { return }
                        self.drafts[at].imageData = composed
                        self.drafts[at].baseImageData = raw
                        self.drafts[at].imageSource = .generated
                        self.drafts[at].renderedIllustrationPrompt = draft.illustrationPrompt
                        self.regeneratingIDs.remove(id)
                    }
                    done += 1
                }
                await MainActor.run { [weak self] in
                    self?.progress = .finished
                    self?.finishRegeneration()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.progressError = "Regeneration cancelled."
                    self?.finishRegeneration()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.progressError = error.localizedDescription
                    self?.finishRegeneration()
                }
            }
        }
    }

    private func finishRegeneration() {
        task = nil
        isGenerating = false
        regeneratingIDs.removeAll()
    }

    /// Live client from the Keychain key (or the injected override),
    /// setting an error when no key is available.
    private func activeService() -> (any GenerationService)? {
        if let serviceOverride { return serviceOverride }
        guard let key = credentials.apiKey(), !key.isEmpty else {
            progressError = GenerationError.missingAPIKey.localizedDescription
            return nil
        }
        return MetaModelClient(apiKey: key)
    }

    private func adopt(source: SourceImporter.Source) {
        cancelGeneration()
        fidelity = source.kind == .presentation ? .faithful : .creative
        sourceTitle = source.title
        sourceText = source.text
        sourceImages = source.images
        sourceNote = source.truncated ? "Source truncated to \(SourceImporter.maxCharacters) characters." : nil
        importError = nil
        approvalGiven = false
        // New source invalidates old drafts: Review Drafts must never
        // point at material generated from previous source.
        drafts = []
        lessonTitle = ""
        progress = nil
        progressError = nil
        saveMessage = nil
    }

    /// Adopts imported source, guarding unsaved drafts first: importing
    /// over generated-but-unsaved work stashes the source and raises the
    /// save/discard confirmation; otherwise the source lands immediately.
    private func adoptGuarded(source: SourceImporter.Source) {
        if !drafts.isEmpty, dirty {
            pendingSource = source
            confirmImport = true
        } else {
            adopt(source: source)
        }
    }

    /// Adopts the source stashed by the import confirmation (Save or
    /// Discard path); Cancel drops it by clearing without adopting.
    func adoptPendingSource() {
        guard let source = pendingSource else { return }
        pendingSource = nil
        confirmImport = false
        adopt(source: source)
    }

    func cancelPendingSource() {
        pendingSource = nil
        confirmImport = false
    }

    // MARK: - API key

    func refreshKeyStatus() {
        keyPresent = credentials.apiKey()?.isEmpty == false
    }

    func saveKey() {
        do {
            try credentials.setAPIKey(keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
            keyInput = ""
            keyMessage = nil
        } catch {
            keyMessage = error.localizedDescription
        }
        refreshKeyStatus()
    }

    func clearKey() {
        try? credentials.setAPIKey(nil)
        refreshKeyStatus()
    }

    // MARK: - Generation

    func generate() {
        guard canGenerate, task == nil, let service = activeService() else { return }
        // More slides/pages than cards: merging is lossy, so the user
        // confirms they want fewer cards than source segments.
        let segments = SourceSegments.count(in: sourceText)
        if segments > settings.clampedCardCount {
            cardCountWarning = (segments, settings.clampedCardCount)
            confirmCardCount = true
            return
        }
        runGeneration(service: service)
    }

    /// Starts generation after the card-count confirmation.
    func generateAfterConfirm() {
        confirmCardCount = false
        cardCountWarning = nil
        guard canGenerate, task == nil, let service = activeService() else { return }
        runGeneration(service: service)
    }

    func cancelCardCountConfirm() {
        confirmCardCount = false
        cardCountWarning = nil
    }

    private func runGeneration(service: any GenerationService) {
        let source = sourceText
        let settings = settings
        let fidelity = fidelity
        let sourceImages = sourceImages
        let instructions = aiInstructions
        isGenerating = true
        progressError = nil
        drafts = []
        lessonTitle = sourceTitle
        let generator = LessonGenerator(service: service)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let drafts = try await generator.generate(source: source, settings: settings, fidelity: fidelity, sourceImages: sourceImages, instructions: instructions) { [weak self] progress in
                    Task { @MainActor [weak self] in self?.progress = progress }
                }
                // A New/Edit/Cancel that landed after the last step must
                // not resurrect stale drafts into the fresh workspace.
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    self?.drafts = drafts
                    self?.finishGeneration()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.progressError = "Generation cancelled."
                    self?.finishGeneration()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.progressError = error.localizedDescription
                    self?.finishGeneration()
                }
            }
        }
    }

    func cancelGeneration() {
        task?.cancel()
        suggestTask?.cancel()
    }

    /// Suggest disabled until the source is approved: the excerpt is
    /// transmitted to the Meta API like generation input.
    var canSuggestCollection: Bool {
        approvalGiven && keyPresent && !isSuggestingCollection
            && !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Asks the model to categorise the current source: an existing
    /// bucket is applied, a genuinely new one is created (persisted)
    /// and applied.
    func suggestCollection() {
        guard canSuggestCollection, suggestTask == nil, let service = activeService() else { return }
        let title = sourceTitle
        let excerpt = String(sourceText.prefix(1500))
        let candidates = catalog.all
        isSuggestingCollection = true
        collectionSuggestError = nil
        suggestTask = Task { [weak self] in
            guard let self else { return }
            defer { self.suggestTask = nil }
            do {
                let suggestion = try await service.suggestCollection(title: title, excerpt: excerpt, collections: candidates)
                await MainActor.run { [weak self] in
                    self?.applyCollectionSuggestion(suggestion)
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in self?.isSuggestingCollection = false }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isSuggestingCollection = false
                    self?.collectionSuggestError = error.localizedDescription
                }
            }
        }
    }

    private func applyCollectionSuggestion(_ suggestion: String) {
        isSuggestingCollection = false
        let resolved = catalog.resolve(suggestion)
        guard !resolved.name.isEmpty else {
            collectionSuggestError = "The model returned an empty collection name."
            return
        }
        if resolved.isNew {
            catalog.addCustom(resolved.name)
            UserDefaults.standard.set(catalog.custom, forKey: Self.customCollectionsKey)
        }
        collection = resolved.name
    }

    private func finishGeneration() {
        task = nil
        isGenerating = false
        if progressError == nil, drafts.isEmpty {
            progressError = "The lesson came back empty. Try a longer source text."
        }
    }

    func regenerateImage(for id: DraftCard.ID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }),
              task == nil, let service = activeService()
        else { return }
        let draft = drafts[index]
        let style = settings.illustrationStyle
        regeneratingIDs.insert(id)
        task = Task { [weak self] in
            do {
                let raw = try await service.generateImage(prompt: draft.illustrationPrompt, style: style)
                let composed = IllustrationComposer.compose(imageData: raw, title: draft.title, labels: draft.labels) ?? raw
                await MainActor.run { [weak self] in
                    guard let self, let at = self.drafts.firstIndex(where: { $0.id == id }) else { return }
                    self.drafts[at].imageData = composed
                    self.drafts[at].baseImageData = raw
                    self.drafts[at].imageSource = .generated
                    self.drafts[at].renderedIllustrationPrompt = draft.illustrationPrompt
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { [weak self] in
                    self?.progressError = error.localizedDescription
                }
            }
            await MainActor.run { [weak self] in
                self?.task = nil
                self?.regeneratingIDs.remove(id)
            }
        }
    }

    func removeDraft(_ id: DraftCard.ID) {
        drafts.removeAll { $0.id == id }
        regeneratingIDs.remove(id)
    }

    // MARK: - Save

    /// Lesson title + at least one draft: the Save button and the
    /// New-workspace Save action share this gate.
    var canSave: Bool {
        !lessonTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !drafts.isEmpty
    }

    @discardableResult
    func saveToCatalog() -> Bool {
        let title = lessonTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !drafts.isEmpty else { return false }
        app.saveGeneratedLesson(
            title: title,
            collection: collection.isEmpty ? nil : collection,
            cards: drafts.map(makePresentationCard(from:)),
            aiInstructions: aiInstructions
        )
        saveMessage = "Saved “\(title)” to the catalog — select it to present."
        dirty = false
        return true
    }

    // MARK: - Settings persistence

    private static let settingsKey = "GestureCue.generationSettings"

    private static func loadSettings() -> GenerationSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(GenerationSettings.self, from: data)
        else { return GenerationSettings() }
        return settings
    }

    private static func saveSettings(_ settings: GenerationSettings) {
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: settingsKey)
    }
}

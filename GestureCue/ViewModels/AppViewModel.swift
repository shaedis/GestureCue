import AppKit
import Combine
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Composition root: builds the shared capture pipeline (capture → gesture
/// detection + program output), routes fired gestures to the card store through
/// the user-configurable mapping, and publishes all UI state on the main actor.
@MainActor
final class AppViewModel: ObservableObject {
    struct FiredFeedback: Identifiable, Equatable {
        let id = UUID()
        /// The gesture that fired, or nil when the action came from mouse/keyboard.
        let gesture: HandGesture?
        let action: CardAction?
        let date = Date()
    }

    let camera: CameraManager
    let programOutput: SampleBufferDisplayOutput
    let expandedOutput: SampleBufferDisplayOutput

    @Published private(set) var store: PresentationCardStore
    @Published private(set) var library: PresentationLibrary
    @Published var showingLibrary = false
    @Published private(set) var isImporting = false
    @Published private(set) var importError: String?
    @Published var gestureMapping: [HandGesture: CardAction] {
        didSet { saveMapping() }
    }
    /// Command hold-to-fire seconds (user-configurable trigger timing).
    @Published var holdDuration: TimeInterval {
        didSet {
            UserDefaults.standard.set(holdDuration, forKey: Self.holdDurationKey)
            gestureDetector.setHoldDuration(holdDuration)
        }
    }
    @Published private(set) var candidate: HandGesture = .unknown
    @Published private(set) var stabilityProgress: Double = 0
    @Published private(set) var confidence: Float = 0
    @Published private(set) var diagnosis = ""
    @Published private(set) var handDetected = false
    @Published private(set) var landmarks: [CGPoint] = []
    @Published var showLandmarks = true
    @Published var isProgramOutputEnabled = true {
        didSet { programPipeline.setEnabled(isProgramOutputEnabled) }
    }
    @Published var cardPosition: CardOverlayPosition {
        didSet {
            UserDefaults.standard.set(cardPosition.rawValue, forKey: Self.cardPositionKey)
            syncOverlay()
        }
    }
    /// Card panel placement in Video + Card mode (ignored otherwise).
    @Published var cardPanelPosition: CardPanelPosition {
        didSet {
            UserDefaults.standard.set(cardPanelPosition.rawValue, forKey: Self.cardPanelKey)
            syncOverlay()
        }
    }
    @Published var paintColor: HighlightColor {
        didSet {
            UserDefaults.standard.set(paintColor.rawValue, forKey: Self.highlightColorKey)
            paintController.setColor(paintColor)
        }
    }
    @Published var outputMirrorMode: OutputMirrorMode {
        didSet {
            UserDefaults.standard.set(outputMirrorMode.rawValue, forKey: Self.mirrorModeKey)
            updateOutputMirroring()
        }
    }
    @Published var paintMode = false {
        didSet { gestureDetector.setPaintMode(paintMode) }
    }
    @Published private(set) var painting = false
    @Published private(set) var isOutputRunning = false
    @Published private(set) var outputMirrored = false
    @Published private(set) var lastFired: FiredFeedback?
    /// Signing mode: hands are ignored until a command window opens.
    @Published private(set) var detectionPaused = true
    /// Seconds left in the open command window (0 when paused).
    @Published private(set) var commandWindowRemaining: TimeInterval = 0
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var recordingError: String?
    @Published private(set) var recordingDropped = 0
    @Published private(set) var virtualCameraStatus: SystemExtensionStatus = .notInstalled
    /// True once frames actually flow into the sink (status may read
    /// active while the device is still unpublished).
    @Published private(set) var virtualCameraStreaming = false

    var router: GestureActionRouter { GestureActionRouter(mapping: gestureMapping) }

    // v5: thumbRight/thumbLeft → next/previous replace indexUp/twoFingersUp
    // (both occur in signing); those plus fist are unassigned by default.
    // Old saves are superseded so installs pick up the new mapping.
    private static let mappingKey = "GestureCue.gestureMapping.v5"
    private static let holdDurationKey = "GestureCue.holdDuration"
    private static let cardPositionKey = "GestureCue.cardPosition"
    private static let cardPanelKey = "GestureCue.cardPanelPosition"
    private static let highlightColorKey = "GestureCue.highlightColor"
    private static let mirrorModeKey = "GestureCue.outputMirrorMode"
    private static let detectionPausedKey = "GestureCue.detectionPaused"
    private var cancellations = Set<AnyCancellable>()
    private var commandWindow = CommandWindow()
    private var lastPaintActivity = Date.distantPast
    private var windowTask: Task<Void, Never>?
    private var virtualCameraTask: Task<Void, Never>?
    /// Listening-dot state burned into the program feed. Synced to the
    /// overlay only on transitions (appear/vanish/green→amber).
    private var lastDotState: DotState = .off

    private enum DotState { case off, green, amber }
    private var recordingTask: Task<Void, Never>?
    private var recordingStartDate: Date?
    private var programOutputWasEnabled = true
    private var wantVirtualCamera = false
    private let outputWindow = OutputWindowController()
    private let importer = PresentationImporter()
    private let gestureDetector: HandGestureDetector
    private let recorder: VideoRecorder
    private let virtualCameraService: VirtualCameraService
    private let extensionManager: SystemExtensionManager
    private let paintController: FingerPaintController
    private let compositor: CardOverlayCompositor
    private let programPipeline: ProgramOutputPipeline
    private let expandedPipeline: ProgramOutputPipeline
    private let virtualPipeline: ProgramOutputPipeline

    init() {
        let compositor = CardOverlayCompositor()
        let paintController = FingerPaintController()
        paintController.sink = { [compositor] layer in compositor.updatePaint(layer) }
        let gestureDetector = HandGestureDetector(paint: paintController)
        let hold = Self.loadHoldDuration()
        gestureDetector.setHoldDuration(hold)
        let recorder = VideoRecorder()
        let virtualCameraService = VirtualCameraService(transport: CMIOVirtualCameraTransport())
        let extensionManager = SystemExtensionManager()
        let programOutput = SampleBufferDisplayOutput()
        let programPipeline = ProgramOutputPipeline(compositor: compositor, output: programOutput)
        // Second output branch sharing the same compositor: feeds the expanded
        // program window. Disabled until the window opens (zero cost when off).
        let expandedOutput = SampleBufferDisplayOutput()
        let expandedPipeline = ProgramOutputPipeline(compositor: compositor, output: expandedOutput, enabled: false)
        programPipeline.setRecorder(recorder)
        let virtualPipeline = ProgramOutputPipeline(compositor: compositor, output: virtualCameraService, enabled: false)
        self.virtualPipeline = virtualPipeline
        let capture = AVFoundationVideoCaptureService(consumers: [gestureDetector, programPipeline, expandedPipeline, virtualPipeline])

        self.gestureDetector = gestureDetector
        self.recorder = recorder
        self.virtualCameraService = virtualCameraService
        self.extensionManager = extensionManager
        self.paintController = paintController
        self.compositor = compositor
        self.programOutput = programOutput
        self.programPipeline = programPipeline
        self.expandedOutput = expandedOutput
        self.expandedPipeline = expandedPipeline
        self.camera = CameraManager(captureService: capture)
        let library = Self.loadLibrary()
        self.library = library
        self.store = PresentationCardStore(cards: library.selected?.cards ?? [])
        self.gestureMapping = Self.loadMapping()
        self.holdDuration = hold
        self.cardPosition = CardOverlayPosition(
            rawValue: UserDefaults.standard.string(forKey: Self.cardPositionKey) ?? ""
        ) ?? .bottom
        self.cardPanelPosition = CardPanelPosition(
            rawValue: UserDefaults.standard.string(forKey: Self.cardPanelKey) ?? ""
        ) ?? .right
        self.paintColor = HighlightColor(
            rawValue: UserDefaults.standard.string(forKey: Self.highlightColorKey) ?? ""
        ) ?? .yellow
        self.outputMirrorMode = OutputMirrorMode(
            rawValue: UserDefaults.standard.string(forKey: Self.mirrorModeKey) ?? ""
        ) ?? .auto
        paintController.setColor(paintColor)
        paintController.setCurrentCard(store.currentCard?.id)

        syncOverlay()
        consumeDetectorStreams()
        // Program output mirrors front cameras exactly like the preview, so
        // paint lands under the finger on screen (external cameras stay raw).
        updateOutputMirroring()
        camera.$isPreviewMirrored
            .sink { [weak self] _ in
                Task { [weak self] in
                    await MainActor.run { self?.updateOutputMirroring() }
                }
            }
            .store(in: &cancellations)
        recorder.onFinish = { [weak self] result in
            Task { [weak self] in
                await MainActor.run { self?.handleRecordingFinish(result) }
            }
        }
        extensionManager.onStatus = { [weak self] status in
            Task { [weak self] in
                await MainActor.run { self?.handleExtensionStatus(status) }
            }
        }
        virtualCameraStatus = CMIOVirtualCameraTransport.devicePresent() ? .installed : .notInstalled
        camera.$status
            .sink { [weak self] status in
                Task { [weak self] in
                    await MainActor.run {
                        if status != .running { self?.stopRecording() }
                    }
                }
            }
            .store(in: &cancellations)
        // Rest state is signing (hands ignored); a persisted listening
        // state re-arms a fresh window instead of resuming a stale one.
        if UserDefaults.standard.object(forKey: Self.detectionPausedKey) as? Bool == false {
            armCommandWindow()
        } else {
            setPaused(true)
        }
        // Paint/brush strokes are user activity too: without this the
        // window idles out mid-brush and painting silently parks.
        paintController.sink = { [compositor, weak self] layer in
            compositor.updatePaint(layer)
            Task { [weak self] in await self?.notePaintActivity() }
        }
    }

    // MARK: - Actions from mouse/keyboard

    func perform(_ action: CardAction) {
        store.apply(action)
        syncOverlay()
        paintController.setCurrentCard(store.currentCard?.id)
        lastFired = FiredFeedback(gesture: nil, action: action)
    }

    func undoPaintStroke() { paintController.undo() }
    func redoPaintStroke() { paintController.redo() }
    func clearPaintStrokes() { paintController.clear() }

    var currentCardHasPicture: Bool { store.currentCard?.imageData != nil }

    /// Synchronous open panel (app-modal); safe to call from UI actions.
    func attachPictureViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the current card"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        store.setCurrentCardImage(data)
        afterDeckContentChanged()
    }

    func removePictureFromCurrentCard() {
        store.setCurrentCardImage(nil)
        afterDeckContentChanged()
    }

    // MARK: - Presentations

    func selectPresentation(_ id: UUID) {
        library.select(id)
        guard let deck = library.selected else { return }
        store = PresentationCardStore(cards: deck.cards)
        syncOverlay()
        paintController.setCurrentCard(store.currentCard?.id)
    }

    func addPresentation() {
        let deck = library.addUntitled()
        saveLibrary()
        selectPresentation(deck.id)
    }

    func renamePresentation(_ id: UUID, name: String) {
        library.rename(id, name: name)
        saveLibrary()
    }

    func deletePresentation(_ id: UUID) {
        let wasSelected = library.selectedID == id
        library.remove(id)
        saveLibrary()
        if wasSelected, let selectedID = library.selectedID {
            selectPresentation(selectedID)
        }
    }

    func importDeckViaPanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.pdf]
        for ext in ["pptx", "ppt", "ppsx"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.message = "Choose slides to import (PDF or PowerPoint)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = nil
        isImporting = true
        let importer = importer
        Task.detached(priority: .userInitiated) {
            let result: Result<Presentation, Error>
            do {
                if url.pathExtension.lowercased() == "pdf" {
                    result = .success(try importer.importPDF(at: url))
                } else {
                    result = .success(try await importer.importPowerPoint(at: url))
                }
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isImporting = false
                switch result {
                case .success(let deck):
                    self.library.addDeck(deck)
                    self.saveLibrary()
                    self.selectPresentation(deck.id)
                case .failure(let error):
                    self.importError = (error as? PresentationImportError)?.displayMessage
                        ?? error.localizedDescription
                }
            }
        }
    }

    func clearImportError() {
        importError = nil
    }

    /// Saves an approved AI-generated lesson as a new catalog deck and
    /// selects it for presenting. The Studio's guidance travels along
    /// so re-opened decks regenerate with the same instructions.
    func saveGeneratedLesson(title: String, collection: String?, cards: [PresentationCard], aiInstructions: String? = nil) {
        let trimmed = collection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance = aiInstructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = Presentation(name: title, cards: cards,
                                collection: trimmed?.isEmpty == false ? trimmed : nil,
                                studioOrigin: true,
                                aiInstructions: guidance?.isEmpty == false ? guidance : nil)
        library.addDeck(deck)
        saveLibrary()
        selectPresentation(deck.id)
    }

    func setPresentationCollection(_ id: UUID, collection: String?) {
        guard let index = library.presentations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = collection?.trimmingCharacters(in: .whitespacesAndNewlines)
        library.presentations[index].collection = trimmed?.isEmpty == false ? trimmed : nil
        saveLibrary()
    }

    func addCardToActiveDeck() {
        store.addCard(PresentationCard(title: "New Card", message: ""))
        afterDeckContentChanged()
    }

    func removeActiveCards(at offsets: IndexSet) {
        store.removeCards(at: offsets)
        afterDeckContentChanged()
    }

    func updateActiveCard(at index: Int, title: String, message: String, detail: String?) {
        store.updateCard(at: index, title: title, message: message, detail: detail)
        afterDeckContentChanged()
    }

    func attachPictureToCard(at index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for this card"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        store.setCardImage(at: index, data)
        afterDeckContentChanged()
    }

    func removePictureFromCard(at index: Int) {
        store.setCardImage(at: index, nil)
        afterDeckContentChanged()
    }

    /// Pushes the active deck's content back to the library, overlay, and paint.
    private func afterDeckContentChanged() {
        if let selectedID = library.selectedID {
            library.updateCards(selectedID, cards: store.cards)
            saveLibrary()
        }
        syncOverlay()
        paintController.setCurrentCard(store.currentCard?.id)
    }

    /// Starts OBS output: enables the capture branch and shows the chromeless
    /// capture window. Stopping hides the window and disables the branch.
    func startOutput() {
        expandedPipeline.setEnabled(true)
        outputWindow.show(layer: expandedOutput.layer)
        isOutputRunning = true
    }

    func stopOutput() {
        expandedPipeline.setEnabled(false)
        outputWindow.hide()
        isOutputRunning = false
    }

    /// Main window closed: stop recording, output, capture, and the
    /// virtual-camera stream so no orphan window or invisible capture
    /// survives (the view dismisses the Studio window itself). Studio
    /// drafts stay in memory; Dock-click reopens the main window.
    func mainWindowClosed() {
        stopRecording()
        stopOutput()
        camera.stop()
        setVirtualCameraEnabled(false)
    }

    private func updateOutputMirroring() {
        let resolved = OutputMirrorMode.resolve(mode: outputMirrorMode, cameraMirrored: camera.isPreviewMirrored)
        outputMirrored = resolved
        compositor.setMirrored(resolved)
    }

    // MARK: - Private

    private func consumeDetectorStreams() {
        Task { [weak self] in
            guard let snapshots = self?.gestureDetector.snapshots else { return }
            for await snapshot in snapshots {
                self?.candidate = snapshot.candidate
                self?.stabilityProgress = snapshot.progress
                self?.confidence = snapshot.confidence
                self?.diagnosis = snapshot.diagnosis
                self?.landmarks = snapshot.landmarks
                self?.handDetected = !snapshot.landmarks.isEmpty
                self?.painting = snapshot.painting
            }
        }
        Task { [weak self] in
            guard let fired = self?.gestureDetector.fired else { return }
            for await gesture in fired {
                self?.handleFired(gesture)
            }
        }
        Task { [weak self] in
            guard let zoomSteps = self?.gestureDetector.zoomSteps else { return }
            for await action in zoomSteps {
                self?.registerCommandActivity()
                self?.perform(action)
            }
        }
        Task { [weak self] in
            guard let armed = self?.gestureDetector.armed else { return }
            for await _ in armed {
                self?.armCommandWindow()
            }
        }
        Task { [weak self] in
            guard let disarmed = self?.gestureDetector.disarmed else { return }
            for await _ in disarmed {
                self?.endCommandWindow()
            }
        }
    }

    private func handleFired(_ gesture: HandGesture) {
        registerCommandActivity()
        let action = router.action(for: gesture)
        if let action {
            store.apply(action)
            syncOverlay()
            paintController.setCurrentCard(store.currentCard?.id)
        }
        lastFired = FiredFeedback(gesture: gesture, action: action)
    }

    private func syncOverlay() {
        compositor.updateOverlay(ProgramOverlay(
            card: store.currentCard, isVisible: store.isVisible, position: cardPosition,
            cardPanel: cardPanelPosition,
            isExpanded: store.isExpanded,
            zoomScale: store.zoomScale(for: store.currentCard?.id),
            commandWindowRemaining: detectionPaused ? nil : commandWindowRemaining,
            cardNumber: store.currentCard == nil ? nil : store.currentIndex + 1,
            cardCount: store.cards.count
        ))
    }

    // MARK: - Command window

    /// Opens a timed window in which gestures drive cards. Called from the
    /// Listen button, the L key, or a 2 s palm hold.
    func armCommandWindow() {
        commandWindow.arm(at: Date())
        commandWindowRemaining = commandWindow.remaining(at: Date())
        setPaused(false)
        lastDotState = .green
        syncOverlay()
        startWindowTicker()
    }

    /// Ends the window early; hands are ignored again.
    func endCommandWindow() {
        windowTask?.cancel()
        windowTask = nil
        commandWindow.end()
        commandWindowRemaining = 0
        lastDotState = .off
        setPaused(true)
        syncOverlay()
    }

    func toggleCommandListening() {
        if detectionPaused {
            armCommandWindow()
        } else {
            endCommandWindow()
        }
    }

    /// User activity pushes window expiry out.
    private func registerCommandActivity() {
        guard !detectionPaused else { return }
        commandWindow.registerActivity(at: Date())
        commandWindowRemaining = commandWindow.remaining(at: Date())
        lastDotState = .green
        syncOverlay()
    }

    /// A paint/brush layer change pushes window expiry out (throttled:
    /// strokes push per frame, but the deadline only needs a nudge).
    /// Called on the main actor from the paint sink.
    private func notePaintActivity() {
        let now = Date()
        guard now.timeIntervalSince(lastPaintActivity) >= 2 else { return }
        lastPaintActivity = now
        registerCommandActivity()
    }

    /// Mouse brush on the program monitor. Explicit UI input: works
    /// whether or not the command window is open, like buttons/keys.
    func mouseBrush(_ event: MouseBrushEvent) {
        switch event {
        case let .down(point): paintController.mouseBrushDown(at: point)
        case let .moved(point): paintController.mouseBrushMoved(to: point)
        case .up: paintController.mouseBrushUp()
        }
    }

    private func setPaused(_ paused: Bool) {
        detectionPaused = paused
        gestureDetector.setDetectionPaused(paused)
        UserDefaults.standard.set(paused, forKey: Self.detectionPausedKey)
    }

    private func startWindowTicker() {
        windowTask?.cancel()
        windowTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                if self.commandWindow.tick(at: Date()) {
                    self.commandWindowRemaining = 0
                    self.lastDotState = .off
                    self.setPaused(true)
                    self.syncOverlay()
                    return
                }
                self.commandWindowRemaining = self.commandWindow.remaining(at: Date())
                let dot: DotState = self.commandWindowRemaining < 60 ? .amber : .green
                if dot != self.lastDotState {
                    self.lastDotState = dot
                    self.syncOverlay()
                }
            }
        }
    }

    // MARK: - Virtual Camera

    func setVirtualCameraEnabled(_ enabled: Bool) {
        wantVirtualCamera = enabled
        if enabled {
            guard let id = SystemExtensionManager.embeddedExtensionIdentifier() else {
                virtualCameraStatus = .failed("Camera extension not found in this app bundle.")
                return
            }
            extensionManager.activate(extensionIdentifier: id)
        } else {
            stopVirtualCameraStream()
            virtualCameraStatus = CMIOVirtualCameraTransport.devicePresent() ? .installed : .notInstalled
        }
    }

    func uninstallVirtualCamera() {
        stopVirtualCameraStream()
        guard let id = SystemExtensionManager.embeddedExtensionIdentifier() else {
            virtualCameraStatus = .notInstalled
            return
        }
        extensionManager.deactivate(extensionIdentifier: id)
    }

    func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleExtensionStatus(_ status: SystemExtensionStatus) {
        switch status {
        case .active:
            if wantVirtualCamera {
                virtualPipeline.setEnabled(true)
                virtualCameraService.start()
                virtualCameraStatus = .active
                virtualCameraStreaming = virtualCameraService.isSinkConnected
                startVirtualCameraTicker()
            } else {
                virtualCameraStatus = .installed
            }
        case .notInstalled:
            stopVirtualCameraStream()
            virtualCameraStatus = .notInstalled
        default:
            virtualCameraStatus = status
        }
    }

    private func stopVirtualCameraStream() {
        virtualCameraTask?.cancel()
        virtualCameraTask = nil
        virtualCameraStreaming = false
        virtualPipeline.setEnabled(false)
        virtualCameraService.stop()
    }

    /// Polls sink connectivity while active: the label flips to Live the
    /// moment the device publishes, with no app restart needed.
    private func startVirtualCameraTicker() {
        virtualCameraTask?.cancel()
        virtualCameraTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.virtualCameraStreaming = self.virtualCameraService.isSinkConnected
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        recordingError = nil
        recordingDropped = 0
        do {
            try recorder.start(url: Self.nextRecordingURL())
        } catch {
            recordingError = "Could not start recording: \(error.localizedDescription)"
            return
        }
        // Recording taps the program branch: force it on and restore after.
        programOutputWasEnabled = isProgramOutputEnabled
        if !programOutputWasEnabled {
            isProgramOutputEnabled = true
        }
        isRecording = true
        recordingStartDate = Date()
        recordingElapsed = 0
        startRecordingTicker()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTask?.cancel()
        recordingTask = nil
        recorder.stop()
        if isProgramOutputEnabled != programOutputWasEnabled {
            isProgramOutputEnabled = programOutputWasEnabled
        }
    }

    func revealLastRecording() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func handleRecordingFinish(_ result: VideoRecorder.FinishResult) {
        switch result {
        case let .saved(url, droppedFrames):
            lastRecordingURL = url
            recordingDropped = droppedFrames
        case .cancelled:
            recordingError = "Recording discarded (no frames captured)."
        case let .failed(message):
            recordingError = "Recording failed: \(message)"
        }
    }

    private func startRecordingTicker() {
        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                if let start = self.recordingStartDate {
                    self.recordingElapsed = Date().timeIntervalSince(start)
                }
            }
        }
    }

    private static func nextRecordingURL() -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestureCue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.recordingStamp.string(from: Date())
        return dir.appendingPathComponent("GestureCue-\(stamp).mp4", isDirectory: false)
    }

    private static let recordingStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Library persistence

    private static var libraryFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestureCue/presentations.json", isDirectory: false)
    }

    private static func loadLibrary() -> PresentationLibrary {
        if let library = PresentationLibrary.load(from: libraryFileURL) {
            let migrated = library.migrated()
            try? migrated.save(to: libraryFileURL)
            return migrated
        }
        let seeded = PresentationLibrary.seeded()
        try? seeded.save(to: libraryFileURL)
        return seeded
    }

    private func saveLibrary() {
        try? library.save(to: Self.libraryFileURL)
    }

    // MARK: - Mapping persistence

    private static func loadMapping() -> [HandGesture: CardAction] {
        guard
            let data = UserDefaults.standard.data(forKey: mappingKey),
            let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return GestureActionRouter.default.mapping }
        var mapping: [HandGesture: CardAction] = [:]
        for (gestureRaw, actionRaw) in raw {
            if let gesture = HandGesture(rawValue: gestureRaw),
               gesture != .unknown,
               let action = CardAction(rawValue: actionRaw)
            {
                mapping[gesture] = action
            }
        }
        return mapping
    }

    private func saveMapping() {
        let raw = Dictionary(uniqueKeysWithValues: gestureMapping.map { ($0.key.rawValue, $0.value.rawValue) })
        UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: Self.mappingKey)
    }

    /// Persisted trigger timing, clamped to the slider range; 0.5 s default.
    private static func loadHoldDuration() -> TimeInterval {
        let fallback = GestureStateMachine.Config().holdDuration
        guard let stored = UserDefaults.standard.object(forKey: holdDurationKey) as? TimeInterval else {
            return fallback
        }
        return min(max(stored, 0.2), 2.0)
    }
}

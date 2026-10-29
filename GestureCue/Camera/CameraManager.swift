import AVFoundation
import Foundation

/// UI-facing camera facade on the main actor: permission, device discovery and
/// selection, status publishing, and lifecycle of the injected
/// `VideoCaptureService`. Detection and program output are separate pipeline
/// branches composed by `AppViewModel`; this type never touches frame data.
@MainActor
final class CameraManager: NSObject, ObservableObject {
    enum Status: String, Sendable {
        case idle
        case requestingPermission
        case starting
        case running
        case stopped
        case denied
        case unavailable
        case failed

        var displayName: String {
            switch self {
            case .idle: "Idle"
            case .requestingPermission: "Requesting permission…"
            case .starting: "Starting…"
            case .running: "Running"
            case .stopped: "Stopped"
            case .denied: "Permission denied"
            case .unavailable: "No camera"
            case .failed: "Error"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published var selectedDeviceID: String? {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            UserDefaults.standard.set(selectedDeviceID, forKey: Self.selectedDeviceKey)
            if status == .running {
                captureService.selectDevice(deviceID: selectedDeviceID)
            }
        }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPreviewMirrored = false
    @Published var resolution: CaptureResolution = .defaultResolution {
        didSet {
            guard oldValue != resolution else { return }
            UserDefaults.standard.set(resolution.rawValue, forKey: Self.resolutionKey)
            captureService.selectResolution(resolution)
        }
    }

    var isRunning: Bool { status == .running }
    var session: AVCaptureSession { captureService.session }

    static let deniedGuidance = "Camera access is denied. Open System Settings → Privacy & Security → Camera and enable GestureCue, then press Start."

    private static let selectedDeviceKey = "GestureCue.selectedCameraID"
    private static let resolutionKey = "GestureCue.captureResolution"
    private let captureService: any VideoCaptureService

    init(captureService: any VideoCaptureService) {
        self.captureService = captureService
        super.init()
        selectedDeviceID = UserDefaults.standard.string(forKey: Self.selectedDeviceKey)
        resolution = CaptureResolution(rawValue: UserDefaults.standard.string(forKey: Self.resolutionKey) ?? "") ?? .defaultResolution
        consumeEvents()
        refreshDevices()
        observeDeviceChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start()
        case .notDetermined:
            status = .requestingPermission
            // The completion handler is nonisolated and cannot capture MainActor
            // self; relay the answer through a Sendable continuation instead.
            let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
            Task { [weak self] in
                for await granted in stream {
                    if granted {
                        self?.start()
                    } else {
                        self?.status = .denied
                        self?.errorMessage = Self.deniedGuidance
                    }
                }
            }
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.yield(granted)
                continuation.finish()
            }
        case .denied, .restricted:
            status = .denied
            errorMessage = Self.deniedGuidance
        @unknown default:
            status = .denied
            errorMessage = Self.deniedGuidance
        }
    }

    func start() {
        guard status != .running, status != .starting else { return }
        refreshDevices()
        guard !devices.isEmpty else {
            status = .unavailable
            errorMessage = "No camera was found. Connect a camera and press Start."
            return
        }
        if selectedDeviceID == nil || !devices.contains(where: { $0.uniqueID == selectedDeviceID }) {
            selectedDeviceID = devices.first?.uniqueID
        }
        errorMessage = nil
        status = .starting
        // Push the persisted resolution: didSet doesn't fire for the init
        // assignment, so without this every launch falls back to the
        // service default until the user re-toggles the picker.
        captureService.selectResolution(resolution)
        captureService.start(deviceID: selectedDeviceID)
    }

    func stop() {
        guard status == .running || status == .starting else { return }
        captureService.stop()
    }

    // MARK: - Devices

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        devices = discovery.devices
        if let selectedDeviceID, !devices.contains(where: { $0.uniqueID == selectedDeviceID }) {
            self.selectedDeviceID = devices.first?.uniqueID
            if status == .running {
                errorMessage = "The selected camera was disconnected."
            }
        }
    }

    private func observeDeviceChanges() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(deviceListDidChange), name: .AVCaptureDeviceWasConnected, object: nil)
        center.addObserver(self, selector: #selector(deviceListDidChange), name: .AVCaptureDeviceWasDisconnected, object: nil)
    }

    @objc private nonisolated func deviceListDidChange() {
        Task { @MainActor [weak self] in self?.refreshDevices() }
    }

    // MARK: - Events

    private func consumeEvents() {
        Task { [weak self] in
            guard let events = self?.captureService.events else { return }
            for await event in events {
                self?.apply(event)
            }
        }
    }

    private func apply(_ event: CaptureEvent) {
        switch event {
        case let .started(isPreviewMirrored):
            self.isPreviewMirrored = isPreviewMirrored
            status = .running
            errorMessage = nil
        case .stopped:
            status = .stopped
        case let .failed(message):
            status = .failed
            errorMessage = message
        case let .interrupted(message):
            errorMessage = message
        case .interruptionEnded:
            if status == .running {
                errorMessage = nil
            }
        }
    }
}

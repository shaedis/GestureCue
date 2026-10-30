import AppKit
import SwiftUI

/// Raw camera preview with landmark overlay, capture controls, permission
/// status, device selection, and the composited program-output monitor.
struct CameraPanelView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox("Camera") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    preview
                    controls
                    Divider()
                    programOutput
                }
            }
        }
        .groupBoxStyle(.automatic)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.9))
            if camera.isRunning {
                CameraPreviewView(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if viewModel.showLandmarks {
                    LandmarkOverlayView(points: viewModel.landmarks, mirrored: camera.isPreviewMirrored)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(statusLine)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .frame(minHeight: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(camera.isRunning ? "Live camera preview" : "Camera preview off. \(statusLine)")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if camera.isRunning {
                    Button("Stop Camera") { camera.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Start Camera") { camera.requestPermissionAndStart() }
                        .buttonStyle(.borderedProminent)
                        .disabled(camera.status == .starting || camera.status == .requestingPermission)
                }
                Spacer()
                Text("Status: \(camera.status.displayName)")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            if camera.status == .denied {
                Text(CameraManager.deniedGuidance)
                    .font(.callout)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            if let error = camera.errorMessage, camera.status != .denied {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Picker("Camera", selection: $camera.selectedDeviceID) {
                ForEach(camera.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID as String?)
                }
            }
            .disabled(camera.devices.isEmpty)

            Toggle("Show hand landmarks", isOn: $viewModel.showLandmarks)
        }
    }

    private var programOutput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Program Output")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("The composited feed: camera plus card overlay. Start Output below to open the fullscreen capture window for OBS and Zoom.")
                .font(.caption)
                .foregroundColor(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                ProgramOutputView(
                    layer: viewModel.programOutput.layer,
                    videoSize: camera.resolution.pixelSize,
                    mirrored: viewModel.outputMirrored,
                    onBrush: { viewModel.mouseBrush($0) }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(minHeight: 140)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Composited program output preview")
            Picker("Card position", selection: $viewModel.cardPosition) {
                ForEach(CardOverlayPosition.allCases, id: \.self) { position in
                    Text(position.displayName).tag(position)
                }
            }
            .pickerStyle(.segmented)
            if viewModel.cardPosition == .sideBySide {
                Picker("Card panel", selection: $viewModel.cardPanelPosition) {
                    ForEach(CardPanelPosition.allCases, id: \.self) { panel in
                        Text(panel.displayName).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
            }
            Picker("Paint color", selection: $viewModel.paintColor) {
                ForEach(HighlightColor.allCases, id: \.self) { color in
                    Text(color.displayName).tag(color)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Enable program output", isOn: $viewModel.isProgramOutputEnabled)
            Divider()
            outputControls
            Divider()
            recording
            Divider()
            virtualCamera
        }
    }

    private var virtualCamera: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Virtual Camera")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(virtualCameraStatusLine)
                .font(.callout)
                .fontWeight(.semibold)
                .accessibilityLabel("Virtual camera status: \(virtualCameraStatusLine)")
            Text("Zoom and Teams see “GestureCue Camera” directly. Needs the app in /Applications plus one approval in System Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                if viewModel.virtualCameraStatus == .active {
                    Button("Stop Camera") { viewModel.setVirtualCameraEnabled(false) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Enable Camera") { viewModel.setVirtualCameraEnabled(true) }
                        .buttonStyle(.borderedProminent)
                }
                if viewModel.virtualCameraStatus == .needsApproval {
                    Button("Open Settings") { viewModel.openExtensionSettings() }
                }
                // Always offered (except mid-removal): the extension can be
                // staged while the device is unpublished, in which case the
                // status reads "Not installed" yet only Uninstall can reset it.
                if viewModel.virtualCameraStatus != .deactivating {
                    Button("Uninstall") { viewModel.uninstallVirtualCamera() }
                }
                Spacer()
            }
        }
    }

    private var virtualCameraStatusLine: String {
        switch viewModel.virtualCameraStatus {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed — streaming off"
        case .activating: return "Activating…"
        case .deactivating: return "Removing…"
        case .needsApproval: return "Needs your approval in System Settings"
        case .needsReboot: return "Reboot to finish, then Enable again"
        case .active:
            return viewModel.virtualCameraStreaming
                ? "Live — pick “GestureCue Camera” in Zoom"
                : "Enabled — waiting for the camera device…"
        case .failed(let message): return "Error: \(message)"
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output to OBS")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Clean video-only window for OBS Window Capture → Virtual Camera → Zoom. Setup: docs/OBS-ZOOM-SETUP.md.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                if viewModel.isOutputRunning {
                    Button("Stop Output") { viewModel.stopOutput() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Start Output") { viewModel.startOutput() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!camera.isRunning)
                }
                Spacer()
            }
            Text(outputStatusLine)
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityLabel("Output status: \(outputStatusLine)")
            Picker("Resolution", selection: $camera.resolution) {
                ForEach(CaptureResolution.allCases, id: \.self) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
            .pickerStyle(.segmented)
            Picker("Mirroring", selection: $viewModel.outputMirrorMode) {
                ForEach(OutputMirrorMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Record to MP4")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Saves the composited feed (video + cards + paint, no audio) to Movies ▸ GestureCue.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                if viewModel.isRecording {
                    Button("Stop Recording") { viewModel.stopRecording() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    Text(Self.mmss(viewModel.recordingElapsed))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                        .accessibilityLabel("Recording elapsed: \(Self.mmss(viewModel.recordingElapsed))")
                } else {
                    Button("Record") { viewModel.startRecording() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: [])
                        .disabled(!camera.isRunning)
                }
                Spacer()
            }
            if let url = viewModel.lastRecordingURL {
                HStack(spacing: 8) {
                    Text("Saved \(url.lastPathComponent)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Reveal in Finder") { viewModel.revealLastRecording() }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Last recording: \(url.lastPathComponent)")
            }
            if viewModel.recordingDropped > 0 {
                Text("\(viewModel.recordingDropped) frame(s) dropped (resolution changed mid-recording).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let error = viewModel.recordingError {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
            }
        }
    }

    private static func mmss(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var outputStatusLine: String {
        let state = viewModel.isOutputRunning ? "Running" : "Stopped"
        let mirror = viewModel.outputMirrored ? "Mirrored" : "Original"
        return "Output \(state) · \(camera.resolution.displayName) · \(mirror)"
    }

    private var statusLine: String {
        switch camera.status {
        case .idle, .stopped: "Press Start to enable the camera."
        case .requestingPermission, .starting: "Starting camera…"
        case .running: "Live"
        case .denied: "Camera permission denied."
        case .unavailable: "No camera found."
        case .failed: camera.errorMessage ?? "Camera error."
        }
    }
}

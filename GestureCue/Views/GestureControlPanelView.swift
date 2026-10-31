import SwiftUI

/// Current gesture readout with stability meter, the configurable
/// gesture-to-action mapping, and fire feedback.
struct GestureControlPanelView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GroupBox("Gesture Control") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    listening
                    Divider()
                    currentGesture
                    Divider()
                    triggerTiming
                    Divider()
                    mapping
                    Divider()
                    paint
                    Divider()
                    feedback
                }
            }
        }
    }

    private var currentGesture: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recognized Gesture")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                if let image = viewModel.candidate.systemImage {
                    Image(systemName: image)
                        .font(.title)
                        .foregroundColor(.accentColor)
                }
                Text(viewModel.candidate.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recognized gesture: \(viewModel.candidate.displayName)")

            ProgressView(value: viewModel.stabilityProgress) {
                Text(stabilityLabel)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Gesture stability: \(stabilityLabel)")
            Text(confidenceLine)
                .font(.callout)
                .foregroundColor(.secondary)
                .accessibilityLabel("Classification confidence: \(confidenceLine)")
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.handDetected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(viewModel.handDetected ? "Hand detected" : "No hand detected")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(viewModel.handDetected ? "Hand detected" : "No hand detected")
            Text("Index up + thumb raised: spread/pinch to zoom. Thumb tucked: card gestures. Index + middle together: brush — strokes fade away.")
                .font(.callout)
                .foregroundColor(.secondary)
            if viewModel.handDetected {
                Text(viewModel.diagnosis)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Classifier diagnosis: \(viewModel.diagnosis)")
            }
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command Listening")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.detectionPaused ? Color.gray : Color.green)
                    .frame(width: 8, height: 8)
                Text(listeningLine)
                    .font(.callout)
                    .fontWeight(.semibold)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Command listening: \(listeningLine)")
            Text("Hold an open palm still for 2 seconds to listen; a still fist for 2 seconds to stop. Listening ends on its own after 5 idle minutes.")
                .font(.caption)
                .foregroundColor(.secondary)
            Button(viewModel.detectionPaused ? "Listen for commands (L)" : "Stop listening (L)") {
                viewModel.toggleCommandListening()
            }
            .keyboardShortcut("l", modifiers: [])
        }
    }

    private var listeningLine: String {
        if viewModel.detectionPaused {
            "Signing — hands ignored"
        } else {
            "Listening — idles out in \(Self.countdown(viewModel.commandWindowRemaining))"
        }
    }

    private static func countdown(_ remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var confidenceLine: String {
        if viewModel.candidate == .unknown {
            "Confidence: —"
        } else {
            "Confidence: \(Int((viewModel.confidence * 100).rounded()))%"
        }
    }

    private var stabilityLabel: String {
        if viewModel.detectionPaused {
            "Paused — sign freely, the camera is ignoring hands"
        } else if viewModel.candidate == .unknown {
            "Show a gesture to the camera"
        } else if viewModel.stabilityProgress >= 1 {
            "Stable — action triggered"
        } else {
            "Hold steady…"
        }
    }

    private var triggerTiming: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trigger Timing")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("How long to hold a gesture still before it fires.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Slider(value: $viewModel.holdDuration, in: 0.2...2.0, step: 0.1)
                    .accessibilityLabel("Hold seconds to trigger")
                    .accessibilityValue(holdLabel)
                Text(holdLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private var holdLabel: String {
        String(format: "%.1f s (%d ms)", viewModel.holdDuration, Int((viewModel.holdDuration * 1000).rounded()))
    }

    private var mapping: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gesture Actions")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Choose which action each gesture triggers.")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(HandGesture.assignable) { gesture in
                Picker(gesture.displayName, selection: mappingBinding(for: gesture)) {
                    Text("None").tag(CardAction?.none)
                    ForEach(CardAction.allCases) { action in
                        Text(action.displayName).tag(CardAction?.some(action))
                    }
                }
            }
            Toggle("Pinch to zoom pictures", isOn: $viewModel.zoomEnabled)
            Text("Spreading or pinching thumb + index (thumb raised) zooms the card picture. Turn off to disable; + / − keys always work.")
                .font(.caption)
                .foregroundColor(.secondary)
            Toggle("Two-finger brush", isOn: $viewModel.brushEnabled)
            Text("Index + middle finger paints fading highlight strokes. Turn off to disable.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func mappingBinding(for gesture: HandGesture) -> Binding<CardAction?> {
        Binding(
            get: { viewModel.gestureMapping[gesture] },
            set: { viewModel.gestureMapping[gesture] = $0 }
        )
    }

    private var paint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finger Paint")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Paint Mode", isOn: $viewModel.paintMode)
            if viewModel.paintMode {
                Text(paintStatusLine)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .accessibilityLabel("Paint status: \(paintStatusLine)")
                Text("Pinch thumb + index and drag to paint on the card. Palm/fist still control the card; index-family gestures are paused.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("Undo") { viewModel.undoPaintStroke() }
                        .keyboardShortcut("z", modifiers: .command)
                    Button("Redo") { viewModel.redoPaintStroke() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Button("Clear") { viewModel.clearPaintStrokes() }
                }
            }
        }
    }

    private var paintStatusLine: String {
        if viewModel.painting {
            "Painting…"
        } else if viewModel.handDetected {
            "Pointing — pinch to paint"
        } else {
            "Show your hand to begin"
        }
    }

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last Action")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let fired = viewModel.lastFired {
                HStack(spacing: 8) {
                    Image(systemName: fired.action == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundColor(fired.action == nil ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fired.action?.displayName ?? "No action assigned")
                            .fontWeight(.semibold)
                        Text(sourceLine(for: fired))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Last action: \(fired.action?.displayName ?? "none"). \(sourceLine(for: fired))")
            } else {
                Text("No action yet")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func sourceLine(for fired: AppViewModel.FiredFeedback) -> String {
        if let gesture = fired.gesture {
            "via \(gesture.displayName) gesture"
        } else {
            "via mouse or keyboard"
        }
    }
}

import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HSplitView {
            CameraPanelView(camera: viewModel.camera, viewModel: viewModel)
                .frame(minWidth: 330, idealWidth: 400, maxWidth: 480)
            GestureControlPanelView(viewModel: viewModel)
                .frame(minWidth: 270, idealWidth: 310, maxWidth: 380)
            PresentationCardPanelView(viewModel: viewModel)
                .frame(minWidth: 380)
        }
        .padding(12)
        .toolbar {
            Button("AI Studio") { openWindow(id: "ai-studio") }
                .accessibilityLabel("Open AI Visual Education Studio")
        }
        .onDisappear {
            dismissWindow(id: "ai-studio")
            viewModel.mainWindowClosed()
        }
    }
}

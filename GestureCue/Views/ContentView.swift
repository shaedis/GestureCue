import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

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
    }
}

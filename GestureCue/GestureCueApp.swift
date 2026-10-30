import SwiftUI

/// Manual build counter, bumped on every restage so testers can confirm
/// which build is running (plain `open` won't restart a running app).
enum AppInfo {
    static let build = 71
}

@main
struct GestureCueApp: App {
    @StateObject private var viewModel: AppViewModel
    @StateObject private var studioViewModel: StudioViewModel

    init() {
        preventMultipleInstances()
        // Own both view models once: constructing the Studio model in the
        // Scene body below would rebuild (and wipe drafts) on every state
        // change in the main window.
        let app = AppViewModel()
        _viewModel = StateObject(wrappedValue: app)
        _studioViewModel = StateObject(wrappedValue: StudioViewModel(app: app))
    }

    var body: some Scene {
        WindowGroup("GestureCue (Build \(AppInfo.build))") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 1080, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 740)
        .windowResizability(.contentSize)
        // Single Window (not a group): repeat opens focus the existing
        // Studio instead of piling up instances.
        Window("AI Visual Education Studio", id: "ai-studio") {
            StudioView(viewModel: studioViewModel)
                .frame(minWidth: 560, minHeight: 600)
        }
        .defaultSize(width: 680, height: 800)
    }
}

/// Single-instance guard: two copies would fight over the webcam, and
/// relaunches must reuse the running app instead of piling up Dock icons.
/// A duplicate activates the original and quits immediately.
private func preventMultipleInstances() {
    // Unit tests run inside the app host; never quit under XCTest.
    guard NSClassFromString("XCTestCase") == nil else { return }
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me }
    guard !others.isEmpty else { return }
    others.first?.activate()
    // Pre-launch: NSApp isn't usable yet, so exit directly instead of
    // terminating. Nothing has initialized: no windows, no camera, no writes.
    exit(0)
}

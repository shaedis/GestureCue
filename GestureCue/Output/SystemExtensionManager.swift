import Foundation
import SystemExtensions

/// Lifecycle state of the GestureCue camera extension. The manager reports
/// request progress; the view model additionally sets `.installed` for the
/// present-but-idle state (extension loaded, streaming off).
enum SystemExtensionStatus: Sendable, Equatable {
    case notInstalled
    case installed
    case activating
    case deactivating
    case needsApproval
    case needsReboot
    case active
    case failed(String)
}

/// Activates/deactivates the embedded camera system extension and reports
/// lifecycle events. The host app must live in /Applications for macOS to
/// activate the extension.
final class SystemExtensionManager: NSObject, @unchecked Sendable {
    var onStatus: ((SystemExtensionStatus) -> Void)?

    private let lock = NSLock()
    private var activating = true

    /// Bundle ID of the appex embedded in this app, if present.
    static func embeddedExtensionIdentifier() -> String? {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ),
            let extURL = urls.first(where: { $0.pathExtension == "systemextension" }),
            let bundle = Bundle(url: extURL)
        else { return nil }
        return bundle.bundleIdentifier
    }

    func activate(extensionIdentifier: String) {
        lock.withLock { activating = true }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        report(.activating)
    }

    func deactivate(extensionIdentifier: String) {
        lock.withLock { activating = false }
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        report(.deactivating)
    }

    private func report(_ status: SystemExtensionStatus) {
        let handler = lock.withLock { onStatus }
        handler?(status)
    }
}

extension SystemExtensionManager: OSSystemExtensionRequestDelegate {
    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        report(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let wasActivating = lock.withLock { activating }
        if result == .completed {
            report(wasActivating ? .active : .notInstalled)
        } else {
            report(.needsReboot)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        report(.failed(error.localizedDescription))
    }
}

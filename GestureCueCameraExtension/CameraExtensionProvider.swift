import CoreMediaIO
import Foundation

/// Device name published to Zoom/Teams/…. Must match the host app's
/// discovery string (separate targets: kept in sync by hand).
let virtualCameraDeviceName = "GestureCue Camera"

/// Provider for the GestureCue virtual camera: one device carrying a 720p
/// source stream (video out to video apps) fed by a sink stream (video in
/// from the GestureCue app). No AppKit here — the extension is sandboxed.
final class CameraExtensionProvider: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraExtensionDevice!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraExtensionDevice(localizedName: virtualCameraDeviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "GestureCue"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

import CoreMediaIO
import Foundation

let providerSource = CameraExtensionProvider(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()

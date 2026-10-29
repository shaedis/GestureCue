import AVFoundation
import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

/// Device name published by the extension. Must match the extension's device
/// (separate targets: kept in sync by hand).
let virtualCameraDeviceName = "GestureCue Camera"

private let virtualCameraLogger = Logger(subsystem: "com.gesturecue.app", category: "VirtualCamera")

/// Sends composited frames into the extension's sink stream.
protocol VirtualCameraSinkTransport: Sendable {
    func connect() -> Bool
    func disconnect()
    var isConnected: Bool { get }
    /// Sends one 1280×720 BGRA buffer; false = dropped (sink not ready).
    func send(_ pixelBuffer: CVPixelBuffer) -> Bool
}

/// Scales program frames to the fixed virtual-camera format (720p BGRA).
/// Passthrough when already 720p. All operations are thread-safe.
final class VirtualCameraFrameScaler: @unchecked Sendable {
    static let width = 1280
    static let height = 720
    static let frameRate = 30

    private let context = CIContext()
    private let pool: CVPixelBufferPool?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        var pool: CVPixelBufferPool?
        let attributes: NSDictionary = [
            kCVPixelBufferWidthKey: Self.width,
            kCVPixelBufferHeightKey: Self.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool)
        self.pool = pool
    }

    /// Returns the input unchanged when already 720p, else a scaled copy.
    /// Sources are always 16:9 (720p/1080p camera), so this never distorts.
    func scaleToCameraSize(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(buffer) == Self.width, CVPixelBufferGetHeight(buffer) == Self.height {
            return buffer
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        // `bounds` only selects a source region (a bottom-left crop), it never
        // rescales: shrink the full frame onto the fixed buffer instead.
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(Self.width) / extent.width,
            y: CGFloat(Self.height) / extent.height
        ))
        context.render(
            scaled, to: out,
            bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), colorSpace: colorSpace
        )
        return out
    }
}

/// `VideoOutputService` feeding the GestureCue virtual camera: finds the
/// extension's sink stream, scales frames to 720p, and enqueues them.
/// Drops (never blocks) when the sink is missing or busy.
final class VirtualCameraService: VideoOutputService, @unchecked Sendable {
    private let transport: any VirtualCameraSinkTransport
    private let scaler: VirtualCameraFrameScaler
    private let lock = NSLock()
    private var started = false
    private var lastConnectAttempt = Date.distantPast

    init(transport: any VirtualCameraSinkTransport, scaler: VirtualCameraFrameScaler = VirtualCameraFrameScaler()) {
        self.transport = transport
        self.scaler = scaler
    }

    var isRunning: Bool {
        lock.withLock { started }
    }

    /// True once the sink stream is open and frames actually flow.
    /// Distinct from `isRunning`: activation can succeed while the
    /// device is still unpublished (no frames flow until it appears).
    var isSinkConnected: Bool {
        transport.isConnected
    }

    func start() {
        lock.withLock { started = true }
        _ = transport.connect()
    }

    func stop() {
        lock.withLock { started = false }
        transport.disconnect()
    }

    func publish(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp _: CMTime) {
        let running = lock.withLock { started }
        guard running else { return }
        if !transport.isConnected {
            // Extension approved after we started: retry at most once a second.
            let now = Date()
            let last = lock.withLock { lastConnectAttempt }
            guard now.timeIntervalSince(last) >= 1 else { return }
            lock.withLock { lastConnectAttempt = now }
            guard transport.connect() else { return }
        }
        guard let frame = scaler.scaleToCameraSize(pixelBuffer) else { return }
        _ = transport.send(frame)
    }
}

/// Real sink transport over the CoreMediaIO C API: discovers the
/// "GestureCue Camera" device, opens its sink stream, and enqueues
/// IOSurface-backed sample buffers. Hardware-bound (no unit tests).
final class CMIOVirtualCameraTransport: VirtualCameraSinkTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var deviceID: CMIODeviceID?
    private var sinkStream: CMIOStreamID?
    private var sinkQueue: CMSimpleQueue?
    private var videoDescription: CMFormatDescription?
    private var loggedFirstSend = false
    private var loggedDrop = false

    static func devicePresent() -> Bool {
        findDevice() != nil
    }

    var isConnected: Bool {
        lock.withLock { sinkQueue != nil }
    }

    func connect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if sinkQueue != nil { return true }
        loggedFirstSend = false
        loggedDrop = false
        guard let (device, sink) = Self.openSink() else {
            virtualCameraLogger.error("virtual camera sink unavailable")
            return false
        }
        virtualCameraLogger.info("virtual camera sink connected")
        var videoDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: Int32(VirtualCameraFrameScaler.width), height: Int32(VirtualCameraFrameScaler.height),
            extensions: nil, formatDescriptionOut: &videoDescription
        )
        guard let videoDescription else { return false }
        self.videoDescription = videoDescription
        deviceID = device
        sinkStream = sink.stream
        sinkQueue = sink.queue
        return true
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if let deviceID, let sinkStream {
            CMIODeviceStopStream(deviceID, sinkStream)
        }
        deviceID = nil
        sinkStream = nil
        sinkQueue = nil
        videoDescription = nil
    }

    func send(_ pixelBuffer: CVPixelBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let sinkQueue, let videoDescription else {
            if !loggedDrop {
                loggedDrop = true
                virtualCameraLogger.error("dropping frame: sink not connected")
            }
            return false
        }
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else {
            if !loggedDrop {
                loggedDrop = true
                virtualCameraLogger.error("dropping frame: sink queue full")
            }
            return false
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(VirtualCameraFrameScaler.frameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: videoDescription,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else {
            if !loggedDrop {
                loggedDrop = true
                virtualCameraLogger.error("dropping frame: sample creation failed")
            }
            return false
        }
        CMSimpleQueueEnqueue(sinkQueue, element: Unmanaged.passRetained(sample).toOpaque())
        if !loggedFirstSend {
            loggedFirstSend = true
            virtualCameraLogger.info("first frame enqueued to sink")
        }
        return true
    }

    // MARK: - Discovery (static, lock-free)

    private struct OpenSink {
        var stream: CMIOStreamID
        var queue: CMSimpleQueue
    }

    private static func openSink() -> (device: CMIODeviceID, sink: OpenSink)? {
        guard let device = findDevice() else { return nil }
        let streams = deviceStreams(device)
        // Open only the sink stream (matched by our controlled stream name).
        // Never fall through to the source: enqueuing there loses frames.
        for stream in streams {
            let name = objectName(stream) ?? "<unnamed>"
            let direction = streamDirection(stream).map(String.init(describing:)) ?? "?"
            virtualCameraLogger.info(
                "stream \(stream, privacy: .public) name=\(name, privacy: .public) direction=\(direction, privacy: .public)"
            )
            if name.localizedCaseInsensitiveContains("Sink") {
                guard let sink = tryOpenSink(device: device, stream: stream) else {
                    virtualCameraLogger.error("sink stream open failed")
                    return nil
                }
                return (device, sink)
            }
        }
        virtualCameraLogger.error("no sink stream found among \(streams.count, privacy: .public) streams")
        return nil
    }

    private static func tryOpenSink(device: CMIODeviceID, stream: CMIOStreamID) -> OpenSink? {
        var queue: Unmanaged<CMSimpleQueue>?
        let status = withUnsafeMutablePointer(to: &queue) { pointer in
            CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, pointer)
        }
        guard status == noErr, let queue else { return nil }
        guard CMIODeviceStartStream(device, stream) == noErr else { return nil }
        return OpenSink(stream: stream, queue: queue.takeUnretainedValue())
    }

    private static func findDevice() -> CMIODeviceID? {
        let devices = allDevices()
        var names: [String] = []
        for device in devices {
            guard let name = objectName(device) else { continue }
            names.append(name)
            if name == virtualCameraDeviceName {
                return device
            }
        }
        virtualCameraLogger.error(
            "device not found among \(devices.count, privacy: .public): \(names.joined(separator: ","), privacy: .public)"
        )
        logAVFoundationDevices()
        return cmioDeviceIDFromAVFoundation()
    }

    private static func logAVFoundationDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        )
        for device in session.devices {
            virtualCameraLogger.error(
                "av device: \(device.localizedName, privacy: .public) type=\(device.deviceType.rawValue, privacy: .public)"
            )
        }
    }

    private static func cmioDeviceIDFromAVFoundation() -> CMIODeviceID? {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified
        )
        guard let match = session.devices.first(where: { $0.localizedName == virtualCameraDeviceName }) else {
            return nil
        }
        virtualCameraLogger.error("av fallback: found by name, matching UID")
        for device in allDevices() {
            if deviceUID(device) == match.uniqueID {
                virtualCameraLogger.error("av fallback: UID matched")
                return device
            }
        }
        virtualCameraLogger.error("av fallback: UID did not match")
        return nil
    }

    private static func deviceUID(_ device: CMIODeviceID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr else { return nil }
        var uid: CFString = "" as NSString
        let uidStatus = withUnsafeMutablePointer(to: &uid) {
            CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &dataUsed, $0)
        }
        guard uidStatus == noErr else { return nil }
        return String(uid)
    }

    private static func allDevices() -> [CMIODeviceID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        _ = devices.withUnsafeMutableBufferPointer { buffer in
            CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &dataUsed, buffer.baseAddress)
        }
        return devices
    }

    private static func objectName(_ object: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr else { return nil }
        var name: CFString = "" as NSString
        let nameStatus = withUnsafeMutablePointer(to: &name) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, $0)
        }
        guard nameStatus == noErr else { return nil }
        return String(name)
    }

    private static func streamDirection(_ stream: CMIOStreamID) -> UInt32? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var direction: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(stream, &address, 0, nil, &dataSize) == noErr,
              dataSize == MemoryLayout<UInt32>.size,
              CMIOObjectGetPropertyData(stream, &address, 0, nil, dataSize, &dataUsed, &direction) == noErr
        else { return nil }
        return direction
    }

    private static func deviceStreams(_ device: CMIODeviceID) -> [CMIOStreamID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streams = [CMIOStreamID](repeating: 0, count: count)
        _ = streams.withUnsafeMutableBufferPointer { buffer in
            CMIOObjectGetPropertyData(device, &address, 0, nil, dataSize, &dataUsed, buffer.baseAddress)
        }
        return streams
    }
}

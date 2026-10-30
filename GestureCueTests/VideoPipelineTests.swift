import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import GestureCue

/// Exercises composition and program output with synthetic frames (no camera).
final class VideoPipelineTests: XCTestCase {
    // MARK: - Synthetic frame helpers

    private func makePixelBuffer(width: Int = 640, height: Int = 360, gray: UInt8 = 128) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4 + 0] = gray
                row[x * 4 + 1] = gray
                row[x * 4 + 2] = gray
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format
        else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: 0, timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    private func bufferBytes(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        return Array(UnsafeRawBufferPointer(start: base, count: count))
    }

    /// Near-white pixels in a horizontal fraction band of the frame.
    /// Split test frame: left half black, right half white (mirror probe).
    private func makeSplitPixelBuffer(width: Int = 640, height: Int = 360) -> CVPixelBuffer? {
        guard let buffer = makePixelBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let v: UInt8 = x < width / 2 ? 0 : 255
                row[x * 4] = v
                row[x * 4 + 1] = v
                row[x * 4 + 2] = v
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func brightPixelCount(_ buffer: CVPixelBuffer, xFraction: Range<Double>) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = Int(Double(width) * xFraction.lowerBound)
        let x1 = Int(Double(width) * xFraction.upperBound)
        var count = 0
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in x0..<x1 {
                if row[x * 4] > 200, row[x * 4 + 1] > 200, row[x * 4 + 2] > 200 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Pixels matching a predicate over (r, g, b) in a frame fraction.
    private func coloredPixelCount(_ buffer: CVPixelBuffer, yFraction: Range<Double> = 0 ..< 1, xFraction: Range<Double> = 0 ..< 1, where matches: (UInt8, UInt8, UInt8) -> Bool) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let y0 = Int(Double(height) * yFraction.lowerBound)
        let y1 = Int(Double(height) * yFraction.upperBound)
        let x0 = Int(Double(width) * xFraction.lowerBound)
        let x1 = Int(Double(width) * xFraction.upperBound)
        var count = 0
        for y in y0..<y1 {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in x0..<x1 {
                if matches(row[x * 4 + 2], row[x * 4 + 1], row[x * 4]) {
                    count += 1
                }
            }
        }
        return count
    }

    /// 96×64 PNG: top half red, bottom half blue (orientation probe).
    private func makeTestImageData() -> Data? {
        let width = 96, height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        // Bitmap context is y-up: upper rect is memory rows 0..<32 (image top).
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Memory rows (0 = displayed top) containing a matching pixel.
    private func coloredRows(_ buffer: CVPixelBuffer, where matches: (UInt8, UInt8, UInt8) -> Bool) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var rows: [Int] = []
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where matches(row[x * 4 + 2], row[x * 4 + 1], row[x * 4]) {
                rows.append(y)
                break
            }
        }
        return rows
    }

    /// Near-white pixels in the displayed bottom strip where the banner lives.
    private func brightPixelCount(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var count = 0
        for y in (height * 6 / 10)..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                if row[x * 4] > 200, row[x * 4 + 1] > 200, row[x * 4 + 2] > 200 {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - Compositor

    func testCompositeWithoutOverlayKeepsDimensions() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let output = try XCTUnwrap(CardOverlayCompositor().composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 360)
    }

    func testVisibleOverlayChangesOutput() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: false))
        let clean = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: true))
        let banner = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertNotEqual(bufferBytes(clean), bufferBytes(banner), "the card banner must burn into the program feed")
    }

    func testOverlayRendersReadableText() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: true))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertGreaterThan(brightPixelCount(output), 100, "banner must contain rendered glyph pixels")
    }

    func testEmptyCardRendersNoBrightPixels() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard(title: "", message: ""), isVisible: true))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertEqual(brightPixelCount(output), 0)
    }

    func testLeftPositionRendersTextOnLeft() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: true, position: .left))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertGreaterThan(brightPixelCount(output, xFraction: 0 ..< 0.5), 100, "glyphs must appear in the left half")
        XCTAssertEqual(brightPixelCount(output, xFraction: 0.75 ..< 1.0), 0, "right quarter must stay clean video")
    }

    func testRightPositionRendersTextOnRight() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: true, position: .right))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertGreaterThan(brightPixelCount(output, xFraction: 0.5 ..< 1.0), 100, "glyphs must appear in the right half")
        XCTAssertEqual(brightPixelCount(output, xFraction: 0 ..< 0.25), 0, "left quarter must stay clean video")
    }

    func testExpandedCardRectFillsFrame() {
        let rect = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .bottom, expanded: true)
        XCTAssertEqual(rect.minX, 51.2, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 51.2, accuracy: 0.01)
        XCTAssertEqual(rect.width, 1177.6, accuracy: 0.01)
        XCTAssertEqual(rect.height, 617.6, accuracy: 0.01)
        // The position preset is irrelevant when expanded.
        XCTAssertEqual(rect, CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .left, expanded: true))
    }

    func testExpandedRendersBiggerText() throws {
        let card = PresentationCard(title: "Question time", message: "Raise your hand if you have a question.")
        let collapsedFrame = try XCTUnwrap(makePixelBuffer())
        let collapsedCompositor = CardOverlayCompositor()
        collapsedCompositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .bottom, isExpanded: false))
        let collapsed = try XCTUnwrap(collapsedCompositor.composite(cameraFrame: collapsedFrame, presentationTimeStamp: .zero))
        let expandedFrame = try XCTUnwrap(makePixelBuffer())
        let expandedCompositor = CardOverlayCompositor()
        expandedCompositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .bottom, isExpanded: true))
        let expanded = try XCTUnwrap(expandedCompositor.composite(cameraFrame: expandedFrame, presentationTimeStamp: .zero))
        let collapsedBright = brightPixelCount(collapsed, xFraction: 0 ..< 1)
        let expandedBright = brightPixelCount(expanded, xFraction: 0 ..< 1)
        XCTAssertGreaterThan(collapsedBright, 0, "sanity: collapsed card renders glyphs")
        XCTAssertGreaterThan(expandedBright, collapsedBright, "expanded text must cover more pixels")
    }

    func testMirroredOutputFlipsCameraFrame() throws {
        let frame = try XCTUnwrap(makeSplitPixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.setMirrored(true)
        compositor.updateOverlay(ProgramOverlay(card: nil, isVisible: false))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertGreaterThan(brightPixelCount(output, xFraction: 0 ..< 0.25), 1000, "mirrored left quarter shows the white half")
        XCTAssertEqual(brightPixelCount(output, xFraction: 0.75 ..< 1.0), 0, "mirrored right quarter shows the black half")
    }

    func testUnmirroredOutputKeepsCameraFrame() throws {
        let frame = try XCTUnwrap(makeSplitPixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: nil, isVisible: false))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertEqual(brightPixelCount(output, xFraction: 0 ..< 0.25), 0)
        XCTAssertGreaterThan(brightPixelCount(output, xFraction: 0.75 ..< 1.0), 1000)
    }

    func testMirroredPaintLandsUnderFinger() throws {
        let card = PresentationCard(title: "", message: "")
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.setMirrored(true)
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .bottom))
        let dot = PaintStroke(color: .yellow, points: [CGPoint(x: 0.1, y: 0.2)])
        compositor.updatePaint(PaintLayer(strokes: [dot]))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        func isYellow(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g > 150 && b < 100 }
        XCTAssertGreaterThan(
            coloredPixelCount(output, xFraction: 0.8 ..< 1.0, where: isYellow), 0,
            "mirrored dot from raw x=0.1 must land on the right"
        )
        XCTAssertEqual(
            coloredPixelCount(output, xFraction: 0 ..< 0.2, where: isYellow), 0,
            "no yellow may remain on the left"
        )
    }

    func testListeningDotRect() {
        let rect = CardOverlayCompositor.listeningDotRect(width: 640, height: 360)
        XCTAssertEqual(rect.minX, 19.2, accuracy: 0.01)
        XCTAssertEqual(rect.width, 12.96, accuracy: 0.01)
        XCTAssertEqual(rect.maxY, 360 - 19.2, accuracy: 0.01)
    }

    func testListeningDotColors() {
        let green = CardOverlayCompositor.listeningDotColor(remaining: 120).components ?? []
        XCTAssertEqual(green.count, 4)
        XCTAssertEqual(green[1], 0.85, accuracy: 0.01)
        let amber = CardOverlayCompositor.listeningDotColor(remaining: 59).components ?? []
        XCTAssertEqual(amber[0], 1, accuracy: 0.01)
        XCTAssertEqual(amber[2], 0, accuracy: 0.01)
    }

    func testListeningDotBurnsIntoFeed() throws {
        func isGreen(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { g > 200 && r < 100 && b < 100 }
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: nil, isVisible: false, commandWindowRemaining: 120))
        let listening = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertGreaterThan(
            coloredPixelCount(listening, xFraction: 0 ..< 0.25, where: isGreen), 20,
            "green dot must burn into the top-left while listening"
        )
        compositor.updateOverlay(ProgramOverlay(card: nil, isVisible: false, commandWindowRemaining: nil))
        let paused = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertEqual(coloredPixelCount(paused, xFraction: 0 ..< 1, where: isGreen), 0, "no dot while signing")
    }

    func testTitleOnlyCardGivesPictureFullHeight() throws {
        let card = PresentationCard(title: "Slide 2", message: "", imageData: makeTestImageData())
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .bottom))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        func isRed(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g < 100 && b < 100 }
        // Memory rows 0.70..<0.82 sit in the old empty message band, above
        // the old 52%-share picture top: red there proves the picture
        // expanded to fill the title-only card.
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.70 ..< 0.82, where: isRed), 500)
    }

    func testBottomCardSplitsSideBySide() throws {
        let banner = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .bottom)
        let layout = CardOverlayCompositor.contentLayout(
            banner: banner, margin: 51.2, messageTop: banner.maxY - 60, messageSize: 27,
            hasMessageText: true, hasImage: true, position: .bottom, expanded: false
        )
        let message = layout.messageRect
        let box = try XCTUnwrap(layout.pictureBox)
        XCTAssertLessThan(message.maxX, box.minX, "text left, picture right")
        XCTAssertEqual(message.height, box.height, accuracy: 0.01)
        XCTAssertGreaterThan(box.width, 140, "picture keeps usable width")
        XCTAssertTrue(banner.contains(message) && banner.contains(box))
    }

    func testBottomCardWithoutImageKeepsFullWidth() {
        let banner = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .bottom)
        let layout = CardOverlayCompositor.contentLayout(
            banner: banner, margin: 51.2, messageTop: banner.maxY - 60, messageSize: 27,
            hasMessageText: true, hasImage: false, position: .bottom, expanded: false
        )
        XCTAssertNil(layout.pictureBox)
        XCTAssertEqual(layout.messageRect.width, banner.width - 51.2 * 1.2, accuracy: 0.01)
    }

    func testSideCardStacksTextOverPicture() throws {
        let banner = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .left)
        let layout = CardOverlayCompositor.contentLayout(
            banner: banner, margin: 51.2, messageTop: banner.maxY - 60, messageSize: 27,
            hasMessageText: true, hasImage: true, position: .left, expanded: false
        )
        let box = try XCTUnwrap(layout.pictureBox)
        XCTAssertGreaterThan(layout.messageRect.minY, box.maxY, "message above picture")
        XCTAssertEqual(layout.messageRect.width, box.width, accuracy: 0.01)
    }

    func testBottomPanelSplitsSideBySide() throws {
        let banner = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .sideBySide, cardPanel: .bottom)
        let layout = CardOverlayCompositor.contentLayout(
            banner: banner, margin: 51.2, messageTop: banner.maxY - 60, messageSize: 27,
            hasMessageText: true, hasImage: true, position: .sideBySide, cardPanel: .bottom, expanded: false
        )
        let message = layout.messageRect
        let box = try XCTUnwrap(layout.pictureBox)
        XCTAssertLessThan(message.maxX, box.minX, "text left, picture right")
        XCTAssertEqual(message.height, box.height, accuracy: 0.01)
        XCTAssertTrue(banner.contains(message) && banner.contains(box))
    }

    func testMessageFitsDetectsOverflow() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 60)
        XCTAssertTrue(CardOverlayCompositor.messageFits("Short", size: 27, rect: rect))
        XCTAssertFalse(CardOverlayCompositor.messageFits(String(repeating: "Long text here. ", count: 40), size: 27, rect: rect))
        XCTAssertTrue(CardOverlayCompositor.messageFits("", size: 27, rect: rect))
    }

    func testTitleWrapsInsteadOfTruncating() {
        // Side-panel text width at 720p: 36% of 1280 minus margins.
        let banner = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .left)
        let maxWidth = banner.width - 51.2 * 1.2
        let title = "The quick brown fox jumps over the lazy dog near the river"
        let lines = CardOverlayCompositor.wrappedTitleLines(title, fontSize: 39.6, maxWidth: maxWidth)
        XCTAssertGreaterThan(lines.count, 1, "long title wraps on narrow panels")
        XCTAssertLessThanOrEqual(lines.count, 3)
        for line in lines {
            XCTAssertLessThanOrEqual(
                CardOverlayCompositor.titleLineWidth(line, fontSize: 39.6), maxWidth + 0.5,
                "each wrapped line fits: \(line)"
            )
        }
        let stripped = { (s: String) in s.replacingOccurrences(of: " ", with: "") }
        XCTAssertEqual(stripped(lines.joined()), stripped(title), "wrapping loses no text")
    }

    func testTitleTruncatesPastMaxLines() {
        let lines = CardOverlayCompositor.wrappedTitleLines(
            String(repeating: "Long title words ", count: 20), fontSize: 40, maxWidth: 300
        )
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.last?.hasSuffix("…") ?? false)
        XCTAssertEqual(CardOverlayCompositor.wrappedTitleLines("", fontSize: 40, maxWidth: 300), [])
        XCTAssertEqual(CardOverlayCompositor.wrappedTitleLines("Short", fontSize: 40, maxWidth: 300), ["Short"])
    }

    func testNumberBadgeFormatting() {
        XCTAssertEqual(CardOverlayCompositor.numberBadge(number: 3, total: 8), "3/8")
        XCTAssertNil(CardOverlayCompositor.numberBadge(number: nil, total: 8))
        XCTAssertNil(CardOverlayCompositor.numberBadge(number: 0, total: 8))
        XCTAssertNil(CardOverlayCompositor.numberBadge(number: 1, total: 0))
    }

    func testSideBySideTilesLayout() {
        let video = CardOverlayCompositor.videoRect(width: 1280, height: 720, position: .sideBySide)
        let card = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .sideBySide)
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        XCTAssertTrue(frame.contains(video) && frame.contains(card))
        XCTAssertFalse(video.intersects(card))
        XCTAssertLessThan(video.maxX, card.minX, "video left, card right")
        let fitted = CardOverlayCompositor.aspectFit(CGSize(width: 1280, height: 720), in: video)
        XCTAssertTrue(video.insetBy(dx: -1, dy: -1).contains(fitted), "whole frame fits inside the tile")
        for position in [CardOverlayPosition.bottom, .left, .right] {
            XCTAssertEqual(CardOverlayCompositor.videoRect(width: 1280, height: 720, position: position), frame)
        }
        XCTAssertEqual(
            CardOverlayCompositor.videoRect(width: 1280, height: 720, position: .sideBySide, expanded: true), frame,
            "expanded keeps fullscreen video under the card"
        )
    }

    func testCardPanelLeftMirrorsRight() {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let video = CardOverlayCompositor.videoRect(width: 1280, height: 720, position: .sideBySide, cardPanel: .left)
        let card = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .sideBySide, cardPanel: .left)
        let rightVideo = CardOverlayCompositor.videoRect(width: 1280, height: 720, position: .sideBySide, cardPanel: .right)
        XCTAssertTrue(frame.contains(video) && frame.contains(card))
        XCTAssertFalse(video.intersects(card))
        XCTAssertLessThan(card.maxX, video.minX, "card left, video right")
        XCTAssertEqual(video.width, rightVideo.width, accuracy: 0.01)
        XCTAssertEqual(video.maxX, 1280 - 1280 * 0.04, accuracy: 0.01)
        XCTAssertEqual(card.minX, 1280 * 0.04, accuracy: 0.01)
        let fitted = CardOverlayCompositor.aspectFit(CGSize(width: 1280, height: 720), in: video)
        XCTAssertTrue(video.insetBy(dx: -1, dy: -1).contains(fitted), "whole frame fits inside the tile")
    }

    func testCardPanelBottomSplitsHorizontally() {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let video = CardOverlayCompositor.videoRect(width: 1280, height: 720, position: .sideBySide, cardPanel: .bottom)
        let card = CardOverlayCompositor.cardRect(width: 1280, height: 720, position: .sideBySide, cardPanel: .bottom)
        XCTAssertTrue(frame.contains(video) && frame.contains(card))
        XCTAssertFalse(video.intersects(card))
        XCTAssertLessThan(card.maxY, video.minY, "card panel below, video on top")
        XCTAssertEqual(card.minX, 1280 * 0.04, accuracy: 0.01)
        XCTAssertEqual(card.maxX, 1280 - 1280 * 0.04, accuracy: 0.01)
        let fitted = CardOverlayCompositor.aspectFit(CGSize(width: 1280, height: 720), in: video)
        XCTAssertTrue(video.insetBy(dx: -1, dy: -1).contains(fitted), "whole frame fits inside the tile")
    }

    /// Camera frame with a bright left half and dark right half.
    private func twoToneFrame() -> CVPixelBuffer? {
        guard let buffer = makePixelBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let v: UInt8 = x < width / 2 ? 255 : 0
                row[x * 4 + 0] = v
                row[x * 4 + 1] = v
                row[x * 4 + 2] = v
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    func testSideBySideShowsWholeVideoBesideCard() throws {
        let card = PresentationCard(title: "Longer Title Here", message: "A longer body of text for glyph counting.")
        let frame = try XCTUnwrap(twoToneFrame())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .sideBySide))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let isBright: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r > 200 && g > 200 && b > 200 }
        let isDark: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r < 50 && g < 50 && b < 50 }
        // Video tile: bright content mid-left, letterbox bars top.
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.4 ..< 0.6, xFraction: 0.05 ..< 0.2, where: isBright), 200)
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.0 ..< 0.12, xFraction: 0.05 ..< 0.4, where: isDark), 500)
        // Card panel: text glyphs on the right.
        XCTAssertGreaterThan(brightPixelCount(output, xFraction: 0.6 ..< 1.0), 100)
    }

    func testSideBySideMirroredFlipsVideo() throws {
        let card = PresentationCard(title: "T", message: "M")
        let frame = try XCTUnwrap(twoToneFrame())
        let compositor = CardOverlayCompositor()
        compositor.setMirrored(true)
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .sideBySide))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let isBright: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r > 200 && g > 200 && b > 200 }
        let isDark: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r < 50 && g < 50 && b < 50 }
        // Mirrored: bright half moves to the tile's right side.
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.4 ..< 0.6, xFraction: 0.30 ..< 0.45, where: isBright), 200)
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.4 ..< 0.6, xFraction: 0.05 ..< 0.2, where: isDark), 1000)
    }

    func testSideBySideHiddenCardStaysFullscreen() throws {
        let card = PresentationCard(title: "T", message: "M")
        let frame = try XCTUnwrap(twoToneFrame())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: false, position: .sideBySide))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        // Fullscreen passthrough: bright across the full height, no bars.
        let topLeft = coloredPixelCount(output, yFraction: 0.0 ..< 0.15, xFraction: 0.05 ..< 0.4) { r, g, b in
            r > 200 && g > 200 && b > 200
        }
        XCTAssertGreaterThan(topLeft, 1000)
    }

    func testCardPanelLeftShowsVideoBesideCard() throws {
        let card = PresentationCard(title: "Longer Title Here", message: "A longer body of text for glyph counting.")
        let frame = try XCTUnwrap(twoToneFrame())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .sideBySide, cardPanel: .left))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let isBright: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r > 200 && g > 200 && b > 200 }
        // Mirrored layout: card glyphs left, video content right.
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.4 ..< 0.6, xFraction: 0.5 ..< 0.65, where: isBright), 200)
        XCTAssertGreaterThan(brightPixelCount(output, xFraction: 0.0 ..< 0.4), 100)
    }

    func testCardPanelBottomShowsCardBelowVideo() throws {
        let card = PresentationCard(title: "Longer Title Here", message: "A longer body of text for glyph counting.")
        let frame = try XCTUnwrap(twoToneFrame())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .sideBySide, cardPanel: .bottom))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let isBright: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in r > 200 && g > 200 && b > 200 }
        // Video on top (bright camera-left inside the fitted tile).
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.1 ..< 0.4, xFraction: 0.32 ..< 0.48, where: isBright), 200)
        // Card glyphs across the bottom panel.
        XCTAssertGreaterThan(coloredPixelCount(output, yFraction: 0.55 ..< 0.9, xFraction: 0.0 ..< 1.0, where: isBright), 100)
    }

    func testCardNumberBadgeBurnsGlyphs() throws {
        let card = PresentationCard(title: "T", message: "M")
        func brightCount(number: Int?) throws -> Int {
            let frame = try XCTUnwrap(makePixelBuffer())
            let compositor = CardOverlayCompositor()
            compositor.updateOverlay(ProgramOverlay(
                card: card, isVisible: true, position: .bottom, cardNumber: number, cardCount: 8
            ))
            let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
            return brightPixelCount(output, xFraction: 0 ..< 1)
        }
        XCTAssertGreaterThan(
            try brightCount(number: 3), try brightCount(number: nil),
            "the badge adds glyphs to the frame"
        )
    }

    func testLongTitleRendersOnSidePanels() throws {
        let card = PresentationCard(
            title: "The quick brown fox jumps over the lazy dog near the river",
            message: "Body stays below the wrapped title."
        )
        // Full-height scan: side-panel titles sit at the top of the frame,
        // outside the bottom-strip helper's region.
        for position in [CardOverlayPosition.left, CardOverlayPosition.right] {
            let frame = try XCTUnwrap(makePixelBuffer())
            let compositor = CardOverlayCompositor()
            compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: position))
            let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
            XCTAssertGreaterThan(
                brightPixelCount(output, xFraction: 0 ..< 1), 100,
                "wrapped title glyphs at \(position)"
            )
        }
    }

    /// Busy photo-like image: deterministic high-frequency noise, a
    /// stand-in for real illustrations over which paint must stay legible.
    /// Mid-tone (100-220, mean ~160) so the red brush (luminance ~128)
    /// deterministically earns a WHITE halo (line darker than bg).
    private func makeBusyImageData() -> Data? {
        let width = 96, height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        // Deterministic LCG noise so dumps and tests are reproducible.
        var state: UInt64 = 0x1234_5678_9ABC_DEF1
        func nextByte() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(100 + Int((state >> 33) % 121)) / 255
        }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let v = nextByte()
                ctx.setFillColor(CGColor(red: v, green: nextByte(), blue: nextByte(), alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Flat white image: the worst case for the yellow brush (line
    /// luminance ~209 vs white 255), standing in for white diagram cards.
    private func makeWhiteImageData() -> Data? {
        let width = 96, height = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Mean red-channel value over a memory-row span and x-fraction span.
    private func meanRed(_ buffer: CVPixelBuffer, rows: Range<Int>, xFraction: Range<Double>) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = Int(Double(width) * xFraction.lowerBound)
        let x1 = Int(Double(width) * xFraction.upperBound)
        var sum = 0, n = 0
        for y in rows {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: x0, to: x1, by: 2) {
                sum += Int(row[x * 4 + 2]); n += 1
            }
        }
        return Double(sum) / Double(max(n, 1))
    }

    /// Mean luminance difference (baseline minus painted) over a
    /// memory-row span and x-fraction span. Positive = paint darkened it.
    private func meanLuminanceDrop(painted: CVPixelBuffer, baseline: CVPixelBuffer, rows: Range<Int>, xFraction: Range<Double>) -> Double {
        CVPixelBufferLockBaseAddress(painted, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(painted, .readOnly) }
        CVPixelBufferLockBaseAddress(baseline, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(baseline, .readOnly) }
        guard let pb = CVPixelBufferGetBaseAddress(painted), let bb = CVPixelBufferGetBaseAddress(baseline) else { return 0 }
        let width = CVPixelBufferGetWidth(painted)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(painted)
        let x0 = Int(Double(width) * xFraction.lowerBound)
        let x1 = Int(Double(width) * xFraction.upperBound)
        func lum(_ row: UnsafeMutablePointer<UInt8>, _ x: Int) -> Double {
            0.299 * Double(row[x * 4 + 2]) + 0.587 * Double(row[x * 4 + 1]) + 0.114 * Double(row[x * 4])
        }
        var sum = 0.0, n = 0
        for y in rows {
            let pr = pb.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let br = bb.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: x0, to: x1, by: 2) {
                sum += lum(br, x) - lum(pr, x); n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    /// Red-channel standard deviation: proves the photo actually renders
    /// (flat card background would read near zero), so the halo tests
    /// below cannot pass vacuously on a missing picture.
    private func redStdev(_ buffer: CVPixelBuffer, rows: Range<Int>, xFraction: Range<Double>) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = Int(Double(width) * xFraction.lowerBound)
        let x1 = Int(Double(width) * xFraction.upperBound)
        var values: [Double] = []
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 3) {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: x0, to: x1, by: 5) {
                values.append(Double(row[x * 4 + 2]))
            }
        }
        guard !values.isEmpty else { return -1 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    }

    /// Mean blue-channel value over a memory-row span and x-fraction span.
    private func meanBlue(_ buffer: CVPixelBuffer, rows: Range<Int>, xFraction: Range<Double>) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = Int(Double(width) * xFraction.lowerBound)
        let x1 = Int(Double(width) * xFraction.upperBound)
        var sum = 0, n = 0
        for y in rows {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: x0, to: x1, by: 2) {
                sum += Int(row[x * 4]); n += 1
            }
        }
        return Double(sum) / Double(max(n, 1))
    }

    /// Mean red-excess (r minus mean(g, b)) over a span: the chroma
    /// signal of the red brush, which reads even on white (where raw
    /// red gain is zero).
    private func meanRedExcess(_ buffer: CVPixelBuffer, rows: Range<Int>, xFraction: Range<Double>) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let x0 = Int(Double(width) * xFraction.lowerBound)
        let x1 = Int(Double(width) * xFraction.upperBound)
        var sum = 0.0, n = 0
        for y in rows {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: x0, to: x1, by: 2) {
                sum += Double(row[x * 4 + 2]) - (Double(row[x * 4 + 1]) + Double(row[x * 4])) / 2
                n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    /// Renders the 720p bottom card (message + image, side-by-side) with
    /// and without one horizontal brush stroke at normalized y 0.2.
    private func renderBrushOverCard(imageData: Data?, color: HighlightColor, endedAt: Date?, xSpan: Range<Double> = 0.1 ..< 0.9) throws -> (painted: CVPixelBuffer, baseline: CVPixelBuffer) {
        let card = PresentationCard(title: "Title here", message: "Some message text here", imageData: imageData)
        func render(layer: PaintLayer) throws -> CVPixelBuffer {
            let frame = try XCTUnwrap(makePixelBuffer(width: 1280, height: 720))
            let compositor = CardOverlayCompositor()
            compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .bottom))
            compositor.updatePaint(layer)
            return try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        }
        let brush = BrushStroke(
            stroke: PaintStroke(color: color, points: [CGPoint(x: xSpan.lowerBound, y: 0.2), CGPoint(x: xSpan.upperBound, y: 0.2)]),
            endedAt: endedAt, fadeDuration: 1.5
        )
        let painted = try render(layer: PaintLayer(brushStrokes: [brush], pointer: nil))
        let baseline = try render(layer: PaintLayer(brushStrokes: [], pointer: nil))
        return (painted, baseline)
    }

    /// Mean tunnel change beside the stroke centerline (rows ±3-6: inside
    /// the halo, outside the color). Positive = darkened, negative =
    /// lightened, near zero = no halo.
    private func tunnelChange(painted: CVPixelBuffer, baseline: CVPixelBuffer, strokeRow: Int, xFraction: Range<Double>) -> Double {
        (meanLuminanceDrop(painted: painted, baseline: baseline, rows: strokeRow + 3 ..< strokeRow + 6, xFraction: xFraction)
            + meanLuminanceDrop(painted: painted, baseline: baseline, rows: strokeRow - 6 ..< strokeRow - 3, xFraction: xFraction)) / 2
    }

    /// Red brush (luminance ~128) on the mid-tone photo (~160) earns a
    /// WHITE halo (line darker than bg): the tunnel must read lighter
    /// than baseline while the red line stays strong.
    func testRedBrushWhiteHalosOnMidTonePhoto() throws {
        let strokeRow = Int((1 - 0.2) * 720)
        let photoX = 0.7 ..< 0.85
        let (painted, baseline) = try renderBrushOverCard(imageData: makeBusyImageData(), color: .red, endedAt: nil)
        XCTAssertGreaterThan(redStdev(baseline, rows: strokeRow - 10 ..< strokeRow + 10, xFraction: photoX), 10,
                              "photo must render in the sampled region")
        XCTAssertLessThan(tunnelChange(painted: painted, baseline: baseline, strokeRow: strokeRow, xFraction: photoX), -20,
                           "white halo must lighten the photo beside the stroke")
        let lineRed = meanRed(painted, rows: strokeRow - 1 ..< strokeRow + 1, xFraction: photoX)
            - meanRed(baseline, rows: strokeRow - 1 ..< strokeRow + 1, xFraction: photoX)
        XCTAssertGreaterThan(lineRed, 60, "color line must stay strongly red over the photo")
    }

    /// Yellow brush (luminance ~209) on a white diagram card earns a DARK
    /// halo: the tunnel must read darker while the yellow line (blue
    /// deficit) stays strong.
    func testYellowBrushDarkHalosOnWhiteCard() throws {
        let strokeRow = Int((1 - 0.2) * 720)
        let photoX = 0.7 ..< 0.85
        let (painted, baseline) = try renderBrushOverCard(imageData: makeWhiteImageData(), color: .yellow, endedAt: nil)
        XCTAssertGreaterThan(tunnelChange(painted: painted, baseline: baseline, strokeRow: strokeRow, xFraction: photoX), 30,
                              "dark halo must darken the white card beside the stroke")
        let blueDrop = meanBlue(baseline, rows: strokeRow - 1 ..< strokeRow + 1, xFraction: photoX)
            - meanBlue(painted, rows: strokeRow - 1 ..< strokeRow + 1, xFraction: photoX)
        XCTAssertGreaterThan(blueDrop, 80, "yellow line must keep its blue deficit on white")
    }

    /// Red brush on white already contrasts (gap 127): no halo, clean
    /// tunnel, strong red-excess line.
    func testRedBrushSkipsHaloOnWhiteCard() throws {
        let strokeRow = Int((1 - 0.2) * 720)
        let photoX = 0.7 ..< 0.85
        let (painted, baseline) = try renderBrushOverCard(imageData: makeWhiteImageData(), color: .red, endedAt: nil)
        XCTAssertLessThan(abs(tunnelChange(painted: painted, baseline: baseline, strokeRow: strokeRow, xFraction: photoX)), 8,
                           "no halo when the line already contrasts")
        let excess = meanRedExcess(painted, rows: strokeRow - 1 ..< strokeRow + 1, xFraction: photoX)
            - meanRedExcess(baseline, rows: strokeRow - 1 ..< strokeRow + 1, xFraction: photoX)
        XCTAssertGreaterThan(excess, 60, "red line must stay strong on white")
    }

    /// Yellow brush confined to the dark text band (gap 170+): no halo.
    func testYellowBrushSkipsHaloOnDarkText() throws {
        let strokeRow = Int((1 - 0.2) * 720)
        let textX = 0.15 ..< 0.4
        let (painted, baseline) = try renderBrushOverCard(imageData: makeBusyImageData(), color: .yellow, endedAt: nil, xSpan: 0.15 ..< 0.4)
        XCTAssertLessThan(abs(tunnelChange(painted: painted, baseline: baseline, strokeRow: strokeRow, xFraction: textX)), 8,
                           "no halo when the line already contrasts")
    }

    /// The halo lingers into the fade: halfway through (alpha ~0.5)
    /// the yellow-on-white tunnel must still read near full strength
    /// (a same-curve halo would already be half gone).
    func testYellowHaloLingersIntoFadeOnWhite() throws {
        let strokeRow = Int((1 - 0.2) * 720)
        let photoX = 0.7 ..< 0.85
        let (painted, baseline) = try renderBrushOverCard(
            imageData: makeWhiteImageData(), color: .yellow,
            endedAt: Date().addingTimeInterval(-0.75)
        )
        XCTAssertGreaterThan(tunnelChange(painted: painted, baseline: baseline, strokeRow: strokeRow, xFraction: photoX), 80,
                              "halo must still separate the fading line from white")
    }

    /// Committed annotation strokes (full alpha) paint no halo: pixels
    /// beside the line must match the card-only baseline.
    func testCommittedStrokeHasNoHalo() throws {
        let strokeRow = Int((1 - 0.2) * 720)
        let photoX = 0.7 ..< 0.85
        let card = PresentationCard(title: "Title here", message: "Some message text here", imageData: makeBusyImageData())
        func render(layer: PaintLayer) throws -> CVPixelBuffer {
            let frame = try XCTUnwrap(makePixelBuffer(width: 1280, height: 720))
            let compositor = CardOverlayCompositor()
            compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .bottom))
            compositor.updatePaint(layer)
            return try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        }
        let stroke = PaintStroke(color: .red, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.2)])
        let painted = try render(layer: PaintLayer(strokes: [stroke], pointer: nil))
        let baseline = try render(layer: PaintLayer(strokes: [], pointer: nil))
        XCTAssertLessThan(tunnelChange(painted: painted, baseline: baseline, strokeRow: strokeRow, xFraction: photoX), 6,
                           "committed strokes must not darken beside the line")
    }

    func testZoomedPictureCoversMorePixels() throws {
        let card = PresentationCard(title: "Slide 2", message: "", imageData: makeTestImageData())
        func render(zoom: CGFloat) throws -> CVPixelBuffer {
            let frame = try XCTUnwrap(makePixelBuffer())
            let compositor = CardOverlayCompositor()
            compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true, position: .bottom, zoomScale: zoom))
            return try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        }
        func isPicture(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
            (r > 200 && g < 100 && b < 100) || (b > 200 && r < 100 && g < 100)
        }
        let fit = coloredPixelCount(try render(zoom: 1.0), where: isPicture)
        let zoomed = coloredPixelCount(try render(zoom: 2.0), where: isPicture)
        XCTAssertGreaterThan(fit, 0, "sanity: unzoomed picture renders")
        XCTAssertGreaterThan(zoomed, fit, "zoomed picture must cover more pixels")
    }

    // MARK: - Output settings

    func testMirrorModeResolve() {
        XCTAssertTrue(OutputMirrorMode.resolve(mode: .auto, cameraMirrored: true))
        XCTAssertFalse(OutputMirrorMode.resolve(mode: .auto, cameraMirrored: false))
        XCTAssertTrue(OutputMirrorMode.resolve(mode: .mirrored, cameraMirrored: false))
        XCTAssertFalse(OutputMirrorMode.resolve(mode: .original, cameraMirrored: true))
    }

    func testCaptureResolutionPresets() {
        XCTAssertEqual(CaptureResolution.hd720.sessionPreset, .hd1280x720)
        XCTAssertEqual(CaptureResolution.hd1080.sessionPreset, .hd1920x1080)
        XCTAssertEqual(CaptureResolution.hd720.displayName, "720p")
        XCTAssertEqual(CaptureResolution.hd1080.displayName, "1080p")
    }

    func testPaintStrokeRendersInCardColor() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: true))
        let stroke = PaintStroke(color: .red, points: [
            CGPoint(x: 0.1, y: 0.15), CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.9, y: 0.15),
        ])
        compositor.updatePaint(PaintLayer(strokes: [stroke], pointer: nil))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let red = coloredPixelCount(output) { r, g, b in r > 200 && g < 150 && b < 150 }
        XCTAssertGreaterThan(red, 100, "stroke must render in red")
    }

    func testPaintStrokesClippedToCard() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: true))
        let stroke = PaintStroke(color: .red, points: [
            CGPoint(x: 0.5, y: 0.0), CGPoint(x: 0.5, y: 1.0),
        ])
        compositor.updatePaint(PaintLayer(strokes: [stroke], pointer: nil))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let aboveCard = coloredPixelCount(output, yFraction: 0 ..< 0.4) { r, g, b in r > 200 && g < 150 && b < 150 }
        XCTAssertEqual(aboveCard, 0, "no stroke pixels above the card")
    }

    func testCardPictureOrientation() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        var card = PresentationCard(title: "", message: "")
        card.imageData = try XCTUnwrap(makeTestImageData())
        compositor.updateOverlay(ProgramOverlay(card: card, isVisible: true))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let redRows = coloredRows(output) { r, g, b in r > 200 && g < 120 && b < 120 }
        let blueRows = coloredRows(output) { r, g, b in b > 200 && r < 120 && g < 120 }
        XCTAssertGreaterThan(redRows.count, 5, "red top half must render")
        XCTAssertGreaterThan(blueRows.count, 5, "blue bottom half must render")
        XCTAssertLessThan(
            redRows.min() ?? Int.max, blueRows.min() ?? Int.min,
            "red must sit above blue (memory rows grow downward)"
        )
    }

    func testCardWithoutPictureHasNoPicturePixels() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard(title: "", message: ""), isVisible: true))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertEqual(coloredPixelCount(output) { r, g, b in r > 200 && g < 120 && b < 120 }, 0)
        XCTAssertEqual(coloredPixelCount(output) { r, g, b in b > 200 && r < 120 && g < 120 }, 0)
    }

    func testPointerRendersWhileStrokesHideWithCard() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[0], isVisible: false))
        let stroke = PaintStroke(color: .red, points: [CGPoint(x: 0.5, y: 0.2)])
        compositor.updatePaint(PaintLayer(strokes: [stroke], pointer: CGPoint(x: 0.5, y: 0.5)))
        let output = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        let yellow = coloredPixelCount(output) { r, g, b in r > 200 && g > 150 && b < 120 }
        XCTAssertGreaterThan(yellow, 10, "pointer renders while aiming")
        let red = coloredPixelCount(output) { r, g, b in r > 200 && g < 150 && b < 150 }
        XCTAssertEqual(red, 0, "strokes hide with the card")
    }

    func testTwoPipelinesShareOneCompositor() throws {
        let compositor = CardOverlayCompositor()
        let first = StubVideoOutput()
        let second = StubVideoOutput()
        let monitor = ProgramOutputPipeline(compositor: compositor, output: first)
        let expanded = ProgramOutputPipeline(compositor: compositor, output: second)
        let sample = try XCTUnwrap(makeSampleBuffer(pixelBuffer: try XCTUnwrap(makePixelBuffer())))
        monitor.consume(sample)
        expanded.consume(sample)
        XCTAssertEqual(first.frames.count, 1, "monitor branch receives the frame")
        XCTAssertEqual(second.frames.count, 1, "expanded branch receives the frame")
    }

    func testVisibleWithoutCardEqualsHidden() throws {
        let frame = try XCTUnwrap(makePixelBuffer())
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: nil, isVisible: false))
        let hidden = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        compositor.updateOverlay(ProgramOverlay(card: nil, isVisible: true))
        let noCard = try XCTUnwrap(compositor.composite(cameraFrame: frame, presentationTimeStamp: .zero))
        XCTAssertEqual(bufferBytes(hidden), bufferBytes(noCard))
    }

    func testPoolAdaptsToFrameSize() throws {
        let compositor = CardOverlayCompositor()
        let big = try XCTUnwrap(compositor.composite(
            cameraFrame: try XCTUnwrap(makePixelBuffer(width: 640, height: 360)), presentationTimeStamp: .zero
        ))
        XCTAssertEqual(CVPixelBufferGetWidth(big), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(big), 360)
        let small = try XCTUnwrap(compositor.composite(
            cameraFrame: try XCTUnwrap(makePixelBuffer(width: 320, height: 240)), presentationTimeStamp: .zero
        ))
        XCTAssertEqual(CVPixelBufferGetWidth(small), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(small), 240)
    }

    // MARK: - Program pipeline

    func testPipelinePublishesWhenEnabled() throws {
        let output = StubVideoOutput()
        let pipeline = ProgramOutputPipeline(compositor: CardOverlayCompositor(), output: output)
        let sample = try XCTUnwrap(makeSampleBuffer(pixelBuffer: try XCTUnwrap(makePixelBuffer())))
        pipeline.consume(sample)
        XCTAssertEqual(output.frames.count, 1)
        XCTAssertEqual(output.frames.first?.width, 640)
        XCTAssertEqual(output.frames.first?.height, 360)
    }

    func testPipelinePublishesWithOverlay() throws {
        let output = StubVideoOutput()
        let compositor = CardOverlayCompositor()
        compositor.updateOverlay(ProgramOverlay(card: PresentationCard.samples[1], isVisible: true))
        let pipeline = ProgramOutputPipeline(compositor: compositor, output: output)
        let sample = try XCTUnwrap(makeSampleBuffer(pixelBuffer: try XCTUnwrap(makePixelBuffer())))
        pipeline.consume(sample)
        XCTAssertEqual(output.frames.count, 1)
    }

    func testPipelineDropsWhenDisabled() throws {
        let output = StubVideoOutput()
        let pipeline = ProgramOutputPipeline(compositor: CardOverlayCompositor(), output: output, enabled: false)
        let sample = try XCTUnwrap(makeSampleBuffer(pixelBuffer: try XCTUnwrap(makePixelBuffer())))
        pipeline.consume(sample)
        XCTAssertTrue(output.frames.isEmpty)
        pipeline.setEnabled(true)
        pipeline.consume(sample)
        XCTAssertEqual(output.frames.count, 1)
    }

    // MARK: - Detector smoke test (real Vision, synthetic frame, no hand)

    func testDetectorReportsUnknownOnBlankFrame() async throws {
        let sample = try XCTUnwrap(makeSampleBuffer(pixelBuffer: try XCTUnwrap(makePixelBuffer())))
        let detector = HandGestureDetector()
        detector.consume(sample)
        let snapshot = await detector.snapshots.first { _ in true }
        XCTAssertEqual(snapshot?.candidate, .unknown)
        XCTAssertEqual(snapshot?.landmarks, [])
    }
}

private final class StubVideoOutput: VideoOutputService, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: [(width: Int, height: Int)] = []
    private var storedRunning = false

    var frames: [(width: Int, height: Int)] { lock.withLock { storedFrames } }
    var isRunning: Bool { lock.withLock { storedRunning } }

    func start() { lock.withLock { storedRunning = true } }
    func stop() { lock.withLock { storedRunning = false } }

    func publish(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp _: CMTime) {
        lock.withLock {
            storedFrames.append((CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        }
    }
}

final class VideoRecorderTests: XCTestCase {
    private func makeBuffer(width: Int = 640, height: Int = 360, gray: UInt8 = 128) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4] = gray
                row[x * 4 + 1] = gray
                row[x * 4 + 2] = gray
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("mp4")
    }

    func testRecordsFramesToMP4() throws {
        let recorder = VideoRecorder()
        let url = tempURL()
        try recorder.start(url: url)
        let frame = try XCTUnwrap(makeBuffer())
        for i in 0..<30 {
            recorder.append(frame, presentationTimeStamp: CMTime(value: Int64(i), timescale: 30))
            Thread.sleep(forTimeInterval: 0.01)
        }
        let done = expectation(description: "finish")
        var result: VideoRecorder.FinishResult?
        recorder.onFinish = { result = $0; done.fulfill() }
        recorder.stop()
        wait(for: [done], timeout: 15)
        guard case let .saved(savedURL, droppedFrames) = result else {
            return XCTFail("expected saved, got \(String(describing: result))")
        }
        XCTAssertEqual(savedURL, url)
        XCTAssertLessThanOrEqual(droppedFrames, 5)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)
        try? FileManager.default.removeItem(at: url)
    }

    func testStopWithoutFramesCancels() throws {
        let recorder = VideoRecorder()
        let url = tempURL()
        try recorder.start(url: url)
        let done = expectation(description: "finish")
        var result: VideoRecorder.FinishResult?
        recorder.onFinish = { result = $0; done.fulfill() }
        recorder.stop()
        wait(for: [done], timeout: 5)
        guard case .cancelled = result else {
            return XCTFail("expected cancelled, got \(String(describing: result))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDoubleStartThrows() throws {
        let recorder = VideoRecorder()
        try recorder.start(url: tempURL())
        XCTAssertThrowsError(try recorder.start(url: tempURL()))
        recorder.stop()
    }

    func testMismatchedFramesDropped() throws {
        let recorder = VideoRecorder()
        let url = tempURL()
        try recorder.start(url: url)
        let frame = try XCTUnwrap(makeBuffer())
        let small = try XCTUnwrap(makeBuffer(width: 320, height: 180))
        for i in 0..<10 {
            recorder.append(frame, presentationTimeStamp: CMTime(value: Int64(i), timescale: 30))
        }
        for i in 10..<15 {
            recorder.append(small, presentationTimeStamp: CMTime(value: Int64(i), timescale: 30))
        }
        let done = expectation(description: "finish")
        var result: VideoRecorder.FinishResult?
        recorder.onFinish = { result = $0; done.fulfill() }
        recorder.stop()
        wait(for: [done], timeout: 15)
        guard case let .saved(_, droppedFrames) = result else {
            return XCTFail("expected saved, got \(String(describing: result))")
        }
        XCTAssertGreaterThanOrEqual(droppedFrames, 5)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Virtual Camera Service

final class MockSinkTransport: VirtualCameraSinkTransport, @unchecked Sendable {
    var connectResult = true
    var sendResult = true
    private let lock = NSLock()
    private var connected = false
    private var buffers: [CVPixelBuffer] = []

    var isConnected: Bool { lock.withLock { connected } }
    var sentCount: Int { lock.withLock { buffers.count } }
    var lastSentSize: (Int, Int)? {
        lock.withLock { buffers.last.map { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) } }
    }

    func connect() -> Bool {
        lock.withLock { connected = connectResult }
        return connectResult
    }

    func disconnect() { lock.withLock { connected = false } }

    func send(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard sendResult else { return false }
        lock.withLock { buffers.append(pixelBuffer) }
        return true
    }
}

final class VirtualCameraServiceTests: XCTestCase {
    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return buffer!
    }

    private func publish(to service: VirtualCameraService, width: Int, height: Int) {
        service.publish(makeBuffer(width: width, height: height), presentationTimeStamp: .zero)
    }

    func testPublishBeforeStartSendsNothing() {
        let transport = MockSinkTransport()
        let service = VirtualCameraService(transport: transport)
        publish(to: service, width: 1280, height: 720)
        XCTAssertEqual(transport.sentCount, 0)
    }

    func testFailedConnectSendsNothing() {
        let transport = MockSinkTransport()
        transport.connectResult = false
        let service = VirtualCameraService(transport: transport)
        service.start()
        publish(to: service, width: 1280, height: 720)
        XCTAssertEqual(transport.sentCount, 0)
    }

    func test720pFramePassesThroughUnchanged() {
        let transport = MockSinkTransport()
        let service = VirtualCameraService(transport: transport)
        service.start()
        publish(to: service, width: 1280, height: 720)
        XCTAssertEqual(transport.sentCount, 1)
        XCTAssertEqual(transport.lastSentSize?.0, 1280)
        XCTAssertEqual(transport.lastSentSize?.1, 720)
    }

    func test1080pFrameScalesTo720p() {
        let transport = MockSinkTransport()
        let service = VirtualCameraService(transport: transport)
        service.start()
        publish(to: service, width: 1920, height: 1080)
        XCTAssertEqual(transport.sentCount, 1)
        XCTAssertEqual(transport.lastSentSize?.0, 1280)
        XCTAssertEqual(transport.lastSentSize?.1, 720)
    }

    func testScalerReturns720pInputIdentical() {
        let scaler = VirtualCameraFrameScaler()
        let buffer = makeBuffer(width: 1280, height: 720)
        XCTAssertTrue(scaler.scaleToCameraSize(buffer) === buffer)
    }

    /// 1080p source with marker bands along the displayed top and right edges.
    /// Memory row 0 is the displayed top; bands survive only when the full
    /// frame is scaled (a bottom-left crop drops both, cutting card titles).
    private func makeEdgeMarkedBuffer(width: Int, height: Int) -> CVPixelBuffer {
        let buffer = makeBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let v: UInt8 = (y < height / 6 || x >= width * 5 / 6) ? 255 : 0
                row[x * 4] = v
                row[x * 4 + 1] = v
                row[x * 4 + 2] = v
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }

    private func isBrightPixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        return row[x * 4] > 200 && row[x * 4 + 1] > 200 && row[x * 4 + 2] > 200
    }

    func test1080pScalePreservesFullFrame() throws {
        let scaler = VirtualCameraFrameScaler()
        let source = makeEdgeMarkedBuffer(width: 1920, height: 1080)
        let scaled = try XCTUnwrap(scaler.scaleToCameraSize(source))
        XCTAssertEqual(CVPixelBufferGetWidth(scaled), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(scaled), 720)
        XCTAssertTrue(isBrightPixel(scaled, x: 640, y: 30), "top edge must survive scaling")
        XCTAssertTrue(isBrightPixel(scaled, x: 1250, y: 360), "right edge must survive scaling")
        XCTAssertFalse(isBrightPixel(scaled, x: 640, y: 360), "center must stay dark")
    }

    func testIsSinkConnectedTracksTransport() {
        let transport = MockSinkTransport()
        let service = VirtualCameraService(transport: transport)
        XCTAssertFalse(service.isSinkConnected)
        service.start()
        XCTAssertTrue(service.isSinkConnected)
        service.stop()
        XCTAssertFalse(service.isSinkConnected)
    }

    func testIsSinkConnectedFalseWhenConnectFails() {
        let transport = MockSinkTransport()
        transport.connectResult = false
        let service = VirtualCameraService(transport: transport)
        service.start()
        XCTAssertFalse(service.isSinkConnected)
    }

    func testStopDisconnectsAndDrops() {
        let transport = MockSinkTransport()
        let service = VirtualCameraService(transport: transport)
        service.start()
        publish(to: service, width: 1280, height: 720)
        XCTAssertEqual(transport.sentCount, 1)
        service.stop()
        XCTAssertFalse(transport.isConnected)
        publish(to: service, width: 1280, height: 720)
        XCTAssertEqual(transport.sentCount, 1)
    }
}

// MARK: - Capture Resolution

final class CaptureResolutionTests: XCTestCase {
    /// 1080p default: wider sensor window on high-resolution cameras keeps
    /// signing hands in frame; downscales cleanly to the 720p outputs.
    func testDefaultResolutionIs1080p() {
        XCTAssertEqual(CaptureResolution.defaultResolution, .hd1080)
    }

    func testSessionPresetsAre169() {
        XCTAssertEqual(CaptureResolution.hd720.sessionPreset, .hd1280x720)
        XCTAssertEqual(CaptureResolution.hd1080.sessionPreset, .hd1920x1080)
    }

    func testPixelSizesMatchPresets() {
        XCTAssertEqual(CaptureResolution.hd720.pixelSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(CaptureResolution.hd1080.pixelSize, CGSize(width: 1920, height: 1080))
    }
}

final class MouseBrushMappingTests: XCTestCase {
    private let video = CGSize(width: 1280, height: 720)

    func testCenterMapsToCenterUnmirrored() {
        let p = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 160, y: 90), viewSize: CGSize(width: 320, height: 180),
            videoSize: video, mirrored: false
        )
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
    }

    func testCornersMapToCornersUnmirrored() {
        let view = CGSize(width: 320, height: 180)
        let bottomLeft = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 0, y: 0), viewSize: view, videoSize: video, mirrored: false
        )
        XCTAssertEqual(bottomLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(bottomLeft.y, 0, accuracy: 1e-9)
        let topRight = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 320, y: 180), viewSize: view, videoSize: video, mirrored: false
        )
        XCTAssertEqual(topRight.x, 1, accuracy: 1e-9)
        XCTAssertEqual(topRight.y, 1, accuracy: 1e-9)
    }

    func testMirroredFlipsXOnly() {
        let view = CGSize(width: 320, height: 180)
        let left = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 0, y: 90), viewSize: view, videoSize: video, mirrored: true
        )
        XCTAssertEqual(left.x, 1, accuracy: 1e-9)
        XCTAssertEqual(left.y, 0.5, accuracy: 1e-9)
        let right = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 320, y: 90), viewSize: view, videoSize: video, mirrored: true
        )
        XCTAssertEqual(right.x, 0, accuracy: 1e-9)
    }

    func testAspectFillCropOffsetsIntoVideo() {
        // Square view on 16:9 video: sides crop. Scale = 200/180, shown
        // width 355.56, crop 77.78/side: left edge reads x = 0.21875.
        let p = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 0, y: 100), viewSize: CGSize(width: 200, height: 200),
            videoSize: video, mirrored: false
        )
        XCTAssertEqual(p.x, 0.21875, accuracy: 1e-6)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
        let center = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 100, y: 100), viewSize: CGSize(width: 200, height: 200),
            videoSize: video, mirrored: false
        )
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
    }

    func testDragsOutsideClampOntoFrame() {
        let view = CGSize(width: 320, height: 180)
        let farLeft = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: -1000, y: 90), viewSize: view, videoSize: video, mirrored: false
        )
        XCTAssertEqual(farLeft.x, 0, accuracy: 1e-9)
        let farTop = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 160, y: 1180), viewSize: view, videoSize: video, mirrored: false
        )
        XCTAssertEqual(farTop.y, 1, accuracy: 1e-9)
    }

    func testDegenerateSizesFallBackToCenter() {
        let p = MouseBrushMonitorView.normalizedPaintPoint(
            viewPoint: CGPoint(x: 10, y: 10), viewSize: CGSize.zero,
            videoSize: video, mirrored: false
        )
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
    }
}

final class BrushFadeTests: XCTestCase {
    private let end = Date(timeIntervalSinceReferenceDate: 2000)

    func testLiveStrokeIsFullyOpaque() {
        XCTAssertEqual(CardOverlayCompositor.brushAlpha(endedAt: nil, at: end, fadeDuration: 1.5), 1)
    }

    func testFadeCurveIsLinear() {
        XCTAssertEqual(CardOverlayCompositor.brushAlpha(endedAt: end, at: end, fadeDuration: 1.5), 1)
        XCTAssertEqual(
            CardOverlayCompositor.brushAlpha(endedAt: end, at: end.addingTimeInterval(0.75), fadeDuration: 1.5),
            0.5, accuracy: 0.001
        )
        XCTAssertEqual(
            CardOverlayCompositor.brushAlpha(endedAt: end, at: end.addingTimeInterval(1.5), fadeDuration: 1.5),
            0, accuracy: 0.001
        )
    }

    func testExpiredStrokeStaysGone() {
        XCTAssertEqual(
            CardOverlayCompositor.brushAlpha(endedAt: end, at: end.addingTimeInterval(99), fadeDuration: 1.5), 0
        )
    }

    func testZeroFadeHidesImmediately() {
        XCTAssertEqual(CardOverlayCompositor.brushAlpha(endedAt: end, at: end, fadeDuration: 0), 0)
    }
}

import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO

/// Composites the live camera frame with the current card overlay (a lower-third
/// banner) into pooled BGRA pixel buffers at the camera's native size (720p).
/// Pure CoreImage/CoreGraphics, no Metal code, safe to call from the video queue.
final class CardOverlayCompositor: VideoCompositor, @unchecked Sendable {
    private let lock = NSLock()
    private var overlay = ProgramOverlay(card: nil, isVisible: false)
    private var overlayImage: CGImage?
    private var paint = PaintLayer()
    private var mirrored = false
    private let context = CIContext()
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int32, height: Int32)?

    func updateOverlay(_ overlay: ProgramOverlay) {
        lock.withLock {
            self.overlay = overlay
            // Decode once per overlay change (never per frame).
            overlayImage = overlay.card?.imageData.flatMap { Self.thumbnail(from: $0) }
        }
    }

    func updatePaint(_ layer: PaintLayer) {
        lock.withLock { paint = layer }
    }

    func setMirrored(_ mirrored: Bool) {
        lock.withLock { self.mirrored = mirrored }
    }

    func composite(cameraFrame: CVPixelBuffer, presentationTimeStamp _: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let width = Int32(CVPixelBufferGetWidth(cameraFrame))
        let height = Int32(CVPixelBufferGetHeight(cameraFrame))
        guard width > 0, height > 0 else { return nil }
        ensurePoolLocked(width: width, height: height)

        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else {
            return nil
        }
        let cameraImage = CIImage(cvPixelBuffer: cameraFrame)
        if mirrored {
            // Selfie-style program output matching the mirrored preview, so
            // paint lands under the finger as seen on screen.
            let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(width), ty: 0)
            context.render(cameraImage.transformed(by: flip), to: output)
        } else {
            context.render(cameraImage, to: output)
        }
        if overlay.isVisible, let card = overlay.card {
            drawCardLocked(card: card, position: overlay.position, expanded: overlay.isExpanded, zoomScale: overlay.zoomScale, into: output)
        }
        drawPaintLocked(layer: paint, cardVisible: overlay.isVisible, position: overlay.position, expanded: overlay.isExpanded, into: output)
        if let remaining = overlay.commandWindowRemaining {
            drawListeningDotLocked(remaining: remaining, into: output)
        }
        return output
    }

    /// Downscaled, orientation-corrected image for in-video rendering.
    /// Sized for imported slide readability (small text stays legible).
    static func thumbnail(from data: Data, maxPixelSize: Int = 1280) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// Listening-dot rectangle in bottom-origin pixel space: top-left in
    /// screen space (never mirrored), drawn over everything so the state
    /// survives cards, paint, and fullscreen expand.
    static func listeningDotRect(width: Int, height: Int) -> CGRect {
        let r = max(6, CGFloat(height) * 0.018)
        let m = CGFloat(width) * 0.03
        return CGRect(x: m, y: CGFloat(height) - m - r * 2, width: r * 2, height: r * 2)
    }

    /// Dot color for the remaining idle time: green, amber under 60 s.
    static func listeningDotColor(remaining: TimeInterval) -> CGColor {
        remaining < 60
            ? CGColor(red: 1, green: 0.62, blue: 0, alpha: 1)
            : CGColor(red: 0.2, green: 0.85, blue: 0.25, alpha: 1)
    }

    /// Card rectangle in bottom-origin pixel space: a position preset, or the
    /// (nearly) full frame when expanded.
    static func cardRect(width: Int, height: Int, position: CardOverlayPosition, expanded: Bool = false) -> CGRect {
        let margin = CGFloat(width) * 0.04
        if expanded {
            return CGRect(x: margin, y: margin, width: CGFloat(width) - margin * 2, height: CGFloat(height) - margin * 2)
        }
        switch position {
        case .bottom:
            let bannerHeight = CGFloat(height) * 0.30
            return CGRect(x: margin, y: margin, width: CGFloat(width) - margin * 2, height: bannerHeight)
        case .left:
            let panelWidth = CGFloat(width) * 0.36
            return CGRect(x: margin, y: margin, width: panelWidth, height: CGFloat(height) - margin * 2)
        case .right:
            let panelWidth = CGFloat(width) * 0.36
            return CGRect(x: CGFloat(width) - margin - panelWidth, y: margin, width: panelWidth, height: CGFloat(height) - margin * 2)
        }
    }

    /// Brush fade curve: full alpha while drawing (nil end), linear fade
    /// after release, gone at the end of the duration. Pure for testing;
    /// the draw path passes the current time.
    static func brushAlpha(endedAt: Date?, at now: Date, fadeDuration: TimeInterval) -> Double {
        guard let endedAt else { return 1 }
        guard fadeDuration > 0 else { return 0 }
        return max(0, 1 - now.timeIntervalSince(endedAt) / fadeDuration)
    }

    /// Draws committed + active paint strokes and fading brush strokes
    /// (clipped to the card, only when the card is visible) plus the live
    /// fingertip pointer.
    private func drawPaintLocked(layer: PaintLayer, cardVisible: Bool, position: CardOverlayPosition, expanded: Bool, into buffer: CVPixelBuffer) {
        guard layer.pointer != nil || (cardVisible && (!layer.strokes.isEmpty || !layer.brushStrokes.isEmpty)) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 320, height >= 180 else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return }

        let w = CGFloat(width)
        let h = CGFloat(height)
        func pixel(_ p: CGPoint) -> CGPoint {
            let x = mirrored ? 1 - p.x : p.x
            return CGPoint(x: x * w, y: p.y * h)
        }

        if cardVisible, !layer.strokes.isEmpty || !layer.brushStrokes.isEmpty {
            ctx.saveGState()
            ctx.clip(to: Self.cardRect(width: width, height: height, position: position, expanded: expanded))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(max(3, h * 0.008))
            func draw(_ stroke: PaintStroke, alpha: CGFloat) {
                let base = stroke.color.markerColor
                let color = alpha >= 1 ? base : (base.copy(alpha: alpha) ?? base)
                if stroke.points.count == 1, let dot = stroke.points.first {
                    let c = pixel(dot)
                    let r = max(2, h * 0.006)
                    ctx.setFillColor(color)
                    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                } else if stroke.points.count > 1 {
                    ctx.setStrokeColor(color)
                    let path = CGMutablePath()
                    path.move(to: pixel(stroke.points[0]))
                    for point in stroke.points.dropFirst() {
                        path.addLine(to: pixel(point))
                    }
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
            for stroke in layer.strokes {
                draw(stroke, alpha: 1)
            }
            let now = Date()
            for brush in layer.brushStrokes {
                let alpha = Self.brushAlpha(endedAt: brush.endedAt, at: now, fadeDuration: brush.fadeDuration)
                guard alpha > 0 else { continue }
                draw(brush.stroke, alpha: CGFloat(alpha))
            }
            ctx.restoreGState()
        }

        if let pointer = layer.pointer {
            let c = pixel(pointer)
            let r = max(5, h * 0.012)
            ctx.setFillColor(layer.pointerColor.markerColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }

    private func drawListeningDotLocked(remaining: TimeInterval, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 320, height >= 180 else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return }
        let rect = Self.listeningDotRect(width: width, height: height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillEllipse(in: rect.insetBy(dx: -3, dy: -3))
        ctx.setFillColor(Self.listeningDotColor(remaining: remaining))
        ctx.fillEllipse(in: rect)
    }

    // MARK: - Private (lock held)

    private func ensurePoolLocked(width: Int32, height: Int32) {
        if pool != nil, poolSize?.width == width, poolSize?.height == height { return }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
        pool = newPool
        poolSize = (width, height)
    }

    private func drawCardLocked(card: PresentationCard, position: CardOverlayPosition, expanded: Bool, zoomScale: CGFloat, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width >= 320, height >= 180 else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return }

        // Raw bitmap context: origin at the displayed bottom-left, y up.
        // Text uses Core Text, which draws directly into the CGContext —
        // NSAttributedString.draw needs an NSGraphicsContext and silently
        // drops glyphs on the video queue.
        ctx.textMatrix = .identity

        let margin = CGFloat(width) * 0.04
        let banner = Self.cardRect(width: width, height: height, position: position, expanded: expanded)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
        ctx.addPath(banner.rounded(radius: 12))
        ctx.fillPath()

        // Expanded cards scale text up so the fullscreen card stays proportional.
        let textScale: CGFloat = expanded ? 1.6 : 1.0
        let titleSize = max(18, CGFloat(height) * 0.055) * textScale
        let messageSize = max(14, CGFloat(height) * 0.038) * textScale
        let textX = banner.minX + margin * 0.6
        let maxWidth = banner.width - margin * 1.2

        // Title: single line pinned to the top of the card.
        let title = NSAttributedString(string: card.title, attributes: [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
            .foregroundColor: NSColor.white.cgColor,
        ])
        let titleLine = CTLineCreateWithAttributedString(title as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let titleWidth = CGFloat(CTLineGetTypographicBounds(titleLine, &ascent, &descent, nil))
        ctx.textPosition = CGPoint(x: textX, y: banner.maxY - margin * 0.5 - ascent)
        if titleWidth > maxWidth, let truncated = CTLineCreateTruncatedLine(titleLine, Double(maxWidth), .end, nil) {
            CTLineDraw(truncated, ctx)
        } else {
            CTLineDraw(titleLine, ctx)
        }

        // Message and optional picture share the space below the title, with
        // the picture below the texts.
        let messageTop = banner.maxY - margin * 0.5 - ascent - descent - 4
        let contentBottom = banner.minY + margin * 0.4
        var messageRect = CGRect(x: textX, y: contentBottom, width: maxWidth, height: messageTop - contentBottom)
        var pictureRect: CGRect?
        var pictureBox: CGRect?
        // Slide-style cards (title + picture, empty message) give the whole
        // below-title area to the picture instead of reserving an empty
        // message band; cards with text keep the message/picture split.
        let hasMessageText = !card.message.isEmpty
        if let image = overlayImage {
            let gap: CGFloat = hasMessageText ? 8 : 0
            let pictureH = (messageTop - contentBottom) * (hasMessageText ? 0.52 : 1.0)
            let messageH = messageTop - contentBottom - pictureH - gap
            if pictureH > 40, !hasMessageText || messageH > messageSize {
                if hasMessageText {
                    messageRect = CGRect(x: textX, y: contentBottom + pictureH + gap, width: maxWidth, height: messageH)
                }
                let box = CGRect(x: textX, y: contentBottom, width: maxWidth, height: pictureH)
                pictureBox = box
                pictureRect = Self.aspectFit(
                    CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                    in: box
                )
            }
        }
        if hasMessageText, messageRect.height > messageSize {
            let message = NSAttributedString(string: card.message, attributes: [
                .font: NSFont.systemFont(ofSize: messageSize, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92).cgColor,
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(message as CFAttributedString)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: messageRect, transform: nil), nil)
            CTFrameDraw(frame, ctx)
        }

        if let pictureRect, let box = pictureBox, let image = overlayImage {
            // In a standard y-up bitmap context CGImage draws upright; no flip
            // needed (the upside-down gotcha applies to flipped UIKit contexts).
            if zoomScale > 1 {
                let center = CGPoint(x: pictureRect.midX, y: pictureRect.midY)
                let zoomed = CGRect(
                    x: center.x - pictureRect.width * zoomScale / 2,
                    y: center.y - pictureRect.height * zoomScale / 2,
                    width: pictureRect.width * zoomScale,
                    height: pictureRect.height * zoomScale
                )
                ctx.saveGState()
                ctx.clip(to: box)
                ctx.draw(image, in: zoomed)
                ctx.restoreGState()
            } else {
                ctx.draw(image, in: pictureRect)
            }
        }
    }
}

private extension CGRect {
    func rounded(radius: CGFloat) -> CGPath {
        CGPath(roundedRect: self, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

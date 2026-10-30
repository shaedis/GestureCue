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
    private var messageFitKey = ""
    private var messageFitSize: CGFloat = 0
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
        let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(width), ty: 0)
        if overlay.isVisible, overlay.card != nil, overlay.position == .sideBySide, !overlay.isExpanded {
            // Video + Card: black stage, then the whole camera frame
            // aspect-fit into its tile (mirrored first, like fullscreen).
            let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            context.render(CIImage(color: .black).cropped(to: full), to: output)
            let tile = Self.videoRect(width: Int(width), height: Int(height), position: .sideBySide, cardPanel: overlay.cardPanel, expanded: false)
            let fitted = Self.aspectFit(CGSize(width: CGFloat(width), height: CGFloat(height)), in: tile)
            let scale = fitted.width / CGFloat(width)
            var video = mirrored ? cameraImage.transformed(by: flip) : cameraImage
            video = video.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: fitted.minX, ty: fitted.minY))
            context.render(video, to: output)
        } else if mirrored {
            // Selfie-style program output matching the mirrored preview, so
            // paint lands under the finger as seen on screen.
            context.render(cameraImage.transformed(by: flip), to: output)
        } else {
            context.render(cameraImage, to: output)
        }
        if overlay.isVisible, let card = overlay.card {
            drawCardLocked(card: card, position: overlay.position, cardPanel: overlay.cardPanel, expanded: overlay.isExpanded, zoomScale: overlay.zoomScale, badge: Self.numberBadge(number: overlay.cardNumber, total: overlay.cardCount), into: output)
        }
        drawPaintLocked(layer: paint, cardVisible: overlay.isVisible, position: overlay.position, cardPanel: overlay.cardPanel, expanded: overlay.isExpanded, into: output)
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
    /// (nearly) full frame when expanded. In Video + Card mode the panel
    /// sits at `cardPanel` (bottom half for `.bottom`).
    static func cardRect(
        width: Int, height: Int, position: CardOverlayPosition,
        cardPanel: CardPanelPosition = .right, expanded: Bool = false
    ) -> CGRect {
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
        case .sideBySide:
            switch cardPanel {
            case .left:
                let panelWidth = CGFloat(width) * 0.40
                return CGRect(x: margin, y: margin, width: panelWidth, height: CGFloat(height) - margin * 2)
            case .right:
                let panelWidth = CGFloat(width) * 0.40
                return CGRect(x: CGFloat(width) - margin - panelWidth, y: margin, width: panelWidth, height: CGFloat(height) - margin * 2)
            case .bottom:
                let stripHeight = CGFloat(height) / 2 - margin * 1.5
                return CGRect(x: margin, y: margin, width: CGFloat(width) - margin * 2, height: stripHeight)
            }
        }
    }

    /// Video tile in bottom-origin pixel space: the full frame except in
    /// Video + Card mode, where the camera shrinks into the tile opposite
    /// the card panel (aspect-fit, never cropped). Pure for testing.
    static func videoRect(
        width: Int, height: Int, position: CardOverlayPosition,
        cardPanel: CardPanelPosition = .right, expanded: Bool = false
    ) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        guard position == .sideBySide, !expanded else { return full }
        let margin = CGFloat(width) * 0.04
        switch cardPanel {
        case .left:
            let panelWidth = CGFloat(width) * 0.40
            let videoWidth = CGFloat(width) - margin * 3 - panelWidth
            return CGRect(x: margin * 2 + panelWidth, y: margin, width: videoWidth, height: CGFloat(height) - margin * 2)
        case .right:
            let panelWidth = CGFloat(width) * 0.40
            let videoWidth = CGFloat(width) - margin * 3 - panelWidth
            return CGRect(x: margin, y: margin, width: videoWidth, height: CGFloat(height) - margin * 2)
        case .bottom:
            let stripHeight = CGFloat(height) / 2 - margin * 1.5
            return CGRect(x: margin, y: CGFloat(height) / 2 + margin / 2, width: CGFloat(width) - margin * 2, height: stripHeight)
        }
    }

    /// Content rectangles below the title: message area + optional picture box.
    struct CardContentLayout: Equatable {
        var messageRect: CGRect
        var pictureBox: CGRect?
    }

    /// Splits the below-title area between message and picture. Wide
    /// short panels (bottom banners, Video + Card bottom panel) with artwork
    /// split side-by-side (text left, picture right) so illustrations stay
    /// visible; every other layout stacks text over picture, and
    /// picture-only cards give the picture the whole area. Pure for testing.
    static func contentLayout(
        banner: CGRect, margin: CGFloat, messageTop: CGFloat, messageSize: CGFloat,
        hasMessageText: Bool, hasImage: Bool, position: CardOverlayPosition,
        cardPanel: CardPanelPosition = .left, expanded: Bool
    ) -> CardContentLayout {
        let textX = banner.minX + margin * 0.6
        let maxWidth = banner.width - margin * 1.2
        let contentBottom = banner.minY + margin * 0.4
        let fullMessage = CGRect(x: textX, y: contentBottom, width: maxWidth, height: messageTop - contentBottom)
        guard hasImage else {
            return CardContentLayout(messageRect: fullMessage, pictureBox: nil)
        }
        let widePanel = position == .bottom || (position == .sideBySide && cardPanel == .bottom)
        if widePanel, !expanded, hasMessageText {
            let contentH = messageTop - contentBottom
            let textW = maxWidth * 0.55
            let pictureW = maxWidth - textW - 8
            if contentH > 90, pictureW > 140 {
                return CardContentLayout(
                    messageRect: CGRect(x: textX, y: contentBottom, width: textW, height: contentH),
                    pictureBox: CGRect(x: textX + textW + 8, y: contentBottom, width: pictureW, height: contentH)
                )
            }
            return CardContentLayout(messageRect: fullMessage, pictureBox: nil)
        }
        // Vertical stack: picture below the texts; picture-only cards give
        // the whole below-title area to the picture.
        let gap: CGFloat = hasMessageText ? 8 : 0
        let pictureH = (messageTop - contentBottom) * (hasMessageText ? 0.52 : 1.0)
        let messageH = messageTop - contentBottom - pictureH - gap
        guard pictureH > 40, !hasMessageText || messageH > messageSize else {
            return CardContentLayout(messageRect: fullMessage, pictureBox: nil)
        }
        var messageRect = fullMessage
        if hasMessageText {
            messageRect = CGRect(x: textX, y: contentBottom + pictureH + gap, width: maxWidth, height: messageH)
        }
        return CardContentLayout(
            messageRect: messageRect,
            pictureBox: CGRect(x: textX, y: contentBottom, width: maxWidth, height: pictureH)
        )
    }

    /// Wraps the card title into lines fitting maxWidth (up to maxLines;
    /// the last line ends with "…" when text remains), so long titles
    /// wrap instead of truncating on narrow side panels. Pure for testing.
    static func wrappedTitleLines(_ title: String, fontSize: CGFloat, maxWidth: CGFloat, maxLines: Int = 3) -> [String] {
        guard !title.isEmpty, maxWidth > 0, maxLines > 0 else { return [] }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let typesetter = CTTypesetterCreateWithAttributedString(
            NSAttributedString(string: title, attributes: [.font: font]) as CFAttributedString
        )
        let total = (title as NSString).length
        var lines: [String] = []
        var index = 0
        while index < total, lines.count < maxLines {
            let take = CTTypesetterSuggestLineBreak(typesetter, index, Double(maxWidth))
            guard take > 0 else { break }
            var text = ((title as NSString).substring(with: NSRange(location: index, length: take)) as String)
                .trimmingCharacters(in: .whitespaces)
            if lines.count == maxLines - 1, index + take < total {
                while !text.isEmpty, Self.titleLineWidth(text + "…", fontSize: fontSize) > maxWidth {
                    text.removeLast()
                    text = text.trimmingCharacters(in: .whitespaces)
                }
                lines.append(text + "…")
                break
            }
            lines.append(text)
            index += take
        }
        return lines.filter { !$0.isEmpty }
    }

    /// "N/M" position badge, or nil when the position is unknown.
    /// Pure for testing.
    static func numberBadge(number: Int?, total: Int) -> String? {
        guard let number, number >= 1, total >= 1 else { return nil }
        return "\(number)/\(total)"
    }

    /// Typographic width of one title line at the size. Internal for tests.
    static func titleLineWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]) as CFAttributedString
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// True when the whole message renders inside the rect at the size.
    static func messageFits(_ message: String, size: CGFloat, rect: CGRect) -> Bool {
        guard !message.isEmpty, rect.width > 0, rect.height > 0 else { return true }
        let attributes = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributes as CFAttributedString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: rect, transform: nil), nil)
        return CTFrameGetVisibleStringRange(frame).length >= (message as NSString).length
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
    private func drawPaintLocked(layer: PaintLayer, cardVisible: Bool, position: CardOverlayPosition, cardPanel: CardPanelPosition, expanded: Bool, into buffer: CVPixelBuffer) {
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
            ctx.clip(to: Self.cardRect(width: width, height: height, position: position, cardPanel: cardPanel, expanded: expanded))
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

    /// Largest message size (down to a readable floor) showing the whole
    /// text; cached per overlay content since frames vastly outnumber
    /// edits, so long bodies shrink instead of clipping mid-sentence.
    private func fittedMessageSizeLocked(message: String, maxSize: CGFloat, rect: CGRect) -> CGFloat {
        let minSize = max(11, maxSize * 0.55)
        let key = "\(message)|\(Int(rect.width))x\(Int(rect.height))@\(Int(maxSize))"
        if key == messageFitKey { return messageFitSize }
        var size = maxSize
        while size > minSize + 0.5, !Self.messageFits(message, size: size, rect: rect) {
            size = max(minSize, size * 0.9)
        }
        messageFitKey = key
        messageFitSize = size
        return size
    }

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

    private func drawCardLocked(card: PresentationCard, position: CardOverlayPosition, cardPanel: CardPanelPosition, expanded: Bool, zoomScale: CGFloat, badge: String?, into buffer: CVPixelBuffer) {
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
        let banner = Self.cardRect(width: width, height: height, position: position, cardPanel: cardPanel, expanded: expanded)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
        ctx.addPath(banner.rounded(radius: 12))
        ctx.fillPath()

        // Expanded cards scale text up so the fullscreen card stays proportional.
        let textScale: CGFloat = expanded ? 1.6 : 1.0
        let titleSize = max(18, CGFloat(height) * 0.055) * textScale
        let messageSize = max(14, CGFloat(height) * 0.038) * textScale
        let textX = banner.minX + margin * 0.6
        let maxWidth = banner.width - margin * 1.2

        // "N/M" position badge, top-right inside the banner; the title
        // gives way so long titles never run under it.
        let badgeFont = NSFont.systemFont(ofSize: max(14, titleSize * 0.45), weight: .bold)
        let titleMaxWidth: CGFloat
        if let badge {
            titleMaxWidth = maxWidth - Self.titleLineWidth(badge, fontSize: badgeFont.pointSize) - margin * 0.5
        } else {
            titleMaxWidth = maxWidth
        }

        // Title: wraps to fit the card width (up to 3 lines), pinned to
        // the top of the card; the message area starts below the block.
        let titleFont = NSFont.systemFont(ofSize: titleSize, weight: .bold)
        let titleLines = Self.wrappedTitleLines(card.title, fontSize: titleSize, maxWidth: titleMaxWidth)
        let titleTop = banner.maxY - margin * 0.5
        let lineHeight = titleFont.ascender - titleFont.descender + titleFont.leading
        var baseline = titleTop - titleFont.ascender
        for text in titleLines {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: titleFont,
                .foregroundColor: NSColor.white.cgColor,
            ]) as CFAttributedString)
            ctx.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(line, ctx)
            baseline -= lineHeight
        }
        if let badge {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: badge, attributes: [
                .font: badgeFont,
                .foregroundColor: NSColor.white.cgColor,
            ]) as CFAttributedString)
            let badgeWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(
                x: banner.maxX - margin * 0.6 - badgeWidth,
                y: titleTop - badgeFont.ascender
            )
            CTLineDraw(line, ctx)
        }
        // Bottom of the last line (or single-line metrics when empty).
        let titleBottom = titleLines.isEmpty
            ? titleTop - titleFont.ascender + titleFont.descender
            : baseline + lineHeight + titleFont.descender

        // Message and picture share the space below the title: bottom
        // banners split side-by-side, everything else stacks.
        let messageTop = titleBottom - 4
        let hasMessageText = !card.message.isEmpty
        let layout = Self.contentLayout(
            banner: banner, margin: margin, messageTop: messageTop, messageSize: messageSize,
            hasMessageText: hasMessageText, hasImage: overlayImage != nil,
            position: position, cardPanel: cardPanel, expanded: expanded
        )
        let messageRect = layout.messageRect
        let pictureBox = layout.pictureBox
        var pictureRect: CGRect?
        if let image = overlayImage, let box = pictureBox {
            pictureRect = Self.aspectFit(
                CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                in: box
            )
        }
        if hasMessageText, messageRect.height > 12 {
            let fitted = fittedMessageSizeLocked(message: card.message, maxSize: messageSize, rect: messageRect)
            let message = NSAttributedString(string: card.message, attributes: [
                .font: NSFont.systemFont(ofSize: fitted, weight: .regular),
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

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
        let overlayHasText = overlay.card.map { !$0.title.isEmpty || !$0.message.isEmpty } ?? false
        drawPaintLocked(layer: paint, cardVisible: overlay.isVisible, position: overlay.position, cardPanel: overlay.cardPanel, expanded: overlay.isExpanded, hasImage: overlayImage != nil, hasText: overlayHasText, into: output)
        if let subtitle = overlay.subtitle, !subtitle.isEmpty {
            drawSubtitleLocked(
                text: subtitle, position: overlay.position, cardPanel: overlay.cardPanel,
                expanded: overlay.isExpanded, cardVisible: overlay.isVisible && overlay.card != nil,
                style: overlay.subtitleStyle, hasText: overlayHasText, into: output
            )
        }
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
        case .split:
            return Self.splitTextRect(width: width, height: height)
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

    /// Split-mode text banner in bottom-origin pixel space: a compact
    /// subtitle-like strip (~two lines: title + message) along the
    /// bottom, leaving the frame to the video and the side picture
    /// panel. Pure for testing.
    static func splitTextRect(width: Int, height: Int) -> CGRect {
        let margin = CGFloat(width) * 0.04
        let bannerHeight = CGFloat(height) * 0.22
        return CGRect(x: margin, y: margin, width: CGFloat(width) - margin * 2, height: bannerHeight)
    }

    /// Split-mode picture panel: a side column above the text banner
    /// (never overlapping it), same width as the `.left`/`.right`
    /// presets. `.bottom` reads as right. Textless cards (picture-only)
    /// have no text strip, so the panel spans the full height instead.
    /// Pure for testing.
    static func splitPictureRect(width: Int, height: Int, side: CardPanelPosition, fullHeight: Bool = false) -> CGRect {
        let margin = CGFloat(width) * 0.04
        let panelWidth = CGFloat(width) * 0.36
        let x = side == .left ? margin : CGFloat(width) - margin - panelWidth
        if fullHeight {
            return CGRect(x: x, y: margin, width: panelWidth, height: CGFloat(height) - margin * 2)
        }
        let bannerTop = splitTextRect(width: width, height: height).maxY + margin * 0.5
        return CGRect(x: x, y: bannerTop, width: panelWidth, height: CGFloat(height) - margin - bannerTop)
    }

    /// Most lines the live subtitle strip grows for; longer text
    /// shrinks to fit instead of growing past this.
    static let maxSubtitleLines = 3

    /// Live subtitle strip in bottom-origin pixel space: starts slim
    /// for one line and grows per line (capped), slimmer than the
    /// split card strip because it carries centered text only (no
    /// title block). Pure for testing.
    static func liveSubtitleStrip(width: Int, height: Int, lines: Int = 1, scale: Double = 1) -> CGRect {
        let margin = CGFloat(width) * 0.04
        let clamped = min(max(lines, 1), maxSubtitleLines)
        let font = NSFont.systemFont(ofSize: max(14, CGFloat(height) * 0.038) * scale, weight: .semibold)
        let lineHeight = font.ascender - font.descender + font.leading
        let stripHeight = margin * 0.5 + CGFloat(clamped) * lineHeight
        return CGRect(x: margin, y: margin, width: CGFloat(width) - margin * 2, height: stripHeight)
    }

    /// Rendered line count of subtitle text at the size within the
    /// width: explicit newlines plus wrapping (uncapped; the strip
    /// clamps). Pure for testing.
    static func subtitleLineCount(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> Int {
        guard !text.isEmpty, maxWidth > 0 else { return 1 }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        return text.components(separatedBy: .newlines).reduce(0) { count, paragraph in
            count + max(1, wrappedLineCount(paragraph, font: font, maxWidth: maxWidth))
        }
    }

    /// Wrapped line count of one newline-free paragraph. Internal for tests.
    static func wrappedLineCount(_ paragraph: String, font: NSFont, maxWidth: CGFloat) -> Int {
        let total = (paragraph as NSString).length
        guard total > 0 else { return 0 }
        let typesetter = CTTypesetterCreateWithAttributedString(
            NSAttributedString(string: paragraph, attributes: [.font: font]) as CFAttributedString
        )
        var lines = 0
        var index = 0
        while index < total {
            let take = CTTypesetterSuggestLineBreak(typesetter, index, Double(maxWidth))
            guard take > 0 else { break }
            lines += 1
            index += take
        }
        return max(lines, 1)
    }

    /// Subtitle strip in bottom-origin pixel space: along the bottom,
    /// lifted just above bottom cards (bottom preset, split strip,
    /// Video + Card bottom panel) and narrowed beside full-height
    /// side cards, so it never covers the card. Full width when no
    /// card shows or the card is fullscreen. A textless split card
    /// has no strip — its full-height panel reads as a side card.
    /// Pure for testing.
    static func subtitleRect(
        width: Int, height: Int, position: CardOverlayPosition,
        cardPanel: CardPanelPosition = .right, expanded: Bool = false, cardVisible: Bool = false,
        lines: Int = 1, scale: Double = 1, hasText: Bool = true
    ) -> CGRect {
        let base = liveSubtitleStrip(width: width, height: height, lines: lines, scale: scale)
        guard cardVisible, !expanded else { return base }
        // Textless split behaves as a side card on the panel side (its
        // full-height panel equals the side preset geometry).
        let effective: CardOverlayPosition
        if position == .split, !hasText {
            effective = cardPanel == .left ? .left : .right
        } else {
            effective = position
        }
        let margin = CGFloat(width) * 0.04
        switch effective {
        case .bottom, .split:
            let cardTop = cardRect(
                width: width, height: height, position: effective,
                cardPanel: cardPanel, expanded: false
            ).maxY
            return CGRect(x: base.minX, y: cardTop + margin * 0.5, width: base.width, height: base.height)
        case .sideBySide where cardPanel == .bottom:
            let cardTop = cardRect(
                width: width, height: height, position: effective,
                cardPanel: cardPanel, expanded: false
            ).maxY
            return CGRect(x: base.minX, y: cardTop + margin * 0.5, width: base.width, height: base.height)
        case .left:
            let cardMaxX = cardRect(
                width: width, height: height, position: effective,
                cardPanel: cardPanel, expanded: false
            ).maxX
            let x = cardMaxX + margin * 0.5
            return CGRect(x: x, y: base.minY, width: base.maxX - x, height: base.height)
        case .right:
            let cardMinX = cardRect(
                width: width, height: height, position: effective,
                cardPanel: cardPanel, expanded: false
            ).minX
            return CGRect(x: base.minX, y: base.minY, width: cardMinX - margin * 0.5 - base.minX, height: base.height)
        case .sideBySide:
            return base
        }
    }

    /// Paint clip rectangles: the single card rect normally, the text
    /// strip plus the picture panel in Split mode when a picture is
    /// drawn (paint must reach both halves and nothing else).
    /// Textless split cards have no strip: the full-height panel
    /// alone. Pure for testing.
    static func paintClipRects(
        width: Int, height: Int, position: CardOverlayPosition,
        cardPanel: CardPanelPosition = .right, expanded: Bool = false, hasImage: Bool = false,
        hasText: Bool = true
    ) -> [CGRect] {
        if position == .split, !expanded, hasImage {
            if !hasText {
                return [splitPictureRect(width: width, height: height, side: cardPanel, fullHeight: true)]
            }
            return [
                splitTextRect(width: width, height: height),
                splitPictureRect(width: width, height: height, side: cardPanel),
            ]
        }
        return [cardRect(width: width, height: height, position: position, cardPanel: cardPanel, expanded: expanded)]
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

    /// Halo trigger threshold: line-vs-background luminance gap below
    /// this earns a halo (0-255 units). Red-on-white (127) and any color
    /// on dark cards (90+) stay clean; yellow-on-white (46) and colors
    /// on mid-tone photos halo.
    static let haloTriggerGap: Double = 80
    /// Background luminance above which a dark tunnel is the only
    /// separator (a white halo would be invisible on near-white).
    static let haloNearWhite: Double = 210
    /// Long stroke runs subdivide to this normalized step so each
    /// halo segment samples its own local background.
    static let haloSampleStep: CGFloat = 0.05

    /// Rec. 601 luminance of an RGB color in 0-255 units.
    static func luminance(of color: CGColor) -> Double {
        guard let components = color.components, components.count >= 3 else { return 0 }
        return (0.299 * Double(components[0]) + 0.587 * Double(components[1]) + 0.114 * Double(components[2])) * 255
    }

    /// Mean background luminance (0-255) sampled from the live BGRA
    /// buffer over the stroke's pixel bbox inflated by `radius`
    /// (stride-capped to ~400 samples). Nil when there is nothing to
    /// sample. The caller must hold the buffer lock.
    static func backgroundLuminance(
        around points: [CGPoint], pixel: (CGPoint) -> CGPoint,
        buffer: UnsafeMutableRawPointer, width: Int, height: Int,
        bytesPerRow: Int, radius: CGFloat
    ) -> Double? {
        guard !points.isEmpty, width > 0, height > 0 else { return nil }
        var minX = width, maxX = 0, minY = height, maxY = 0
        for point in points {
            let c = pixel(point)
            // CG points are y-up; buffer memory rows are y-down (row 0
            // is the displayed top).
            let memY = CGFloat(height - 1) - c.y
            minX = min(minX, Int(c.x - radius)); maxX = max(maxX, Int(c.x + radius))
            minY = min(minY, Int(memY - radius)); maxY = max(maxY, Int(memY + radius))
        }
        minX = max(0, minX); minY = max(0, minY)
        maxX = min(width - 1, maxX); maxY = min(height - 1, maxY)
        guard maxX >= minX, maxY >= minY else { return nil }
        let spanX = maxX - minX + 1, spanY = maxY - minY + 1
        let stride = max(1, Int((Double(spanX * spanY) / 400).squareRoot()))
        var sum = 0.0, count = 0
        var y = minY
        while y <= maxY {
            let row = buffer.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var x = minX
            while x <= maxX {
                sum += 0.299 * Double(row[x * 4 + 2]) + 0.587 * Double(row[x * 4 + 1]) + 0.114 * Double(row[x * 4])
                count += 1
                x += stride
            }
            y += stride
        }
        guard count > 0 else { return nil }
        return sum / Double(count)
    }

    /// Draws committed + active paint strokes and fading brush strokes
    /// (clipped to the card, only when the card is visible) plus the live
    /// fingertip pointer.
    private func drawPaintLocked(layer: PaintLayer, cardVisible: Bool, position: CardOverlayPosition, cardPanel: CardPanelPosition, expanded: Bool, hasImage: Bool, hasText: Bool, into buffer: CVPixelBuffer) {
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
            // Split mode paints in two disjoint rects: clip to their
            // union via the path (beginPath keeps the clip rects out of
            // later strokePath calls). The single-rect path is unchanged.
            let clips = Self.paintClipRects(
                width: width, height: height, position: position,
                cardPanel: cardPanel, expanded: expanded, hasImage: hasImage, hasText: hasText
            )
            if clips.count == 1, let only = clips.first {
                ctx.clip(to: only)
            } else {
                for rect in clips { ctx.addRect(rect) }
                ctx.clip()
                ctx.beginPath()
            }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let lineWidth = max(3, h * 0.008)
            ctx.setLineWidth(lineWidth)
            // Fading brush strokes get an adaptive halo under the color
            // line: it appears only when the line's luminance is close to
            // the sampled background (a thin fading line otherwise drops
            // below visibility, e.g. yellow on a white diagram — while
            // red on white or any color on dark cards needs nothing).
            // Polarity pushes the tunnel AWAY from the line color (dark
            // halo above the line, white below it — except on near-white,
            // where only a dark tunnel separates), so the fade can never
            // sweep the tunnel through the line color; the halo lingers
            // slightly into the fade and both reach zero together, so the
            // gradual-vanish feel is untouched and nothing ghosts.
            func draw(_ stroke: PaintStroke, alpha: CGFloat, halo: Bool) {
                let marker = stroke.color.markerColor
                let color = alpha >= 1 ? marker : (marker.copy(alpha: alpha) ?? marker)
                let lineLum = halo ? Self.luminance(of: marker) : 0
                let haloAlpha = 0.55 * min(1, 2 * alpha)
                /// Halo color separating this background sample from the
                /// line, or nil when the line already contrasts it.
                func haloForBg(_ bgLum: Double) -> CGColor? {
                    guard abs(lineLum - bgLum) < Self.haloTriggerGap else { return nil }
                    let dark = lineLum >= bgLum || bgLum > Self.haloNearWhite
                    return CGColor(gray: dark ? 0 : 1, alpha: haloAlpha)
                }
                func bgAround(_ points: [CGPoint]) -> Double? {
                    Self.backgroundLuminance(
                        around: points, pixel: pixel, buffer: base,
                        width: width, height: height, bytesPerRow: bytesPerRow, radius: lineWidth
                    )
                }
                if stroke.points.count == 1, let dot = stroke.points.first {
                    let c = pixel(dot)
                    let r = max(2, h * 0.006)
                    if halo, let bgLum = bgAround([dot]), let haloColor = haloForBg(bgLum) {
                        ctx.setFillColor(haloColor)
                        ctx.fillEllipse(in: CGRect(x: c.x - r * 2, y: c.y - r * 2, width: r * 4, height: r * 4))
                    }
                    ctx.setFillColor(color)
                    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                } else if stroke.points.count > 1 {
                    let path = CGMutablePath()
                    path.move(to: pixel(stroke.points[0]))
                    for point in stroke.points.dropFirst() {
                        path.addLine(to: pixel(point))
                    }
                    if halo {
                        // Per-segment halos: a stroke can cross dark text
                        // into a white photo, so each short run samples
                        // its own background (long runs subdivide).
                        ctx.setLineWidth(lineWidth * 2)
                        for index in stroke.points.indices.dropFirst() {
                            let a = stroke.points[index - 1], b = stroke.points[index]
                            let runs = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / Self.haloSampleStep)))
                            for run in 0 ..< runs {
                                let t0 = CGFloat(run) / CGFloat(runs), t1 = CGFloat(run + 1) / CGFloat(runs)
                                let p0 = CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
                                let p1 = CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
                                let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                                guard let bgLum = bgAround([mid]), let haloColor = haloForBg(bgLum) else { continue }
                                ctx.setStrokeColor(haloColor)
                                let seg = CGMutablePath()
                                seg.move(to: pixel(p0))
                                seg.addLine(to: pixel(p1))
                                ctx.addPath(seg)
                                ctx.strokePath()
                            }
                        }
                        ctx.setLineWidth(lineWidth)
                    }
                    ctx.setStrokeColor(color)
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
            for stroke in layer.strokes {
                draw(stroke, alpha: 1, halo: false)
            }
            let now = Date()
            for brush in layer.brushStrokes {
                let alpha = Self.brushAlpha(endedAt: brush.endedAt, at: now, fadeDuration: brush.fadeDuration)
                guard alpha > 0 else { continue }
                draw(brush.stroke, alpha: CGFloat(alpha), halo: true)
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

    /// Draws the transient live subtitle: a centered two-liner over a
    /// subtitle strip, lifted above bottom cards so it never covers
    /// them. Session-only; the deck is untouched.
    private func drawSubtitleLocked(
        text: String, position: CardOverlayPosition, cardPanel: CardPanelPosition,
        expanded: Bool, cardVisible: Bool, style: SubtitleStyle, hasText: Bool, into buffer: CVPixelBuffer
    ) {
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
        ctx.textMatrix = .identity

        let margin = CGFloat(width) * 0.04
        let maxSize = max(14, CGFloat(height) * 0.038) * style.scale
        // Line count needs the true strip width (side cards narrow
        // it): measure a one-line strip first, then size for real.
        let probe = Self.subtitleRect(
            width: width, height: height, position: position,
            cardPanel: cardPanel, expanded: expanded, cardVisible: cardVisible,
            lines: 1, scale: style.scale, hasText: hasText
        )
        let lines = Self.subtitleLineCount(text, fontSize: maxSize, maxWidth: probe.width - margin * 1.2)
        let strip = Self.subtitleRect(
            width: width, height: height, position: position,
            cardPanel: cardPanel, expanded: expanded, cardVisible: cardVisible,
            lines: lines, scale: style.scale, hasText: hasText
        )
        ctx.setFillColor(style.backgroundColor.cgColor)
        ctx.addPath(strip.rounded(radius: 12))
        ctx.fillPath()

        let textRect = strip.insetBy(dx: margin * 0.6, dy: margin * 0.25)
        guard textRect.height > 12 else { return }
        let fitted = fittedMessageSizeLocked(message: text, maxSize: maxSize, rect: textRect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fitted, weight: .semibold),
            .foregroundColor: style.textColor.cgColor,
            .paragraphStyle: paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: textRect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
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
        // Split mode (unexpanded) draws the subtitle strip: short title
        // plus message, picture in its own side panel. Textless cards
        // (picture-only) skip the strip entirely — a zero banner draws
        // nothing — and the panel spans the full height instead.
        let isSplit = position == .split && !expanded
        let hasText = !card.title.isEmpty || !card.message.isEmpty
        let skipStrip = isSplit && !hasText
        let banner = skipStrip ? .zero : Self.cardRect(width: width, height: height, position: position, cardPanel: cardPanel, expanded: expanded)
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
        let titleLines = Self.wrappedTitleLines(card.title, fontSize: titleSize, maxWidth: titleMaxWidth, maxLines: isSplit ? 2 : 3)
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
        if let badge, !skipStrip {
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
        // banners split side-by-side, everything else stacks. Split mode
        // instead draws the picture in its own side panel, so the banner
        // lays out text-only and full-width.
        let messageTop = titleBottom - 4
        let hasMessageText = !card.message.isEmpty
        let splitPicture = isSplit && overlayImage != nil
        let layout = Self.contentLayout(
            banner: banner, margin: margin, messageTop: messageTop, messageSize: messageSize,
            hasMessageText: hasMessageText, hasImage: overlayImage != nil && !splitPicture,
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

        // Photographic and generated art carries nothing exact at the
        // edges, so side panels cover their picture box with it (no
        // bars); diagrams (exact edge labels) and expanded cards
        // always fit uncropped.
        let coverArt = card.diagramKind == nil
        let inCardCover = coverArt && !expanded && (position == .left || position == .right)
        if let box = pictureBox, let image = overlayImage {
            if inCardCover {
                let filled = Self.aspectFill(
                    CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                    in: box
                )
                Self.drawPicture(image, fitted: filled, box: box, zoomScale: zoomScale, ctx: ctx, cover: true)
            } else if let pictureRect {
                Self.drawPicture(image, fitted: pictureRect, box: box, zoomScale: zoomScale, ctx: ctx)
            }
        }

        // Split mode: the picture fills its own side panel above the
        // text banner — cover for art, fit for exact diagrams.
        // Textless cards have no strip, so the panel goes full height.
        if splitPicture, let image = overlayImage {
            let panel = Self.splitPictureRect(width: width, height: height, side: cardPanel, fullHeight: !hasText)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
            ctx.addPath(panel.rounded(radius: 12))
            ctx.fillPath()
            let box = panel.insetBy(dx: margin * 0.4, dy: margin * 0.4)
            if coverArt {
                let filled = Self.aspectFill(
                    CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                    in: box
                )
                Self.drawPicture(image, fitted: filled, box: box, zoomScale: zoomScale, ctx: ctx, cover: true)
            } else {
                let fitted = Self.aspectFit(
                    CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                    in: box
                )
                Self.drawPicture(image, fitted: fitted, box: box, zoomScale: zoomScale, ctx: ctx)
            }
        }
    }

    /// Largest rect of the size covering the box (centered; crops the
    /// overflow). Pure for testing.
    static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let filled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - filled.width / 2, y: rect.midY - filled.height / 2, width: filled.width, height: filled.height)
    }

    /// Draws the picture aspect-fit rect (zoomed about its center and
    /// clipped to the box when zoomed). In-card art fits (never crops);
    /// the split-mode side panel covers (crops sides, no bars).
    private static func drawPicture(
        _ image: CGImage, fitted: CGRect, box: CGRect, zoomScale: CGFloat, ctx: CGContext, cover: Bool = false
    ) {
        // In a standard y-up bitmap context CGImage draws upright; no flip
        // needed (the upside-down gotcha applies to flipped UIKit contexts).
        if cover {
            // Cover rect exceeds the box: always clip, zoom multiplies.
            let center = CGPoint(x: fitted.midX, y: fitted.midY)
            let zoomed = CGRect(
                x: center.x - fitted.width * zoomScale / 2,
                y: center.y - fitted.height * zoomScale / 2,
                width: fitted.width * zoomScale,
                height: fitted.height * zoomScale
            )
            ctx.saveGState()
            ctx.clip(to: box)
            ctx.draw(image, in: zoomed)
            ctx.restoreGState()
        } else if zoomScale > 1 {
            let center = CGPoint(x: fitted.midX, y: fitted.midY)
            let zoomed = CGRect(
                x: center.x - fitted.width * zoomScale / 2,
                y: center.y - fitted.height * zoomScale / 2,
                width: fitted.width * zoomScale,
                height: fitted.height * zoomScale
            )
            ctx.saveGState()
            ctx.clip(to: box)
            ctx.draw(image, in: zoomed)
            ctx.restoreGState()
        } else {
            ctx.draw(image, in: fitted)
        }
    }
}

private extension CGRect {
    func rounded(radius: CGFloat) -> CGPath {
        CGPath(roundedRect: self, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

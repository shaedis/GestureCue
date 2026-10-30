import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Deterministic diagram renderer: exact educational content (fractions,
/// number lines, timelines, cause→effect chains) is drawn programmatically
/// so labels and proportions are always correct — never trusted to image
/// pixels. Unknown kinds and invalid numbers return nil so the caller
/// falls back to the generated illustration.
struct DiagramRenderer: Sendable {
    static let canvasSize = CGSize(width: 1280, height: 720)

    static func render(_ spec: DiagramSpec, size: CGSize = canvasSize) -> Data? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width >= 320, height >= 180 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.textMatrix = .identity

        let drawn: Bool
        switch spec.kind {
        case "fractionCircle":
            drawn = drawFraction(ctx: ctx, spec: spec, size: size)
        case "numberLine":
            drawn = drawNumberLine(ctx: ctx, spec: spec, size: size)
        case "timeline":
            drawn = drawTimeline(ctx: ctx, spec: spec, size: size)
        case "causeEffect":
            drawn = drawCauseEffect(ctx: ctx, spec: spec, size: size)
        default:
            return nil
        }
        guard drawn, let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Kinds (each validates, false = fall back to illustration)

    /// numbers = [shaded, total] (integral); labels[0] = fraction text.
    private static func drawFraction(ctx: CGContext, spec: DiagramSpec, size: CGSize) -> Bool {
        guard spec.numbers.count == 2 else { return false }
        let shaded = spec.numbers[0]
        let total = spec.numbers[1]
        guard total >= 1, total <= 12, total == total.rounded(),
              shaded >= 0, shaded <= total, shaded == shaded.rounded()
        else { return false }
        let n = Int(total)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.44)
        let radius = min(size.width, size.height) * 0.30
        for index in 0..<n {
            let start = -CGFloat.pi / 2 + CGFloat(index) * 2 * CGFloat.pi / CGFloat(n)
            let end = start + 2 * CGFloat.pi / CGFloat(n)
            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            ctx.closePath()
            ctx.setFillColor(index < Int(shaded) ? Palette.blue : Palette.slateLight)
            ctx.fillPath()
            ctx.setStrokeColor(Palette.ink)
            ctx.setLineWidth(3)
            ctx.strokePath()
        }
        if let caption = spec.caption, !caption.isEmpty {
            drawCentered(ctx: ctx, text: caption, fontSize: size.height * 0.055,
                         yCenter: size.height * 0.88, maxWidth: size.width * 0.9, bold: true, centerX: size.width / 2)
        }
        let fraction = spec.labels.first ?? "\(Int(shaded))/\(n)"
        drawCentered(ctx: ctx, text: fraction, fontSize: size.height * 0.075,
                     yCenter: size.height * 0.10, maxWidth: size.width * 0.9, bold: true, centerX: size.width / 2)
        return true
    }

    /// numbers = [min, max, marks...]; labels[i] names marks[i].
    private static func drawNumberLine(ctx: CGContext, spec: DiagramSpec, size: CGSize) -> Bool {
        guard spec.numbers.count >= 2 else { return false }
        let minValue = spec.numbers[0]
        let maxValue = spec.numbers[1]
        guard minValue < maxValue else { return false }
        let marks = Array(spec.numbers.dropFirst(2))
        let left = size.width * 0.08
        let right = size.width * 0.92
        let axisY = size.height * 0.44
        func x(_ value: Double) -> CGFloat {
            left + CGFloat((value - minValue) / (maxValue - minValue)) * (right - left)
        }
        ctx.setStrokeColor(Palette.ink)
        ctx.setLineWidth(4)
        ctx.move(to: CGPoint(x: left, y: axisY))
        ctx.addLine(to: CGPoint(x: right, y: axisY))
        ctx.strokePath()
        // Ticks: integer steps when the range is small, else quintiles.
        var ticks: [Double] = []
        if minValue == minValue.rounded(), maxValue == maxValue.rounded(), maxValue - minValue <= 20 {
            ticks = (Int(minValue)...Int(maxValue)).map(Double.init)
        } else {
            ticks = (0...4).map { minValue + (maxValue - minValue) * Double($0) / 4 }
        }
        for tick in ticks {
            let px = x(tick)
            ctx.setStrokeColor(Palette.ink)
            ctx.setLineWidth(3)
            ctx.move(to: CGPoint(x: px, y: axisY - 10))
            ctx.addLine(to: CGPoint(x: px, y: axisY + 10))
            ctx.strokePath()
            drawCentered(ctx: ctx, text: tickLabel(tick), fontSize: size.height * 0.04,
                         yCenter: axisY - size.height * 0.06, maxWidth: 120, bold: false, centerX: px)
        }
        for (index, mark) in marks.enumerated() {
            let px = x(mark)
            ctx.setFillColor(Palette.red)
            ctx.fillEllipse(in: CGRect(x: px - 10, y: axisY - 10, width: 20, height: 20))
            let label = index < spec.labels.count ? spec.labels[index] : tickLabel(mark)
            drawCentered(ctx: ctx, text: label, fontSize: size.height * 0.045,
                         yCenter: axisY + size.height * 0.07, maxWidth: 220, bold: true, centerX: px)
        }
        if let caption = spec.caption, !caption.isEmpty {
            drawCentered(ctx: ctx, text: caption, fontSize: size.height * 0.055,
                         yCenter: size.height * 0.88, maxWidth: size.width * 0.9, bold: true, centerX: size.width / 2)
        }
        return true
    }

    /// numbers = years in order; labels[i] = event for numbers[i].
    private static func drawTimeline(ctx: CGContext, spec: DiagramSpec, size: CGSize) -> Bool {
        guard spec.numbers.count >= 2, spec.numbers.count <= 8 else { return false }
        let count = spec.numbers.count
        let left = size.width * 0.08
        let right = size.width * 0.92
        let axisY = size.height * 0.44
        ctx.setStrokeColor(Palette.ink)
        ctx.setLineWidth(5)
        ctx.move(to: CGPoint(x: left, y: axisY))
        ctx.addLine(to: CGPoint(x: right, y: axisY))
        ctx.strokePath()
        for index in 0..<count {
            let px = count == 1 ? (left + right) / 2 : left + CGFloat(index) / CGFloat(count - 1) * (right - left)
            ctx.setFillColor(Palette.blue)
            ctx.fillEllipse(in: CGRect(x: px - 11, y: axisY - 11, width: 22, height: 22))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: px - 5, y: axisY - 5, width: 10, height: 10))
            let year = tickLabel(spec.numbers[index])
            drawCentered(ctx: ctx, text: year, fontSize: size.height * 0.042,
                         yCenter: axisY - size.height * 0.07, maxWidth: 200, bold: true, centerX: px)
            if index < spec.labels.count, !spec.labels[index].isEmpty {
                let above = index.isMultiple(of: 2)
                drawCentered(ctx: ctx, text: spec.labels[index], fontSize: size.height * 0.04,
                             yCenter: above ? axisY + size.height * 0.09 : axisY - size.height * 0.16,
                             maxWidth: (right - left) / CGFloat(count) * 0.95, bold: false, centerX: px)
            }
        }
        if let caption = spec.caption, !caption.isEmpty {
            drawCentered(ctx: ctx, text: caption, fontSize: size.height * 0.055,
                         yCenter: size.height * 0.88, maxWidth: size.width * 0.9, bold: true, centerX: size.width / 2)
        }
        return true
    }

    /// labels = nodes left→right with arrows; the last node is the effect.
    private static func drawCauseEffect(ctx: CGContext, spec: DiagramSpec, size: CGSize) -> Bool {
        guard spec.labels.count >= 2, spec.labels.count <= 6 else { return false }
        let count = spec.labels.count
        let boxWidth = size.width * 0.80 / CGFloat(count)
        let boxHeight = size.height * 0.22
        let totalWidth = boxWidth * CGFloat(count)
        let originX = (size.width - totalWidth) / 2
        let boxY = size.height * 0.33
        for index in 0..<count {
            let rect = CGRect(x: originX + CGFloat(index) * boxWidth + 6,
                              y: boxY, width: boxWidth - 12, height: boxHeight)
            let isEffect = index == count - 1
            ctx.setFillColor(isEffect ? Palette.orangeLight : Palette.slateLight)
            ctx.fill(rect)
            ctx.setStrokeColor(isEffect ? Palette.orange : Palette.blue)
            ctx.setLineWidth(4)
            ctx.stroke(rect)
            drawCentered(ctx: ctx, text: spec.labels[index], fontSize: size.height * 0.038,
                         yCenter: boxY + boxHeight / 2, maxWidth: boxWidth - 24,
                         bold: isEffect, centerX: rect.midX)
            if index < count - 1 {
                let x0 = rect.maxX + 2
                let x1 = rect.maxX + 10
                let midY = boxY + boxHeight / 2
                ctx.setStrokeColor(Palette.ink)
                ctx.setLineWidth(4)
                ctx.move(to: CGPoint(x: x0, y: midY))
                ctx.addLine(to: CGPoint(x: x1, y: midY))
                ctx.move(to: CGPoint(x: x1 - 7, y: midY + 6))
                ctx.addLine(to: CGPoint(x: x1, y: midY))
                ctx.addLine(to: CGPoint(x: x1 - 7, y: midY - 6))
                ctx.strokePath()
            }
        }
        if let caption = spec.caption, !caption.isEmpty {
            drawCentered(ctx: ctx, text: caption, fontSize: size.height * 0.055,
                         yCenter: size.height * 0.82, maxWidth: size.width * 0.9, bold: true, centerX: size.width / 2)
        }
        return true
    }

    // MARK: - Helpers

    private static func tickLabel(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private enum Palette {
        static let ink = CGColor(gray: 0.15, alpha: 1)
        static let blue = CGColor(red: 0.20, green: 0.45, blue: 0.90, alpha: 1)
        static let orange = CGColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        static let orangeLight = CGColor(red: 1, green: 0.93, blue: 0.82, alpha: 1)
        static let slateLight = CGColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1)
        static let red = CGColor(red: 0.85, green: 0.20, blue: 0.20, alpha: 1)
    }

    private static func drawCentered(ctx: CGContext, text: String, fontSize: CGFloat,
                                     yCenter: CGFloat, maxWidth: CGFloat, bold: Bool, centerX: CGFloat) {
        guard !text.isEmpty else { return }
        let traits: [CFString: Any] = [kCTFontWeightTrait: (bold ? 0.4 : 0.0) as CGFloat]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.ink,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var use = line
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth,
           let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, nil) {
            use = truncated
        }
        let width = CGFloat(CTLineGetTypographicBounds(use, nil, nil, nil))
        let cx = centerX
        ctx.textPosition = CGPoint(x: cx - width / 2, y: yCenter - fontSize * 0.35)
        CTLineDraw(use, ctx)
    }
}

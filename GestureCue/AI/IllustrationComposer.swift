import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Burns a title band and label line onto generated artwork so each draft
/// card is one cohesive 16:9 visual (title + labels stay readable at
/// video size and travel with the image into the catalog). Pure static
/// renderer; nil base image passes through as nil (text-only card).
struct IllustrationComposer: Sendable {
    static let canvasSize = CGSize(width: 1280, height: 720)

    static func compose(
        imageData: Data?, title: String, labels: [String],
        size: CGSize = canvasSize
    ) -> Data? {
        guard let imageData, let base = thumbnail(from: imageData, maxPixelSize: Int(max(size.width, size.height))) else {
            return nil
        }
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

        // Base artwork, aspect-filled.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let fitted = aspectFill(CGSize(width: base.width, height: base.height), in: size)
        ctx.draw(base, in: fitted)

        // Title band along the bottom.
        let margin = size.width * 0.04
        let bandHeight = size.height * 0.28
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.72))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: bandHeight))
        ctx.textMatrix = .identity
        let textX = margin
        let maxWidth = size.width - margin * 2
        drawLine(ctx: ctx, text: title, fontSize: size.height * 0.064, weight: 700,
                 at: CGPoint(x: textX, y: bandHeight * 0.52), maxWidth: maxWidth)
        let labelLine = labels.joined(separator: " • ")
        if !labelLine.isEmpty {
            drawLine(ctx: ctx, text: labelLine, fontSize: size.height * 0.042, weight: 400,
                     at: CGPoint(x: textX, y: bandHeight * 0.18), maxWidth: maxWidth)
        }

        guard let composed = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, composed, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Private

    private static func thumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Smallest rect covering `bounds` with `size`'s aspect (centered crop).
    private static func aspectFill(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private static func drawLine(ctx: CGContext, text: String, fontSize: CGFloat, weight: Int,
                                 at origin: CGPoint, maxWidth: CGFloat) {
        guard !text.isEmpty else { return }
        let traits: [CFString: Any] = [kCTFontWeightTrait: (weight >= 700 ? 0.4 : 0.0) as CGFloat]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = origin
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth,
           let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, nil) {
            CTLineDraw(truncated, ctx)
        } else {
            CTLineDraw(line, ctx)
        }
    }
}

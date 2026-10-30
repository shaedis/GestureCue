import CoreGraphics
import Foundation
import ImageIO

/// Extracts embedded raster images from PDF pages, mirroring the
/// PowerPoint path: original pictures (not page renders) so imported
/// decks keep their artwork on cards.
///
/// Division of labour: Quartz (`CGPDFStreamCopyData`) applies every
/// lossless filter it understands (flate, run-length, ASCII85/hex,
/// LZW, fax, predictors) and hands over plain samples; DCT/JPX streams
/// arrive as JPEG bytes instead. This extractor validates dimensions,
/// unpacks sub-byte samples, expands indexed palettes, and encodes PNG
/// — never trusting a size or a pixel it hasn't checked.
///
/// Supported subset (everything else is skipped, never fatal):
/// - Containers: page `/XObject` image entries, including images nested
///   inside Form XObjects. Page `/Resources` inherited from `/Parent`
///   pages is honoured. Inline (`BI…EI`) images are skipped — in
///   practice these are tiny placeholders.
/// - Encodings: `DCTDecode` ships the original JPEG bytes (ImageIO
///   gate); `JPXDecode` likewise; every other Quartz-decodable stream
///   becomes PNG samples. Crypt filters and undecodable streams are
///   skipped. Predictor rows are unfiltered when Quartz leaves them
///   (PNG optimum, 10–15, 8-bit only); other predictors are skipped.
/// - Colorspaces: DeviceRGB, DeviceGray, CalRGB/CalGray (treated as
///   device RGB/gray — a deliberate approximation for extraction),
///   Indexed over those, ICCBased with 1 or 3 components, and
///   DeviceCMYK / ICCBased-4 (converted through an RGB redraw, since
///   PNG cannot hold CMYK). Lab, Separation, DeviceN, and Pattern are
///   skipped, as are 16-bit samples. Soft masks are ignored: extracted
///   art is opaque.
///
/// Security posture: image count and pixel dimensions are capped and
/// every sample buffer must match its declared size exactly (dimension
/// lies and decompression bombs degrade to skipped images); every
/// lookup is optional-chained and every failure degrades to nil, never
/// a crash.
struct PdfImageExtractor: Sendable {
    /// Resource caps (generous for real documents, fatal for bombs).
    /// Injectable for tests; production uses the defaults.
    struct Limits: Sendable {
        var maxImages = 200
        var maxPixels = 25_000_000
    }

    /// Embedded images grouped per page (index 0 = page 1), indices
    /// global 1-based in page order. Within a page, resource-name order
    /// (XObject dictionaries unordered) — deterministic, not visual.
    /// Empty when the document holds no supported images.
    static func imagesPerPage(from document: CGPDFDocument, limits: Limits = Limits()) -> [[SourceImage]] {
        let count = document.numberOfPages
        guard count > 0 else { return [] }
        var pages: [[SourceImage]] = []
        pages.reserveCapacity(count)
        var index = 0
        for number in 1 ... count {
            guard let page = document.page(at: number) else {
                pages.append([])
                continue
            }
            var found: [SourceImage] = []
            for bytes in imageBytes(on: page, limits: limits) {
                guard index < limits.maxImages else { break }
                index += 1
                found.append(SourceImage(index: index, slide: number, data: bytes))
            }
            pages.append(found)
        }
        return pages
    }

    // MARK: - Page walk

    /// Raw PNG/JPEG file bytes of every supported image on the page.
    private static func imageBytes(on page: CGPDFPage, limits: Limits) -> [Data] {
        guard let resources = resources(of: page) else { return [] }
        var streams: [(name: String, stream: CGPDFStreamRef)] = []
        collectXObjects(from: resources, into: &streams, depth: 0)
        var bytes: [Data] = []
        for entry in streams.sorted(by: { $0.name < $1.name }) {
            if let decoded = decodeImage(entry.stream, limits: limits) {
                bytes.append(decoded)
            }
        }
        return bytes
    }

    /// Page `/Resources`, walking up `/Parent` when inherited.
    private static func resources(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        while let current = node {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), resources != nil {
                return resources
            }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent), parent != nil else { return nil }
            node = parent
        }
        return nil
    }

    /// Image streams plus Form-nested image streams, depth-first.
    /// Depth-capped so reference cycles between Forms terminate.
    private static func collectXObjects(
        from resources: CGPDFDictionaryRef,
        into found: inout [(name: String, stream: CGPDFStreamRef)],
        depth: Int
    ) {
        guard depth < 8 else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        for name in entryNames(of: xobjects) {
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream else { continue }
            guard let dict = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype),
                  let subtype, String(cString: subtype) == "Image"
            else {
                // Recurse into Form XObjects for their nested images.
                if let kind = subtype.map({ String(cString: $0) }), kind == "Form" {
                    var nested: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &nested), let nested {
                        collectXObjects(from: nested, into: &found, depth: depth + 1)
                    }
                }
                continue
            }
            found.append((name, stream))
        }
    }

    // MARK: - Image decode

    /// Decodes one image XObject to PNG/JPEG file bytes, or nil when
    /// unsupported or inconsistent.
    private static func decodeImage(_ stream: CGPDFStreamRef, limits: Limits) -> Data? {
        guard let dict = CGPDFStreamGetDictionary(stream),
              let width = int(dict, "Width"), let height = int(dict, "Height"),
              let bits = int(dict, "BitsPerComponent"),
              width > 0, height > 0, bits == 1 || bits == 2 || bits == 4 || bits == 8,
              width * height <= limits.maxPixels
        else { return nil }
        guard let (bytes, format) = streamBytes(stream) else { return nil }
        if format != .raw {
            // JPEG-family bytes (DCT/JPX): ship the originals verbatim
            // when ImageIO recognises them.
            guard PptxTextExtractor.isDecodableImage(bytes) else { return nil }
            return bytes
        }
        if filterNames(dict).contains(where: { $0 == "DCTDecode" || $0 == "DCT" || $0 == "JPXDecode" }),
           PptxTextExtractor.isDecodableImage(bytes)
        {
            // Defensive: JPEG bytes mislabelled as raw still ship.
            return bytes
        }
        return samplesPNG(bytes, dict: dict, width: width, height: height, bits: bits, limits: limits)
    }

    /// Quartz-decoded samples → PNG file bytes.
    private static func samplesPNG(
        _ samples: Data, dict: CGPDFDictionaryRef,
        width: Int, height: Int, bits: Int, limits: Limits
    ) -> Data? {
        guard let model = colorModel(dict) else { return nil }
        // Samples stay proportional to the pixel cap: dimension lies
        // can neither over-allocate nor over-inflate.
        guard samples.count <= limits.maxPixels * 4 + height + 1024 else { return nil }
        let bytes = sampleBytes(samples, width: width, height: height,
                                sampleComponents: model.sampleComponents,
                                components: model.components, bits: bits,
                                predictor: predictorParms(dict),
                                palette: model.palette)
        guard let bytes else { return nil }
        return png(width: width, height: height, components: model.components,
                   space: model.space, bytes: bytes)
    }

    // MARK: - Colorspaces

    private struct ColorModel {
        var space: CGColorSpace
        var components: Int
        /// Samples per pixel pre-palette (1 for Indexed, else components).
        var sampleComponents: Int
        /// Index → sample bytes for Indexed spaces (nil otherwise).
        var palette: [UInt8]?
    }

    private static func colorModel(_ dict: CGPDFDictionaryRef) -> ColorModel? {
        if let name = name(dict, "ColorSpace") {
            return deviceModel(name)
        }
        guard let array = array(dict, "ColorSpace"), CGPDFArrayGetCount(array) > 0,
              let name = arrayName(array, 0)
        else { return nil }
        switch name {
        case "Indexed", "I":
            return indexedModel(array)
        case "ICCBased":
            return iccModel(array)
        case "CalRGB":
            return deviceModel("DeviceRGB")
        case "CalGray":
            return deviceModel("DeviceGray")
        case "CalCMYK":
            return deviceModel("DeviceCMYK")
        default:
            return nil
        }
    }

    private static func deviceModel(_ name: String) -> ColorModel? {
        switch name {
        case "DeviceRGB":
            return ColorModel(space: CGColorSpaceCreateDeviceRGB(), components: 3, sampleComponents: 3)
        case "DeviceGray", "G":
            return ColorModel(space: CGColorSpaceCreateDeviceGray(), components: 1, sampleComponents: 1)
        case "DeviceCMYK":
            // PNG cannot hold CMYK: decode then convert via RGB redraw.
            return ColorModel(space: CGColorSpaceCreateDeviceCMYK(), components: 4, sampleComponents: 4)
        default:
            return nil
        }
    }

    private static func indexedModel(_ array: CGPDFArrayRef) -> ColorModel? {
        guard CGPDFArrayGetCount(array) >= 4,
              let baseName = arrayName(array, 1),
              let base = deviceModel(baseName), base.components <= 3,
              let hival = arrayInt(array, 2), hival >= 0, hival <= 255
        else { return nil }
        let count = (hival + 1) * base.components
        if let string = arrayString(array, 3) {
            let bytes = [UInt8](string)
            guard bytes.count >= count else { return nil }
            return ColorModel(space: base.space, components: base.components, sampleComponents: 1,
                              palette: Array(bytes.prefix(count)))
        }
        var stream: CGPDFStreamRef?
        guard CGPDFArrayGetStream(array, 3, &stream),
              let stream, let bytes = decodedStreamBytes(stream)
        else { return nil }
        let raw = [UInt8](bytes)
        guard raw.count >= count else { return nil }
        return ColorModel(space: base.space, components: base.components, sampleComponents: 1,
                          palette: Array(raw.prefix(count)))
    }

    private static func iccModel(_ array: CGPDFArrayRef) -> ColorModel? {
        var stream: CGPDFStreamRef?
        guard CGPDFArrayGetCount(array) >= 2,
              CGPDFArrayGetStream(array, 1, &stream),
              let stream,
              let dict = CGPDFStreamGetDictionary(stream),
              let components = int(dict, "N"), components == 1 || components == 3 || components == 4,
              let profile = decodedStreamBytes(stream),
              let space = CGColorSpace(iccData: profile as CFData)
        else { return nil }
        return ColorModel(space: space, components: components, sampleComponents: components)
    }

    // MARK: - Sample assembly

    private struct PredictorParms {
        var predictor: Int
        var colors: Int
        var columns: Int
    }

    private static func predictorParms(_ dict: CGPDFDictionaryRef) -> PredictorParms? {
        let parms: CGPDFDictionaryRef?
        if let direct = dictionary(dict, "DecodeParms") {
            parms = direct
        } else if let array = array(dict, "DecodeParms"), CGPDFArrayGetCount(array) > 0 {
            var first: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, 0, &first) else { return nil }
            parms = first
        } else {
            return nil
        }
        guard let parms, let predictor = int(parms, "Predictor"), predictor != 1 else { return nil }
        guard predictor >= 10, predictor <= 15 else { return nil }
        return PredictorParms(predictor: predictor,
                              colors: int(parms, "Colors") ?? 0,
                              columns: int(parms, "Columns") ?? 0)
    }

    /// Inflated/run-length/raw bytes → 8-bit interleaved samples,
    /// applying predictor unfiltering, bit unpacking, and palette lookup.
    private static func sampleBytes(
        _ data: Data, width: Int, height: Int, sampleComponents: Int,
        components: Int, bits: Int, predictor: PredictorParms?, palette: [UInt8]?
    ) -> [UInt8]? {
        var bytes = [UInt8](data)
        // Predictor rows are unfiltered only when they are actually
        // there: Quartz usually strips them, but the layout decides,
        // not the assumption.
        if let predictor, bytes.count == height * (width * sampleComponents + 1) {
            let colors = predictor.colors, columns = predictor.columns
            guard bits == 8, colors == 0 || colors == sampleComponents,
                  columns == 0 || columns == width,
                  let unfiltered = unfilterPNG(bytes, width: width, height: height, components: sampleComponents)
            else { return nil }
            bytes = unfiltered
        } else if bits < 8 {
            bytes = unpackBits(bytes, width: width, height: height, components: sampleComponents, bits: bits)
        }
        // Exact size match: any shortfall or surplus means corruption.
        guard bytes.count == width * height * sampleComponents else { return nil }
        if let palette {
            var expanded: [UInt8] = []
            expanded.reserveCapacity(bytes.count * components)
            for index in bytes {
                let base = Int(index) * components
                guard base + components <= palette.count else { return nil }
                expanded.append(contentsOf: palette[base ..< base + components])
            }
            return expanded
        }
        return bytes
    }

    /// Reverses PNG-optimum predictor rows (filter byte + stride).
    private static func unfilterPNG(_ bytes: [UInt8], width: Int, height: Int, components: Int) -> [UInt8]? {
        let stride = width * components
        guard bytes.count == height * (stride + 1) else { return nil }
        var out = [UInt8](repeating: 0, count: height * stride)
        for row in 0 ..< height {
            let src = row * (stride + 1)
            let dst = row * stride
            let filter = bytes[src]
            guard filter <= 4 else { return nil }
            for col in 0 ..< stride {
                let raw = Int(bytes[src + 1 + col])
                let left = col >= components ? Int(out[dst + col - components]) : 0
                let up = row > 0 ? Int(out[dst - stride + col]) : 0
                let upperLeft = row > 0 && col >= components ? Int(out[dst - stride + col - components]) : 0
                let value: Int = switch filter {
                case 1: raw + left
                case 2: raw + up
                case 3: raw + (left + up) / 2
                case 4: raw + paeth(left, up, upperLeft)
                default: raw
                }
                out[dst + col] = UInt8(value & 0xFF)
            }
        }
        return out
    }

    private static func paeth(_ left: Int, _ up: Int, _ upperLeft: Int) -> Int {
        let p = left + up - upperLeft
        let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upperLeft)
        if pa <= pb, pa <= pc { return left }
        return pb <= pc ? up : upperLeft
    }

    /// Expands 1/2/4-bit MSB-first samples (byte-padded rows) to bytes.
    private static func unpackBits(_ bytes: [UInt8], width: Int, height: Int, components: Int, bits: Int) -> [UInt8] {
        let rowBits = width * components * bits
        let rowBytes = (rowBits + 7) / 8
        var out: [UInt8] = []
        out.reserveCapacity(width * height * components)
        let scale = 255 / ((1 << bits) - 1)
        for row in 0 ..< height {
            let base = row * rowBytes
            guard base + rowBytes <= bytes.count else { break }
            var bit = 0
            for _ in 0 ..< width * components {
                let byte = Int(bytes[base + bit / 8])
                let shift = 8 - bits - bit % 8
                out.append(UInt8(((byte >> shift) & ((1 << bits) - 1)) * scale))
                bit += bits
            }
        }
        return out
    }

    // MARK: - Stream bytes

    /// Stream bytes plus their true format. Quartz applies every
    /// lossless filter it understands and reports `.raw` regardless;
    /// JPEG-family streams report back honestly (`.jpegEncoded`/2).
    private static func streamBytes(_ stream: CGPDFStreamRef) -> (Data, CGPDFDataFormat)? {
        var format: CGPDFDataFormat = .raw
        guard let bytes = CGPDFStreamCopyData(stream, &format) else { return nil }
        return (bytes as Data, format)
    }

    /// Quartz-decoded bytes for auxiliary streams (ICC profiles, index
    /// palettes). JPEG-family formats never occur here; anything but
    /// `.raw` is refused.
    private static func decodedStreamBytes(_ stream: CGPDFStreamRef) -> Data? {
        guard let (bytes, format) = streamBytes(stream),
              format == .raw, bytes.count <= 4_000_000
        else { return nil }
        return bytes
    }

    private static func filterNames(_ dict: CGPDFDictionaryRef) -> [String] {
        if let single = name(dict, "Filter") {
            return [single]
        }
        guard let array = array(dict, "Filter") else { return [] }
        var names: [String] = []
        for index in 0 ..< CGPDFArrayGetCount(array) {
            if let filter = arrayName(array, index) {
                names.append(filter)
            }
        }
        return names
    }

    // MARK: - PNG encode

    private static func png(width: Int, height: Int, components: Int, space: CGColorSpace, bytes: [UInt8]) -> Data? {
        let bitsPerPixel = components * 8
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: bitsPerPixel,
                  bytesPerRow: width * components,
                  space: space, bitmapInfo: CGBitmapInfo(),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        let rgb = components == 4 ? redrawRGB(image, width: width, height: height) : image
        guard let rgb else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, rgb, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Converts CMYK art to RGB (PNG cannot hold CMYK).
    private static func redrawRGB(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - CGPDF helpers

    private static func entryNames(of dict: CGPDFDictionaryRef) -> [String] {
        let box = PdfDictionaryBox()
        let context = Unmanaged.passUnretained(box).toOpaque()
        CGPDFDictionaryApplyFunction(dict, { key, _, info in
            guard let info else { return }
            Unmanaged<PdfDictionaryBox>.fromOpaque(info).takeUnretainedValue().items.append(String(cString: key))
        }, context)
        return box.items
    }

    private static func int(_ dict: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, key, &value) else { return nil }
        return Int(value)
    }

    private static func name(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func array(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, key, &value) else { return nil }
        return value
    }

    private static func dictionary(_ dict: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, key, &value) else { return nil }
        return value
    }

    private static func arrayName(_ array: CGPDFArrayRef, _ index: Int) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, index, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func arrayInt(_ array: CGPDFArrayRef, _ index: Int) -> Int? {
        var value: CGPDFInteger = 0
        guard CGPDFArrayGetInteger(array, index, &value) else { return nil }
        return Int(value)
    }

    private static func arrayString(_ array: CGPDFArrayRef, _ index: Int) -> Data? {
        var value: CGPDFStringRef?
        guard CGPDFArrayGetString(array, index, &value), let value,
              let bytes = CGPDFStringGetBytePtr(value)
        else { return nil }
        return Data(bytes: bytes, count: CGPDFStringGetLength(value))
    }
}

/// C callback trampoline context. (Kept at file scope: C function
/// pointers cannot close over locals.)
private final class PdfDictionaryBox {
    var items: [String] = []
}

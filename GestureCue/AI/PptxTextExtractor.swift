import Compression
import Foundation
import ImageIO

/// Minimal .pptx text extractor with no third-party dependencies: reads
/// slide XML straight from the zip (stored + deflated entries) and
/// collects text runs in slide-number order. Bullets, tables, and text
/// boxes all surface as `a:t` runs, so one rule covers them; notes,
/// masters, layouts, and media are ignored. Anything malformed returns
/// nil and the caller reports the file unreadable.
///
/// Security posture: entry counts, per-entry and total decompressed
/// sizes are capped (zip bombs, slides + rels + media share one
/// budget); entry names are only ever matched against known paths
/// (never written, so `../` traversal is meaningless); XML containing
/// a DOCTYPE is rejected outright (no entity expansion attacks);
/// every read is bounds-checked and every failure degrades to nil,
/// never a crash.
struct PptxTextExtractor: Sendable {
    /// Resource caps (generous for real decks, fatal for bombs).
    /// Injectable for tests; production uses the defaults.
    struct Limits: Sendable {
        var maxEntries = 4096
        var maxSlides = 1000
        var maxTotalBytes = 100_000_000
        var maxEntryBytes = 50_000_000
    }

    /// Decodable image formats accepted from `ppt/media/`.
    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "webp"]

    /// Slide numbers + texts in slide-number order (slides with
    /// neither text nor images skipped, true numbering kept). Image-only
    /// slides appear with empty text; prefer `slidesAndImages` when the
    /// caller's images matter. Nil when `data` is not a readable zip,
    /// holds no slides, or breaks any resource cap.
    static func slides(from data: Data, limits: Limits = Limits()) -> [(number: Int, text: String)]? {
        slidesAndImages(from: data, limits: limits)?.slides.map { (number: $0.number, text: $0.text) }
    }

    /// Slides plus the original images embedded in them. Each slide
    /// carries its images' global indices (1-based, slide order);
    /// identical media files referenced twice share one index.
    /// Text-empty slides survive only when they carry images (the
    /// importer marks them as having no extractable text).
    static func slidesAndImages(
        from data: Data, limits: Limits = Limits()
    ) -> (slides: [(number: Int, text: String, images: [Int])], images: [SourceImage])? {
        guard let entries = ZipReader.entries(in: data, maxEntries: limits.maxEntries) else { return nil }
        let byName = Dictionary(entries.map { ($0.name, $0) }) { first, _ in first }
        let slideNumbers = entries.compactMap { slideNumber(of: $0.name) }.sorted()
        guard slideNumbers.count <= limits.maxSlides else { return nil }
        var budget = limits.maxTotalBytes
        // Declared sizes gate the spend before inflating: over budget
        // rejects the file, while a corrupt entry only skips its slide.
        func spend(_ entry: ZipReader.Entry) -> Bool {
            budget -= entry.uncompressedSize
            return budget >= 0
        }
        func take(_ entry: ZipReader.Entry) -> Data? {
            ZipReader.contents(of: entry, in: data, maxBytes: limits.maxEntryBytes)
        }
        var slides: [(number: Int, text: String, images: [Int])] = []
        var images: [SourceImage] = []
        var mediaIndex: [String: Int] = [:]
        for number in slideNumbers {
            guard let entry = byName["ppt/slides/slide\(number).xml"] else { continue }
            guard spend(entry) else { return nil }
            guard let xml = take(entry),
                  let content = SlideXML.content(from: xml)
            else { continue }
            let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let rels: [String: String]
            if let relsEntry = byName["ppt/slides/_rels/slide\(number).xml.rels"] {
                guard spend(relsEntry) else { return nil }
                rels = take(relsEntry).map { SlideRels.map(from: $0) } ?? [:]
            } else {
                rels = [:]
            }
            var markers: [Int] = []
            for embed in content.embeds {
                guard let target = rels[embed] else { continue }
                let path = resolve(target: target, base: "ppt/slides")
                guard path.hasPrefix("ppt/media/"),
                      imageExtensions.contains((path as NSString).pathExtension.lowercased()),
                      let mediaEntry = byName[path]
                else { continue }
                if let known = mediaIndex[path] {
                    if !markers.contains(known) {
                        markers.append(known)
                    }
                    continue
                }
                guard spend(mediaEntry) else { return nil }
                guard let bytes = take(mediaEntry), isDecodableImage(bytes) else { continue }
                images.append(SourceImage(index: images.count + 1, slide: number, data: bytes))
                mediaIndex[path] = images.count
                markers.append(images.count)
            }
            if text.isEmpty, markers.isEmpty {
                continue
            }
            slides.append((number: number, text: text, images: markers))
        }
        guard !slides.isEmpty else { return nil }
        return (slides, images)
    }

    private static func slideNumber(of name: String) -> Int? {
        // "ppt/slides/slide12.xml" (masters/layouts live elsewhere).
        guard name.hasPrefix("ppt/slides/slide"), name.hasSuffix(".xml") else { return nil }
        let start = name.index(name.startIndex, offsetBy: "ppt/slides/slide".count)
        let end = name.index(name.endIndex, offsetBy: -".xml".count)
        guard start < end else { return nil }
        return Int(name[start ..< end])
    }

    /// Resolves a rels target (e.g. "../media/image1.png") against its
    /// base directory. The caller only accepts results under
    /// `ppt/media/`, so escaping or external targets never resolve.
    private static func resolve(target: String, base: String) -> String {
        var parts = base.split(separator: "/").map(String.init)
        let cleaned = target.hasPrefix("/") ? String(target.dropFirst()) : target
        for segment in cleaned.split(separator: "/") {
            if segment == ".." {
                if !parts.isEmpty {
                    parts.removeLast()
                }
            } else if segment != "." {
                parts.append(String(segment))
            }
        }
        return parts.joined(separator: "/")
    }

    /// True when ImageIO recognises the bytes — the same decoder the
    /// compositor and review UI use, so accepted bytes always render.
    /// Shared with the PDF extractor for its shipped-originals gate.
    static func isDecodableImage(_ bytes: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

// MARK: - Slide XML (a:t runs, a:p breaks, a:blip embed order)

private enum SlideXML {
    /// Text plus referenced image embed ids in document order.
    /// No DOCTYPE, no entities: real slides never declare any, and
    /// this rules out entity-expansion (billion laughs) payloads.
    /// External entities stay off (XMLParser default).
    static func content(from xml: Data) -> (text: String, embeds: [String])? {
        if xml.range(of: Data("<!DOCTYPE".utf8)) != nil {
            return nil
        }
        let parser = XMLParser(data: xml)
        let delegate = Collector()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return delegate.finished()
    }

    private final class Collector: NSObject, XMLParserDelegate {
        private var runs: [String] = []
        private var current = ""
        private var inText = false
        private var embeds: [String] = []

        func parser(
            _: XMLParser, didStartElement name: String, namespaceURI _: String?,
            qualifiedName _: String?, attributes: [String: String] = [:]
        ) {
            switch local(name) {
            case "t":
                inText = true
            case "blip":
                if let id = attributes.first(where: { local($0.key) == "embed" })?.value,
                   !embeds.contains(id)
                {
                    embeds.append(id)
                }
            default:
                break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            if inText {
                current += string
            }
        }

        func parser(
            _: XMLParser, didEndElement name: String, namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            switch local(name) {
            case "t":
                inText = false
            case "p":
                runs.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            default:
                break
            }
        }

        func finished() -> (text: String, embeds: [String]) {
            let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                runs.append(tail)
            }
            return (runs.filter { !$0.isEmpty }.joined(separator: "\n"), embeds)
        }

        private func local(_ name: String) -> String {
            String(name.split(separator: ":").last ?? Substring(name))
        }
    }
}

// MARK: - Slide rels (embed id → media target)

private enum SlideRels {
    /// Embed-id → relationship target for image parts. Anything
    /// unparseable yields no mappings (images simply don't resolve).
    static func map(from xml: Data) -> [String: String] {
        guard xml.range(of: Data("<!DOCTYPE".utf8)) == nil else { return [:] }
        let parser = XMLParser(data: xml)
        let delegate = Collector()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return [:] }
        return delegate.mapping
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var mapping: [String: String] = [:]

        func parser(
            _: XMLParser, didStartElement name: String, namespaceURI _: String?,
            qualifiedName _: String?, attributes: [String: String] = [:]
        ) {
            guard name == "Relationship",
                  attributes["Type"]?.hasSuffix("/image") == true,
                  let id = attributes["Id"],
                  let target = attributes["Target"]
            else { return }
            mapping[id] = target
        }
    }
}

// MARK: - Minimal zip reader (stored + deflated)

private enum ZipReader {
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    /// Central-directory entries, or nil when `data` is not a zip.
    static func entries(in data: Data, maxEntries: Int) -> [Entry]? {
        guard let directoryOffset = endOfCentralDirectory(in: data) else { return nil }
        let count = Int(data.u16(at: directoryOffset + 10))
        guard count <= maxEntries else { return nil }
        let size = Int(data.u32(at: directoryOffset + 12))
        let start = Int(data.u32(at: directoryOffset + 16))
        guard count > 0, size > 0, start >= 0, start + size <= data.count else { return nil }
        var entries: [Entry] = []
        var offset = start
        for _ in 0 ..< count {
            guard data.u32(at: offset) == 0x02014B50, offset + 46 <= data.count else { return nil }
            let nameLength = Int(data.u16(at: offset + 28))
            let extraLength = Int(data.u16(at: offset + 30))
            let commentLength = Int(data.u16(at: offset + 32))
            let nameEnd = offset + 46 + nameLength
            guard nameEnd <= data.count else { return nil }
            let name = String(data: data[offset + 46 ..< nameEnd], encoding: .utf8) ?? ""
            entries.append(Entry(
                name: name,
                method: data.u16(at: offset + 10),
                compressedSize: Int(data.u32(at: offset + 20)),
                uncompressedSize: Int(data.u32(at: offset + 24)),
                localHeaderOffset: Int(data.u32(at: offset + 42))
            ))
            offset = nameEnd + extraLength + commentLength
        }
        return entries
    }

    /// Decompressed entry bytes, or nil on any inconsistency.
    static func contents(of entry: Entry, in data: Data, maxBytes: Int) -> Data? {
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count,
              data.u32(at: header) == 0x04034B50
        else { return nil }
        let start = header + 30 + Int(data.u16(at: header + 26)) + Int(data.u16(at: header + 28))
        guard start >= 0, start + entry.compressedSize <= data.count else { return nil }
        let raw = data[start ..< start + entry.compressedSize]
        switch entry.method {
        case 0:
            guard raw.count <= maxBytes else { return nil }
            return Data(raw)
        case 8:
            return inflate(raw, expectedSize: entry.uncompressedSize, maxBytes: maxBytes)
        default:
            return nil
        }
    }

    /// Offset of the end-of-central-directory record, scanning back over
    /// the (up to 64 KiB) file comment. Zip64 is rejected (never used
    /// for slide decks).
    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let floor = max(0, data.count - 66_000)
        var offset = data.count - 22
        while offset >= floor {
            if data.u32(at: offset) == 0x06054B50,
               data.u16(at: offset + 10) != 0xFFFF,
               data.u32(at: offset + 12) != 0xFFFF_FFFF,
               data.u32(at: offset + 16) != 0xFFFF_FFFF
            {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    /// Raw deflate via COMPRESSION_ZLIB: despite the name, Apple's
    /// one-shot buffer API decodes raw deflate streams (its own encoder
    /// emits no zlib header either — verified by round-trip). A real
    /// failure returns nil and the file reports unreadable, never
    /// corrupt text.
    private static func inflate(_ raw: Data, expectedSize: Int, maxBytes: Int) -> Data? {
        guard expectedSize >= 0, expectedSize <= maxBytes, !raw.isEmpty else { return nil }
        if expectedSize == 0 {
            return Data()
        }
        var output = Data(count: expectedSize)
        let decoded = output.withUnsafeMutableBytes { outputPtr in
            raw.withUnsafeBytes { inputPtr in
                compression_decode_buffer(
                    outputPtr.baseAddress!, expectedSize,
                    inputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else { return nil }
        return output
    }
}

private extension Data {
    func u16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}

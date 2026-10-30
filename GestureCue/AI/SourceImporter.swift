import CoreGraphics
import Foundation
import PDFKit

/// Extracts plain-text source material for lesson generation: pasted text,
/// PDF / PowerPoint / Markdown / TXT files, Jupyter notebooks (parsed as
/// data, code is never executed), and existing catalog decks. Pure value
/// type; all errors are user-presentable.
struct SourceImporter: Sendable {
    /// Sources longer than this are truncated (flagged, never silent) to
    /// bound request size and cost.
    static let maxCharacters = 20_000

    /// Finished presentations (PDF/PowerPoint) get faithful treatment:
    /// the model splits and fits the author's content instead of
    /// inventing new lessons from raw material.
    enum Kind: String, Sendable, Equatable {
        case freeform
        case presentation
    }

    struct Source: Sendable, Equatable {
        var title: String
        var text: String
        var truncated: Bool
        var kind: Kind = .freeform
        /// Original images (presentation imports), referenced from the
        /// text by `[Image N]` markers so plans can reattach them to cards.
        var images: [SourceImage] = []
    }

    enum ImportError: Error, Sendable, Equatable {
        case unsupportedType(String)
        case unreadable(String)
        case empty(String)
    }

    func importFile(at url: URL) throws -> Source {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return try pdf(at: url)
        case "pptx", "ppsx":
            return try powerPoint(at: url)
        case "ppt":
            throw ImportError.unsupportedType(".ppt (convert to .pptx first)")
        case "md", "markdown", "txt", "text":
            return try text(at: url)
        case "ipynb":
            return try notebook(at: url)
        default:
            throw ImportError.unsupportedType(url.pathExtension.isEmpty ? "unknown type" : ".\(url.pathExtension)")
        }
    }

    func importText(_ text: String, title: String = "Pasted text") throws -> Source {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty(title) }
        return cap(title: title, text: trimmed)
    }

    /// Reuses a catalog deck as source: titles, messages, and details joined
    /// in card order.
    func importPresentation(_ deck: Presentation) throws -> Source {
        let parts = deck.cards.flatMap { card -> [String] in
            var lines = ["## \(card.title)", card.message]
            if let detail = card.detail, !detail.isEmpty {
                lines.append(detail)
            }
            return lines
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportError.empty(deck.name) }
        return cap(title: deck.name, text: text)
    }

    // MARK: - Private

    private func cap(title: String, text: String, kind: Kind = .freeform, images: [SourceImage] = []) -> Source {
        guard text.count > Self.maxCharacters else {
            return Source(title: title, text: text, truncated: false, kind: kind, images: images)
        }
        let end = text.index(text.startIndex, offsetBy: Self.maxCharacters)
        return Source(title: title, text: String(text[..<end]) + "\n\n[…truncated…]", truncated: true, kind: kind, images: images)
    }

    private func text(at url: URL) throws -> Source {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        return try importText(text, title: url.deletingPathExtension().lastPathComponent)
    }

    private func pdf(at url: URL) throws -> Source {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        // Original embedded pictures ride along like PowerPoint media;
        // image-only pages survive with a text placeholder.
        let imagePages: [[SourceImage]]
        if let cgDocument = CGPDFDocument(url as CFURL),
           !cgDocument.isEncrypted || cgDocument.isUnlocked
        {
            imagePages = PdfImageExtractor.imagesPerPage(from: cgDocument)
        } else {
            imagePages = []
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            let body = document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let markers = index < imagePages.count ? imagePages[index] : []
            if body.isEmpty, markers.isEmpty {
                continue
            }
            var part = "## Page \(index + 1)\n\(body.isEmpty ? "(no extractable text)" : body)"
            if !markers.isEmpty {
                part += "\n" + markers.map { "[Image \($0.index)]" }.joined(separator: " ")
            }
            pages.append(part)
        }
        guard !pages.isEmpty else { throw ImportError.empty(url.lastPathComponent) }
        return cap(
            title: url.deletingPathExtension().lastPathComponent,
            text: pages.joined(separator: "\n\n"),
            kind: .presentation,
            images: imagePages.flatMap { $0 }
        )
    }

    private func powerPoint(at url: URL) throws -> Source {
        guard let data = try? Data(contentsOf: url),
              let deck = PptxTextExtractor.slidesAndImages(from: data)
        else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        var parts: [String] = []
        for slide in deck.slides {
            let body = slide.text.isEmpty ? "(no extractable text)" : slide.text
            var part = "## Slide \(slide.number)\n\(body)"
            if !slide.images.isEmpty {
                part += "\n" + slide.images.map { "[Image \($0)]" }.joined(separator: " ")
            }
            parts.append(part)
        }
        guard !parts.isEmpty else { throw ImportError.empty(url.lastPathComponent) }
        return cap(
            title: url.deletingPathExtension().lastPathComponent,
            text: parts.joined(separator: "\n\n"),
            kind: .presentation,
            images: deck.images
        )
    }

    /// Minimal nbformat reader: concatenates markdown and code cell sources
    /// as text. Decoding only — nothing is ever executed.
    private func notebook(at url: URL) throws -> Source {
        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        struct Cell: Decodable {
            var cellType: String
            var source: SourceText
            enum CodingKeys: String, CodingKey {
                case cellType = "cell_type"
                case source
            }
        }
        struct SourceText: Decodable {
            var text: String
            init(from decoder: Decoder) throws {
                let box = try decoder.singleValueContainer()
                if let string = try? box.decode(String.self) {
                    text = string
                } else {
                    text = (try box.decode([String].self)).joined()
                }
            }
        }
        struct Notebook: Decodable {
            var cells: [Cell]
        }
        guard let notebook = try? JSONDecoder().decode(Notebook.self, from: data) else {
            throw ImportError.unreadable(url.lastPathComponent)
        }
        var parts: [String] = []
        for (index, cell) in notebook.cells.enumerated() {
            let body = cell.source.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, cell.cellType == "markdown" || cell.cellType == "code" else { continue }
            parts.append("## Cell \(index + 1) (\(cell.cellType))\n\(body)")
        }
        guard !parts.isEmpty else { throw ImportError.empty(url.lastPathComponent) }
        return cap(title: url.deletingPathExtension().lastPathComponent, text: parts.joined(separator: "\n\n"))
    }
}

extension SourceImporter.ImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedType(detail):
            "Unsupported file type (\(detail)). Use PDF, PowerPoint (.pptx), Markdown, TXT, or Jupyter notebooks."
        case let .unreadable(name):
            "Could not read “\(name)”."
        case let .empty(name):
            "“\(name)” contains no usable text."
        }
    }
}

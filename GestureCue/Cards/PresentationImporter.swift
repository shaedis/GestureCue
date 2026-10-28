import AppKit
import Foundation
import PDFKit

/// Import failures with user-readable messages.
enum PresentationImportError: Error, Equatable {
    case unreadableFile
    case noPages
    case libreOfficeMissing
    case conversionFailed(String)

    var displayMessage: String {
        switch self {
        case .unreadableFile:
            "That file could not be read."
        case .noPages:
            "No slides or pages were found in that file."
        case .libreOfficeMissing:
            "PowerPoint import needs LibreOffice (free from libreoffice.org). Or export the deck as PDF and import that instead."
        case .conversionFailed(let detail):
            "PowerPoint conversion failed (\(detail))."
        }
    }
}

/// Imports slide decks from files into the presentation catalog:
/// - PDF renders natively with PDFKit (one card per page).
/// - PowerPoint (.pptx/.ppt) converts to PDF first with LibreOffice
///   (`soffice --headless --convert-to pdf`) when installed.
/// Slides become picture cards (title "Slide N" + rendered image); builds
/// a `Presentation` the caller adds to the library.
struct PresentationImporter: Sendable {
    /// Rendered slide width in pixels (aspect preserved).
    var slideWidth: CGFloat = 1600
    var jpegQuality: CGFloat = 0.85

    static var libreOfficeSearchPaths: [String] {
        [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice").path,
        ]
    }

    /// First executable `soffice` in `paths` (injected for tests).
    static func sofficeURL(searching paths: [String] = libreOfficeSearchPaths) -> URL? {
        paths.map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    func importPDF(at url: URL, name: String? = nil) throws -> Presentation {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw PresentationImportError.unreadableFile
        }
        var cards: [PresentationCard] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let size = page.bounds(for: .mediaBox).size
            let scale = slideWidth / max(size.width, 1)
            let thumbnail = page.thumbnail(
                of: CGSize(width: slideWidth, height: size.height * scale), for: .mediaBox
            )
            guard let data = Self.jpegData(thumbnail, quality: jpegQuality) else { continue }
            cards.append(PresentationCard(title: "Slide \(index + 1)", message: "", imageData: data))
        }
        guard !cards.isEmpty else { throw PresentationImportError.noPages }
        return Presentation(name: name ?? url.deletingPathExtension().lastPathComponent, cards: cards)
    }

    /// `sofficeSearchPaths` overrides the install search (nil = defaults).
    func importPowerPoint(at url: URL, name: String? = nil, sofficeSearchPaths: [String]? = nil) async throws -> Presentation {
        let paths = sofficeSearchPaths ?? Self.libreOfficeSearchPaths
        guard let soffice = Self.sofficeURL(searching: paths) else {
            throw PresentationImportError.libreOfficeMissing
        }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let status = try await Self.run(
            soffice,
            arguments: ["--headless", "--convert-to", "pdf", "--outdir", workDir.path, url.path]
        )
        guard status == 0 else {
            throw PresentationImportError.conversionFailed("soffice exited with status \(status)")
        }
        let pdfURL = workDir
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("pdf")
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw PresentationImportError.conversionFailed("no PDF produced")
        }
        return try importPDF(at: pdfURL, name: name ?? url.deletingPathExtension().lastPathComponent)
    }

    /// Runs a tool to completion on a background thread, returning its exit
    /// status. No timeout: `soffice --convert-to` finishes in seconds for
    /// typical decks, and killing a conversion mid-write gains nothing.
    static func run(_ executable: URL, arguments: [String]) async throws -> Int32 {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    static func jpegData(_ image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { return nil }
        return jpeg
    }
}

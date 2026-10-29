import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct DocumentContext {
    static func load(_ url: URL) throws -> ContextAttachment {
        let bytes = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard bytes <= 10_000_000 else { throw DocumentError("Choose a file smaller than 10 MB.") }
        let ext = url.pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw DocumentError("This image could not be decoded.") }
            guard png.count <= 10_000_000 else { throw DocumentError("The decoded image exceeds 10 MB.") }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kaddo/Attachments")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent("\(UUID().uuidString).png")
            try png.write(to: destination, options: .atomic)
            return ContextAttachment(title: url.lastPathComponent, text: "User-selected image: \(url.lastPathComponent)", imagePath: destination.path)
        }
        let text: String
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw DocumentError("The PDF is unreadable or locked.") }
            text = pdf.string ?? ""
        case "rtf":
            text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        default:
            let data = try Data(contentsOf: url)
            guard !data.contains(0), let decoded = String(data: data, encoding: .utf8) else { throw DocumentError("Choose UTF-8 text, a PDF, an RTF document, or an image.") }
            text = decoded
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentError("No selectable text was found. For a scanned PDF, attach page images instead.") }
        let truncated = text.count > 100_000
        return ContextAttachment(title: url.lastPathComponent, text: String(text.prefix(100_000)) + (truncated ? "\n[Document truncated to 100,000 characters]" : ""))
    }
}
private struct DocumentError: LocalizedError {
    var text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

import AppKit
import UniformTypeIdentifiers
import ClearlineCore

extension AppState {
    func importDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, .rtf, UTType(filenameExtension: "docx")!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20_000_000 else { throw FormatError.tooLarge }
            let ext = url.pathExtension.lowercased()
            if ["rtf", "docx"].contains(ext) {
                guard confirmConversion(ext.uppercased()) else { return }
                let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
                let attributed = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
                let rich = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                newDocument(text: attributed.string, title: url.deletingPathExtension().lastPathComponent, format: .rtf, richText: rich)
            } else {
                guard let text = String(data: data, encoding: .utf8) else { throw FormatError.encoding }
                newDocument(text: text, title: url.deletingPathExtension().lastPathComponent, format: ext == "md" || ext == "markdown" ? .md : .txt)
            }
        } catch { self.error = error.localizedDescription }
    }
    func exportDocument() {
        guard let document = current else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.title + "." + document.format.rawValue
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, .rtf, UTType(filenameExtension: "docx")!]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let ext = url.pathExtension.lowercased()
            if ["rtf", "docx"].contains(ext) {
                if ext == "docx" && !confirmConversion("DOCX") { return }
                let attributed = document.richText.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) } ?? NSAttributedString(string: document.text)
                let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: ext == "rtf" ? NSAttributedString.DocumentType.rtf : .officeOpenXML])
                try data.write(to: url, options: .atomic)
            } else {
                if document.format == .rtf && !confirmConversion("plain text") { return }
                try document.text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func confirmConversion(_ format: String) -> Bool {
        let alert = NSAlert(); alert.messageText = "Convert \(format)?"
        alert.informativeText = "Clearline preserves text and basic attributed formatting when macOS supports it. Advanced layout, comments, tracked changes, tables, images, and attachments may be lost. Markdown remains literal source text, not rendered formatting. Keep the original file."
        alert.addButton(withTitle: "Convert"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
enum FormatError: String, Error, LocalizedError {
    case tooLarge = "This file exceeds the 20 MB import limit."
    case encoding = "This file is not UTF-8 text. Convert its encoding before importing."
    var errorDescription: String? { rawValue }
}

import AppKit
import SwiftUI

/// A local, selectable rendering. The source editor owns all document mutations.
struct MarkdownPreview: NSViewRepresentable {
    let text: String
    let textSize: Double
    let documentID: UUID

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 38, height: 20)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Markdown preview")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.text != text || coordinator.textSize != textSize || coordinator.documentID != documentID else { return }
        let switching = coordinator.documentID != documentID
        view.textStorage?.setAttributedString(MarkdownRenderer.render(text, textSize: textSize))
        if switching { view.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
        coordinator.text = text
        coordinator.textSize = textSize
        coordinator.documentID = documentID
    }
    final class Coordinator {
        var text: String?
        var textSize: Double?
        var documentID: UUID?
    }
}

@MainActor
enum MarkdownRenderer {
    static func render(_ source: String, textSize: Double) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: textSize), .foregroundColor: NSColor.labelColor]
        guard let markdown = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let output = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousRow: Int?
        var seenListItems = Set<Int>()
        for run in markdown.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let row = components.first { component in
                switch component.kind { case .tableRow, .tableHeaderRow: return true; default: return false }
            }?.identity
            let newBlock = block != previousBlock
            if newBlock && output.length > 0 {
                // Foundation strips block separators; restore them without splitting inline runs.
                let separator = row != nil && row == previousRow ? "\t" : "\n"
                output.append(NSAttributedString(string: separator, attributes: base))
            }
            var attributes = base
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 14
            var size = textSize
            var bold = false
            var code = false
            var quoteDepth = 0
            var listDepth = 0
            var listItem: PresentationIntent.IntentType?
            var ordered = false
            for component in components {
                switch component.kind {
                case .header(let level):
                    size = textSize * [1.8, 1.5, 1.25, 1.1, 1, 1][min(max(level - 1, 0), 5)]
                    bold = true
                    paragraph.paragraphSpacingBefore = 10
                case .codeBlock:
                    code = true
                    paragraph.paragraphSpacing = 0
                case .blockQuote: quoteDepth += 1
                case .listItem: if listItem == nil { listItem = component }
                case .orderedList, .unorderedList:
                    if listDepth == 0 { ordered = component.kind == .orderedList }
                    listDepth += 1
                case .tableHeaderRow: bold = true
                default: break
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            bold = bold || inline.contains(.stronglyEmphasized)
            code = code || inline.contains(.code)
            var font = code ? NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: bold ? .semibold : .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attributes[.font] = font
            if code { attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if quoteDepth > 0 { attributes[.foregroundColor] = NSColor.secondaryLabelColor }
            let indent = CGFloat(listDepth + quoteDepth) * 24
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = indent
            if listDepth > 0 { paragraph.paragraphSpacing = 6 }
            if row != nil { paragraph.tabStops = (1...12).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 150) } }
            var prefix = ""
            if newBlock, let item = listItem, seenListItems.insert(item.identity).inserted, case .listItem(let ordinal) = item.kind {
                prefix = ordered ? "\(ordinal).\t" : "•\t"
                paragraph.firstLineHeadIndent = max(0, indent - 24)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            attributes[.paragraphStyle] = paragraph
            // Only explicit web/mail links become interactive. No remote content is fetched.
            if let link = run.link, let scheme = link.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: prefix + String(markdown[run.range].characters), attributes: attributes))
            previousBlock = block
            previousRow = row
        }
        return output
    }
}

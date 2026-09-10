import AppKit
import SwiftUI
import ClearlineCore

/// A local, selectable rendering. The source editor owns all document mutations.
struct MarkdownPreview: NSViewRepresentable {
    let text: String
    let textSize: Double
    let documentID: UUID
    var zoom: Double = 1

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = WorkspaceScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 38, height: 20)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        if coordinator.text != text || coordinator.textSize != textSize {
            let columns = MarkdownTable.blocks(in: text).map { $0.table.header.count }.max() ?? 0
            (scroll as? WorkspaceScrollView)?.minimumDocumentWidth = columns > 0 ? CGFloat(columns) * CGFloat(textSize) * 7 + 76 : 0
        }
        WorkspaceZoom.apply(zoom, to: scroll)
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
        // Foundation omits empty cell runs. Give them a zero-width layout placeholder
        // in the rendering input only, so blank headers, cells and trailing rows survive.
        let input = NSMutableString(string: source)
        for block in MarkdownTable.blocks(in: source).reversed() {
            var table = block.table
            guard !block.hasExtraCells else { continue }
            table.header = table.header.map { $0.isEmpty ? "\u{200B}" : $0 }
            table.rows = table.rows.map { $0.map { $0.isEmpty ? "\u{200B}" : $0 } }
            input.replaceCharacters(in: block.range, with: table.markdown)
        }
        guard let markdown = try? AttributedString(markdown: input as String, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let output = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousRow: Int?
        var seenListItems = Set<Int>()
        var tables: [Int: NSTextTable] = [:]
        var tableCells: [Int: NSTextTableBlock] = [:]
        var previousAttributes = base
        for run in markdown.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let row = components.first { component in
                switch component.kind { case .tableRow, .tableHeaderRow: return true; default: return false }
            }?.identity
            let newBlock = block != previousBlock
            if newBlock && previousBlock != nil {
                // Each native table cell is a paragraph, including empty cells.
                output.append(NSAttributedString(string: "\n", attributes: previousRow != nil ? previousAttributes : base))
            }
            var attributes = base
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            paragraph.paragraphSpacing = 14
            if previousRow != nil && row == nil && newBlock { paragraph.paragraphSpacingBefore = 12 }
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
            if row != nil {
                var rowIndex = 0, columnIndex = 0
                for component in components {
                    if case .tableRow(let index) = component.kind { rowIndex = index }
                    if case .tableCell(let index) = component.kind { columnIndex = index }
                }
                for component in components {
                    guard case .table(let columns) = component.kind else { continue }
                    let table: NSTextTable
                    if let existing = tables[component.identity] { table = existing }
                    else {
                        table = NSTextTable(); table.numberOfColumns = columns.count
                        table.layoutAlgorithm = .fixedLayoutAlgorithm
                        table.collapsesBorders = true; table.hidesEmptyCells = false
                        table.setContentWidth(100, type: .percentageValueType)
                        tables[component.identity] = table
                    }
                    let cell = tableCells[block ?? -1] ?? NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: columnIndex, columnSpan: 1)
                    tableCells[block ?? -1] = cell
                    cell.setContentWidth(100 / CGFloat(max(1, columns.count)), type: .percentageValueType)
                    cell.setWidth(8, type: .absoluteValueType, for: .padding)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(.separatorColor)
                    cell.verticalAlignment = .topAlignment
                    if rowIndex == 0 { cell.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10) }
                    else if rowIndex.isMultiple(of: 2) { cell.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.05) }
                    paragraph.textBlocks = [cell]
                    paragraph.paragraphSpacing = 0; paragraph.lineSpacing = 3
                    paragraph.headIndent = 0; paragraph.firstLineHeadIndent = 0
                    if columns.indices.contains(columnIndex) {
                        switch columns[columnIndex].alignment {
                        case .left: paragraph.alignment = .left
                        case .center: paragraph.alignment = .center
                        case .right: paragraph.alignment = .right
                        @unknown default: paragraph.alignment = .left
                        }
                    }
                }
            }
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
            previousAttributes = attributes
        }
        if previousRow != nil { output.append(NSAttributedString(string: "\n", attributes: previousAttributes)) }
        return output
    }
}

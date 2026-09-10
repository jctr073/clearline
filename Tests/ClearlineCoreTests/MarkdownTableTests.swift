import XCTest
import AppKit
import SwiftUI
@testable import ClearlineCore
@testable import ClearlineApp

final class MarkdownTableTests: XCTestCase {
    func testSourceRangesEscapesAlignmentAndRaggedRows() throws {
        let table = "| Name | Details | Cost |\r\n| --- | :---: | ---: |\r\n| café 😀 | **a** \\| b | 10 |\r\n| x |"
        let source = "Before 😀\r\n\r\n" + table + "\r\n\r\nAfter"
        let block = try XCTUnwrap(MarkdownTable.blocks(in: source).first)
        XCTAssertEqual((source as NSString).substring(with: block.range), table)
        XCTAssertEqual(block.table.alignments, [.left, .center, .right])
        XCTAssertEqual(block.table.rows, [["café 😀", "**a** \\| b", "10"], ["x", "", ""]])
        XCTAssertEqual(MarkdownTable.blocks(in: block.table.markdown).first?.table, block.table)
        XCTAssertFalse(block.hasExtraCells)
    }
    func testPipesBackslashesAndEmptyCells() throws {
        let table = MarkdownTable(header: ["", "b"], rows: [["a|b", "\\\\|"], ["", ""]], alignments: [.left, .right])
        let parsed = try XCTUnwrap(MarkdownTable.blocks(in: table.markdown).first?.table)
        XCTAssertEqual(parsed.header, ["", "b"])
        XCTAssertEqual(parsed.rows, [["a\\|b", "\\\\\\|"], ["", ""]])
        XCTAssertEqual(parsed.markdown, table.markdown)
    }
    func testFencesContainersInvalidHeadersAndOverflow() {
        let table = "| a | b |\n| --- | --- |\n| c | d |"
        XCTAssertTrue(MarkdownTable.blocks(in: "```md\n" + table + "\n```").isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: "~~~\n" + table + "\n~~~").isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: "<div>\n" + table + "\n</div>").isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: "<!--\n\n" + table + "\n-->").isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: "<pre>\n\n" + table + "\n</pre>").isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: "```\n" + table).isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: table.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")).isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: table.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")).isEmpty)
        XCTAssertTrue(MarkdownTable.blocks(in: "| a | b |\n| --- |\n| x | y |").isEmpty)
        XCTAssertEqual(MarkdownTable.blocks(in: "| a |\n| --- |\n| x | y |").first?.hasExtraCells, true)
        XCTAssertEqual(MarkdownTable.blocks(in: table + "\n\n" + table).count, 2)
    }
    func testSpreadsheetQuotingAndHeaderChoice() throws {
        let input = "Name\tNotes\t\r\n\"A\"\t\"He said \"\"hi\"\"\"\t\r\n"
        let table = try MarkdownTable.spreadsheet(input, firstRowIsHeader: true)
        XCTAssertEqual(table.header, ["Name", "Notes", ""])
        XCTAssertEqual(table.rows, [["A", "He said \"hi\"", ""]])
        let body = try MarkdownTable.spreadsheet("a|b\t*literal*\n", firstRowIsHeader: false)
        XCTAssertEqual(body.header, ["Column 1", "Column 2"])
        XCTAssertEqual(body.rows, [["a\\|b", "\\*literal\\*"]])
        XCTAssertThrowsError(try MarkdownTable.spreadsheet("\"multi\nline\"\tx", firstRowIsHeader: false))
        XCTAssertThrowsError(try MarkdownTable.spreadsheet("\"unclosed", firstRowIsHeader: false))
        XCTAssertThrowsError(try MarkdownTable.spreadsheet(Array(repeating: "x", count: 21).joined(separator: "\t"), firstRowIsHeader: true))
    }
    func testWritingChecksIgnoreSyntaxButCheckCellProse() {
        let text = "| item   | description  |\n| :--- | ---: |\n| value  | in order to write |"
        let issues = LocalRules.analyze(WritingDocument(text: text, format: .md), preferences: .init())
        XCTAssertFalse(issues.contains { $0.category == .spacing })
        XCTAssertTrue(issues.contains { $0.original == "in order to" })
    }
    @MainActor
    func testInsertEditUndoRedoAndStaleDraft() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let doc = WritingDocument(text: "Before 😀\n\nAfter", format: .md)
        state.library.documents = [doc]; state.library.selectedID = doc.id
        let host = NSHostingView(rootView: NativeEditor(state: state, document: doc))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400); host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(state.editor.textView)
        view.setSelectedRange(NSRange(location: 11, length: 0))
        state.openTable()
        let insert = try XCTUnwrap(state.tableSession)
        XCTAssertTrue(insert.apply(to: state)); state.tableSession = nil
        let inserted = view.string
        XCTAssertTrue(inserted.hasPrefix("Before 😀\n\n|")); XCTAssertTrue(inserted.hasSuffix("\n\nAfter"))
        XCTAssertEqual(state.current?.text, inserted)
        view.undoManager?.undo(); XCTAssertEqual(view.string, doc.text); XCTAssertEqual(state.current?.text, doc.text)
        view.undoManager?.redo(); XCTAssertEqual(view.string, inserted)
        let block = try XCTUnwrap(MarkdownTable.blocks(in: inserted).first)
        view.setSelectedRange(NSRange(location: block.range.location + 3, length: 0))
        state.openTable(); let edit = try XCTUnwrap(state.tableSession)
        XCTAssertTrue(edit.editing)
        edit.table.rows[0][0] = "changed"
        XCTAssertTrue(edit.apply(to: state)); state.tableSession = nil
        XCTAssertTrue(view.string.contains("changed"))
        view.undoManager?.undo(); XCTAssertEqual(view.string, inserted)
        XCTAssertFalse(edit.apply(to: state)) // Revision changed even though undo restored the text.
        XCTAssertNotNil(edit.error)
    }
    @MainActor
    func testPreviewHasNativeCellsIncludingEmptyRowsAndInlineFormatting() throws {
        let text = "Before\n\n| **A** | B | C |\n| --- | :---: | ---: |\n| x *y* | | 12 |\n| | | |\n\nAfter"
        let rendered = MarkdownRenderer.render(text, textSize: 18)
        var cells: [String: NSTextTableBlock] = [:]
        rendered.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock else { return }
            cells["\(cell.startingRow):\(cell.startingColumn)"] = cell
        }
        XCTAssertEqual(cells.count, 9)
        XCTAssertEqual(cells["2:2"]?.table.numberOfColumns, 3)
        XCTAssertNotNil(cells["0:0"]?.backgroundColor)
        let amount = (rendered.string as NSString).range(of: "12")
        XCTAssertEqual((rendered.attribute(.paragraphStyle, at: amount.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .right)
        let after = (rendered.string as NSString).range(of: "After")
        XCTAssertTrue((rendered.attribute(.paragraphStyle, at: after.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == true)
        let x = (rendered.string as NSString).range(of: "x ")
        let y = (rendered.string as NSString).range(of: "y")
        let firstBlock = (rendered.attribute(.paragraphStyle, at: x.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
        let secondBlock = (rendered.attribute(.paragraphStyle, at: y.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first
        XCTAssertTrue(firstBlock === secondBlock)
        let font = try XCTUnwrap(rendered.attribute(.font, at: y.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
    }
    @MainActor
    func testPreviewLayoutAndGridSnapshot() throws {
        let text = "# Release plan\n\n| Feature | Owner | Status |\n| --- | :---: | ---: |\n| **Markdown tables** with a longer description that wraps across several lines | Jamie | In progress |\n| Spreadsheet paste | Alex | Ready |\n| | | |\n\nEverything stays editable in Markdown."
        let host = NSHostingView(rootView: MarkdownPreview(text: text, textSize: 18, documentID: UUID()).background(Color(nsColor: .textBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 500); host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> NSTextView? { (view as? NSTextView) ?? view.subviews.compactMap { textView(in: $0) }.first }
        let view = try XCTUnwrap(textView(in: host))
        let container = try XCTUnwrap(view.textContainer)
        view.layoutManager?.ensureLayout(for: container)
        XCTAssertGreaterThan(view.layoutManager?.usedRect(for: container).height ?? 0, 100)
        for zoom in [0.5, 1.0, 2.0] {
            WorkspaceZoom.apply(zoom, to: try XCTUnwrap(view.enclosingScrollView))
            XCTAssertEqual(view.frame.width, max(view.enclosingScrollView!.contentView.bounds.width, 454), accuracy: 1)
        }
        WorkspaceZoom.apply(1, to: try XCTUnwrap(view.enclosingScrollView))
        host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["CLEARLINE_TABLE_SNAPSHOTS"] {
            try snapshot(host, path: path + "/table-preview.png")
            let state = AppState(autoload: false)
            let doc = WritingDocument(text: text, format: .md)
            let block = try XCTUnwrap(MarkdownTable.blocks(in: text).first)
            let session = MarkdownTableSession(document: doc, range: block.range, table: block.table, editing: true)
            let grid = NSHostingView(rootView: MarkdownTableEditor(state: state, session: session).background(Color(nsColor: .windowBackgroundColor)))
            grid.frame = NSRect(x: 0, y: 0, width: 820, height: 570); grid.layoutSubtreeIfNeeded()
            try snapshot(grid, path: path + "/table-editor.png")
        }
    }
    @MainActor
    func testGridTabAndShiftTabStayInCells() throws {
        let state = AppState(autoload: false)
        let doc = WritingDocument(text: "", format: .md)
        let session = MarkdownTableSession(document: doc, range: NSRange(location: 0, length: 0), table: MarkdownTable(), editing: false)
        let host = NSHostingView(rootView: MarkdownTableEditor(state: state, session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 570), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField, field.isEditable { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        let cells = fields(in: host)
        XCTAssertEqual(cells.count, 12)
        let first = try XCTUnwrap(cells.first)
        window.makeFirstResponder(first)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        func tab(_ modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            window.sendEvent(event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        try tab()
        XCTAssertNotNil(cells[1].currentEditor(), "Tab should move from header column 1 to header column 2")
        try tab(.shift)
        XCTAssertNotNil(first.currentEditor(), "Shift-Tab should return to header column 1")
    }
    @MainActor
    func testPastedGridChangesDimensionsInPresentedSheet() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let doc = WritingDocument(text: "", format: .md)
        state.library.documents = [doc]; state.library.selectedID = doc.id
        state.showOnboarding = false; state.ready = true
        let host = NSHostingView(rootView: WorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1230, height: 830), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        state.openTable()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let session = try XCTUnwrap(state.tableSession)
        XCTAssertNotNil(window.attachedSheet)
        for (columns, rows, length) in [(2, 3, 12), (6, 12, 2000), (1, 1, 1), (20, 20, 50), (3, 5, 0)] {
            let row = Array(repeating: String(repeating: "a", count: length), count: columns).joined(separator: "\t")
            session.table = try MarkdownTable.spreadsheet(Array(repeating: row, count: rows).joined(separator: "\n"), firstRowIsHeader: true)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(session.table.header.count, columns)
        }
        state.tableSession = nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    @MainActor
    func testPastedTablePreviewInWorkspaceWindow() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        state.showOnboarding = false; state.ready = true
        let doc = WritingDocument(text: "", format: .md)
        state.library.documents = [doc]; state.library.selectedID = doc.id
        let host = NSHostingView(rootView: WorkspaceView(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1230, height: 830), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        runDisplayCycle(for: 0.2)
        for columns in [3, 6, 20, 1] {
            let row = Array(repeating: "Long cell contents that need to wrap within the column", count: columns).joined(separator: "\t")
            let table = try MarkdownTable.spreadsheet(Array(repeating: row, count: 12).joined(separator: "\n"), firstRowIsHeader: true)
            state.showMarkdownPreview = false
            let view = try XCTUnwrap(state.editor.textView)
            let source = "# Heading\n\n" + String(repeating: "A paragraph with inline `code` and **bold text**. ", count: 12) + "\n\n```sh\nexample command\n```\n\n" + table.markdown + "\n\n" + table.markdown
            view.insertText(source + "\n\n", replacementRange: NSRange(location: 0, length: view.string.utf16.count))
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            state.openTable()
            runDisplayCycle(for: 0.3)
            XCTAssertNotNil(window.attachedSheet)
            let session = try XCTUnwrap(state.tableSession)
            session.table = table
            XCTAssertTrue(session.apply(to: state))
            state.tableSession = nil
            let appliedSource = state.current?.text
            // Enter Preview before the sheet's closing animation has finished.
            state.showMarkdownPreview = true
            for zoom in [0.9, 1.0, 0.5, 2.0] {
                state.preferences.workspaceZoom = zoom
                window.setContentSize(NSSize(width: zoom == 0.9 ? 960 : 1230, height: 830))
                runDisplayCycle(for: 0.25)
                XCTAssertEqual(state.current?.text, appliedSource)
                func previewScroll(in view: NSView) -> WorkspaceScrollView? {
                    if let text = view as? NSTextView, text.accessibilityLabel() == "Markdown preview" {
                        return text.enclosingScrollView as? WorkspaceScrollView
                    }
                    return view.subviews.compactMap { previewScroll(in: $0) }.first
                }
                let scroll = try XCTUnwrap(previewScroll(in: host))
                let preview = try XCTUnwrap(scroll.documentView as? NSTextView)
                XCTAssertEqual(preview.frame.width, max(scroll.contentView.bounds.width, scroll.minimumDocumentWidth), accuracy: 1)
                if columns == 20 { XCTAssertGreaterThan(preview.frame.width, scroll.contentView.bounds.width) }
                XCTAssertEqual(try XCTUnwrap(window.contentView).frame.width, zoom == 0.9 ? 960 : 1230, accuracy: 1)
            }
        }
    }
    @MainActor
    private func runDisplayCycle(for duration: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSApp.stop(nil)
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!
            NSApp.postEvent(event, atStart: true)
        }
        NSApp.run()
    }
    @MainActor
    private func snapshot(_ view: NSView, path: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

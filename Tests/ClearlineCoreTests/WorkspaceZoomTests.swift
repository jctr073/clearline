import XCTest
import AppKit
import SwiftUI
@testable import ClearlineCore
@testable import ClearlineApp

final class WorkspaceZoomTests: XCTestCase {
    @MainActor
    func testZoomPreservesRichTextSelectionAndUndo() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let rich = NSAttributedString(string: "Original", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        var document = WritingDocument(text: rich.string, format: .rtf)
        document.richText = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        state.library.documents = [document]; state.library.selectedID = document.id
        let host = NSHostingView(rootView: NativeEditor(state: state, document: document))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(state.editor.textView)
        view.insertText(" draft", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
        view.breakUndoCoalescing()
        let before = try XCTUnwrap(state.current)
        let attributes = NSAttributedString(attributedString: try XCTUnwrap(view.textStorage))
        let selection = view.selectedRange()
        for zoom in [0.5, 1.5, 2, 1] {
            state.preferences.workspaceZoom = zoom
            host.rootView = NativeEditor(state: state, document: before)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.enclosingScrollView?.magnification, CGFloat(zoom))
            XCTAssertEqual(state.current, before)
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertEqual(view.textStorage, attributes)
        }
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "Original")
    }

    @MainActor
    func testPreviewZoomDoesNotRebuildRenderedText() throws {
        let id = UUID()
        let host = NSHostingView(rootView: MarkdownPreview(text: "# Heading\n\n**Text**", textSize: 18, documentID: id))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        func scrollIn(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap { scrollIn($0) }.first
        }
        let scroll = try XCTUnwrap(scrollIn(host))
        let view = try XCTUnwrap(scroll.documentView as? NSTextView)
        view.setSelectedRange(NSRange(location: 0, length: 7))
        let rendered = NSAttributedString(attributedString: try XCTUnwrap(view.textStorage))
        host.rootView = MarkdownPreview(text: "# Heading\n\n**Text**", textSize: 18, documentID: id, zoom: 1.5)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification, 1.5)
        XCTAssertEqual(view.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 7))
        XCTAssertEqual(view.textStorage, rendered)
        host.frame.size.width = 420
        host.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(WorkspaceZoom.clamped(.nan), 1)
        XCTAssertEqual(WorkspaceZoom.clamped(10), 2)
        XCTAssertEqual(WorkspaceZoom.clamped(0), 0.5)
    }

    func testZoomPreferenceMigratesAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("preferences.json"))
        let store = DocumentStore(directory: directory)
        var preferences = try await store.loadPreferences()
        XCTAssertEqual(preferences.workspaceZoom, 1)
        preferences.workspaceZoom = 1.5
        try await store.savePreferences(preferences)
        let restored = try await store.loadPreferences()
        XCTAssertEqual(restored.workspaceZoom, 1.5)
    }
}

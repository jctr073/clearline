import XCTest
import AppKit
import ApplicationServices
@testable import ClearlineCore
@testable import ClearlineApp

final class CrossAppSelectionTests: XCTestCase {
    private func capture(text: String = "Selected 😀 text", range: UTF16Range? = nil, fullText: String? = nil, writable: Bool = false, limit: Int = 1000) throws -> ExternalSelection {
        try ExternalSelection(pid: 0, bundleID: "com.example.reader", appName: "Reader", element: AXUIElementCreateApplication(0), range: range, text: text, fullText: fullText, bounds: nil, selectedTextIsSettable: writable, maxInputCharacters: limit)
    }

    func testReadOnlySelectionDoesNotNeedRangeOrFullField() throws {
        let selection = try capture()
        XCTAssertEqual(selection.text, "Selected 😀 text")
        XCTAssertNil(selection.range)
        XCTAssertNil(selection.fullText)
        XCTAssertFalse(selection.canReplace)
    }

    func testReplacementRequiresWritableSelectionAndMatchingContext() throws {
        let text = "Selected 😀 text", full = "Before Selected 😀 text after"
        let range = UTF16Range(7, text.utf16.count)
        XCTAssertTrue(try capture(range: range, fullText: full, writable: true).canReplace)
        XCTAssertFalse(try capture(range: range, fullText: full).canReplace)
        XCTAssertFalse(try capture(range: range, fullText: "Changed", writable: true).canReplace)
        XCTAssertFalse(try capture(fullText: full, writable: true).canReplace)
        XCTAssertFalse(try capture(range: range, writable: true).canReplace)
        XCTAssertFalse(try capture(range: UTF16Range(-1, 3), fullText: full, writable: true).canReplace)
        XCTAssertFalse(try capture(range: range, fullText: full + String(repeating: "x", count: 200000), writable: true).canReplace)
    }

    func testEmptyAndOversizedSelectionsAreRefused() throws {
        XCTAssertThrowsError(try capture(text: ""))
        XCTAssertThrowsError(try capture(text: "😀", limit: 1))
        XCTAssertEqual(try capture(text: "😀", limit: 2).text, "😀")
    }

    @MainActor
    private func session() throws -> AISession {
        let selection = try capture()
        let session = AISession(original: selection.text, documentID: nil, revision: nil, range: UTF16Range(0, selection.text.utf16.count), action: .clarity, preferences: .init(), external: selection)
        session.result = try OpenAIWire.parseResult(Data(#"{"text":"Proposal 😀","explanation":"Fixture","tone":"","warnings":[],"recommendations":[],"edits":[]}"#.utf8))
        return session
    }

    @MainActor
    func testReadOnlySelectionCannotBeReplacedEvenThroughDirectApply() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let session = try session()
        session.apply(state: state)
        XCTAssertFalse(session.applied)
        XCTAssertEqual(session.error, CrossAppError.notWritable.localizedDescription)
        XCTAssertThrowsError(try CrossAppController(state: state).replace(try XCTUnwrap(session.external), with: "Replacement")) {
            XCTAssertEqual($0 as? CrossAppError, .notWritable)
        }
    }

    @MainActor
    func testAppendPreservesRichTextAndSupportsUndoWithoutReplacingSelection() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let view = ClearlineTextView(); view.isRichText = true; view.allowsUndo = true
        view.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        defer { window.contentView = nil }
        view.textStorage?.setAttributedString(NSAttributedString(string: "Existing café 😀", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        let document = WritingDocument(text: view.string, format: .rtf)
        state.library.documents = [document]; state.library.selectedID = document.id
        state.editor.textView = view; state.editor.documentID = document.id
        let coordinator = NativeEditor.Coordinator(state: state); coordinator.view = view; view.delegate = coordinator
        view.setSelectedRange(NSRange(location: 0, length: 8))
        let session = try session()
        session.appendToWorkspace(state: state, documentID: document.id)
        XCTAssertTrue(session.applied)
        XCTAssertEqual(view.string, document.text + "\n\nProposal 😀")
        XCTAssertEqual(state.current?.text, view.string)
        XCTAssertNotNil(state.current?.richText)
        XCTAssertEqual(state.library.revisions.first?.document.text, document.text)
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        session.appendToWorkspace(state: state, documentID: document.id)
        XCTAssertEqual(view.string, document.text + "\n\nProposal 😀")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, document.text)
        XCTAssertEqual(state.current?.text, document.text)
        view.undoManager?.redo()
        XCTAssertEqual(state.current?.text, document.text + "\n\nProposal 😀")
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testAppendHandlesEmptyDocumentsAndExistingParagraphBreaks() throws {
        for original in ["", "Text", "Text\n", "Text\n\n"] {
            let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
            let view = ClearlineTextView(); view.string = original
            let document = WritingDocument(text: original)
            state.library.documents = [document]; state.library.selectedID = document.id
            state.editor.textView = view; state.editor.documentID = document.id
            let session = try session()
            session.appendToWorkspace(state: state, documentID: document.id)
            XCTAssertTrue(session.applied)
            XCTAssertEqual(view.string, original.isEmpty ? "Proposal 😀" : "Text\n\nProposal 😀")
        }
    }

    @MainActor
    func testAppendRefusesMissingOrChangedWorkspaceTarget() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let session = try session()
        XCTAssertFalse(session.canAppendToWorkspace(state: state))
        session.appendToWorkspace(state: state, documentID: UUID())
        XCTAssertFalse(session.applied)
        XCTAssertNotNil(session.error)
        let document = WritingDocument(text: "Current")
        let view = ClearlineTextView(); view.string = document.text
        state.library.documents = [document]; state.library.selectedID = document.id
        state.editor.textView = view; state.editor.documentID = document.id
        session.appendToWorkspace(state: state, documentID: UUID())
        XCTAssertFalse(session.applied)
        XCTAssertEqual(view.string, "Current")
        view.string = "Newer content"
        XCTAssertFalse(session.canAppendToWorkspace(state: state))
        session.appendToWorkspace(state: state, documentID: document.id)
        XCTAssertFalse(session.applied)
        XCTAssertEqual(view.string, "Newer content")
    }
}

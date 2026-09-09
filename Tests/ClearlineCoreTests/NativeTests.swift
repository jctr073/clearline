import XCTest
import AppKit
@testable import ClearlineCore
@testable import ClearlineApp

final class NativeTests: XCTestCase {
    @MainActor
    func testNativeEditorSuggestionUndoAndRedo() throws {
        let view = ClearlineTextView(); view.allowsUndo = true; view.string = "bad spelling"
        let doc = WritingDocument(text: view.string)
        let bridge = EditorBridge(); bridge.textView = view; bridge.documentID = doc.id
        let edit = Suggestion(revision: 0, category: .spelling, rule: "local.test", original: "bad", replacement: "good", explanation: "test", range: UTF16Range(0, 3))
        try bridge.apply([edit], document: doc)
        XCTAssertEqual(view.string, "good spelling"); XCTAssertTrue(view.undoManager?.canUndo == true)
        view.undoManager?.undo(); XCTAssertEqual(view.string, "bad spelling")
        view.undoManager?.redo(); XCTAssertEqual(view.string, "good spelling")
    }
    @MainActor
    func testNativeEditorRefusesWrongDocument() {
        let view = NSTextView(); view.allowsUndo = true; view.string = "text"
        let bridge = EditorBridge(); bridge.textView = view; bridge.documentID = UUID()
        XCTAssertThrowsError(try bridge.apply([], document: WritingDocument(text: "text")))
    }
    @MainActor
    func testRTFAndDOCXBasicFormattingRoundTrip() throws {
        let attributed = NSMutableAttributedString(string: "Bold café 😀\nSecond line")
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 17), range: NSRange(location: 0, length: 4))
        for format in [NSAttributedString.DocumentType.rtf, .officeOpenXML] {
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: format])
            let restored = try NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil)
            XCTAssertEqual(restored.string.trimmingCharacters(in: .newlines), attributed.string)
            let font = try XCTUnwrap(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        }
    }
    @MainActor
    func testAppleSpellingService() async throws {
        let engine = NativeSpelling()
        guard engine.engineLanguage("en_US") != nil else { throw XCTSkip("English spelling is not installed") }
        let document = WritingDocument(text: "A mispelled word.")
        let suggestions = await engine.analyze(document, preferences: .init())
        XCTAssertTrue(suggestions.contains { $0.original == "mispelled" && $0.replacement == "misspelled" })
    }
    @MainActor
    func testLateAIProposalCannotOverwriteNewerDocument() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let doc = WritingDocument(text: "Original writing", revision: 3)
        state.library.documents = [doc]; state.library.selectedID = doc.id
        let session = AISession(original: doc.text, documentID: doc.id, revision: 3, range: UTF16Range(0, doc.text.utf16.count), action: .clarity, preferences: .init())
        session.result = try OpenAIWire.parseResult(Data(#"{"text":"Late proposal","explanation":"Fixture only","tone":"","warnings":[],"recommendations":[],"edits":[]}"#.utf8))
        state.library.documents[0].update(text: "Newer writing")
        session.apply(state: state)
        XCTAssertEqual(state.current?.text, "Newer writing"); XCTAssertTrue(session.stale); XCTAssertNotNil(session.error)
    }
    @MainActor
    func testCrossAppDisabledAndPausedDoNotReadSelection() {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let controller = CrossAppController(state: state)
        XCTAssertThrowsError(try controller.readSelection()) { XCTAssertEqual($0 as? CrossAppError, .disabled) }
        state.preferences.crossAppEnabled = true; state.paused = true
        XCTAssertThrowsError(try controller.readSelection()) { XCTAssertEqual($0 as? CrossAppError, .paused) }
        state.paused = false
        if !controller.trusted {
            XCTAssertThrowsError(try controller.readSelection()) { XCTAssertEqual($0 as? CrossAppError, .permission) }
        }
    }
    @MainActor
    func testNativeBatchIsSingleUndoGroup() throws {
        let view = ClearlineTextView(); view.allowsUndo = true; view.string = "a  b  c"
        let doc = WritingDocument(text: view.string)
        let bridge = EditorBridge(); bridge.textView = view; bridge.documentID = doc.id
        let edits = LocalRules.analyze(doc, preferences: .init()).filter(\.batchSafe)
        try bridge.apply(edits, document: doc, batch: true)
        XCTAssertEqual(view.string, "a b c")
        view.undoManager?.undo(); XCTAssertEqual(view.string, "a  b  c")
        view.undoManager?.redo(); XCTAssertEqual(view.string, "a b c")
    }
    @MainActor
    func testRichTextBoldFormattingCanBeUndone() throws {
        let view = ClearlineTextView(); view.isRichText = true; view.allowsUndo = true
        view.textStorage?.setAttributedString(NSAttributedString(string: "words", attributes: [.font: NSFont.systemFont(ofSize: 17)]))
        view.setSelectedRange(NSRange(location: 0, length: 5))
        let doc = WritingDocument(text: "words", format: .rtf)
        let bridge = EditorBridge(); bridge.textView = view; bridge.documentID = doc.id
        bridge.format("bold", document: doc)
        let bold = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        view.undoManager?.undo()
        let regular = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: regular).contains(.boldFontMask))
    }
    @MainActor
    func testTenThousandWordNativeEditorAndAnalysisTiming() async throws {
        let view = ClearlineTextView(frame: NSRect(x: 0, y: 0, width: 650, height: 700))
        view.allowsUndo = true
        let text = String(repeating: "Clear writing gives every reader more time to think deeply. ", count: 1000)
        let start = Date()
        view.string = text
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let layout = Date().timeIntervalSince(start)
        var longestEdit: Double = 0
        for _ in 0..<20 {
            let before = Date()
            view.insertText("x", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
            longestEdit = max(longestEdit, Date().timeIntervalSince(before))
        }
        let checkStart = Date()
        _ = await NativeSpelling().analyze(WritingDocument(text: text), preferences: .init())
        let check = Date().timeIntervalSince(checkStart)
        print("PERFORMANCE native 10,000 words: initial layout \(Int(layout*1000)) ms; slowest of 20 insertions \(Int(longestEdit*1000)) ms; asynchronous spelling \(Int(check*1000)) ms")
        XCTAssertLessThan(longestEdit, 1)
    }
}

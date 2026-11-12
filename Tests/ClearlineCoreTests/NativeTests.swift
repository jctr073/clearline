import XCTest
import AppKit
@testable import ClearlineCore
@testable import ClearlineApp

final class NativeTests: XCTestCase {
    @MainActor
    func testQuickWritingMenuUsesSavedSettingsAndCapturedSelection() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let document = WritingDocument(text: "Before 😀 selected text. After.")
        state.library.documents = [document]; state.library.selectedID = document.id
        state.preferences.writingAction = .friendly
        state.preferences.model = "gpt-6-astra"; state.preferences.effort = "high"
        let view = ClearlineTextView(); view.string = document.text; view.state = state
        state.editor.textView = view; state.editor.documentID = document.id
        let selection = (document.text as NSString).range(of: "😀 selected text.")
        // The published selection may still be awaiting the delegate's asynchronous update.
        state.selection = NSRange(location: 0, length: 0)
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        view.addWritingItems(to: menu, selection: selection)
        XCTAssertEqual(menu.items.first?.title, "Quick edit — Selection…")
        XCTAssertEqual(menu.items.first?.tag, ClearlineTextView.quickEditTag)
        let quick = try XCTUnwrap(menu.items.first?.representedObject as? AISession)
        XCTAssertEqual(quick.action, .custom)
        XCTAssertEqual(quick.original, "😀 selected text.")
        XCTAssertEqual(quick.range.nsRange, selection)
        XCTAssertEqual(state.preferences.writingAction, .friendly, "Quick edit must not replace the saved action")
        XCTAssertEqual(menu.items[1].title, "Make friendlier — Selection")
        XCTAssertEqual(menu.items[1].tag, 0)
        XCTAssertEqual(menu.items.last?.title, "Copy")
        let session = try XCTUnwrap(menu.items[1].representedObject as? AISession)
        XCTAssertEqual(session.original, "😀 selected text.")
        XCTAssertEqual(session.range.nsRange, selection)
        XCTAssertEqual(session.model, "gpt-6-astra")
        XCTAssertEqual(session.effort, "high")
        XCTAssertNil(state.aiSession, "Opening the context menu must not open the full dialog")
        let submenu = try XCTUnwrap(menu.items[2].submenu)
        XCTAssertEqual(submenu.items.filter { $0.state == .on }.map(\.title), ["Make friendlier"])
        XCTAssertEqual(submenu.items.first?.title, "Make friendlier")
        XCTAssertEqual(Set(submenu.items.map(\.title)), Set(WritingAction.allCases.filter { $0 != .voice }.map(\.rawValue)))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        session.result = try OpenAIWire.parseResult(Data(#"{"text":"Rewritten.","explanation":"","tone":"","warnings":[],"recommendations":[],"edits":[]}"#.utf8))
        session.apply(state: state)
        XCTAssertTrue(session.applied)
        XCTAssertEqual(view.string, "Before Rewritten. After.")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, document.text)
    }

    @MainActor
    func testQuickWritingWithoutSelectionUsesWholeDocumentAndRejectsStaleProposal() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let document = WritingDocument(text: "First paragraph.\n\nSecond paragraph.")
        state.library.documents = [document]; state.library.selectedID = document.id
        let view = ClearlineTextView(); view.string = document.text; view.state = state
        state.editor.textView = view; state.editor.documentID = document.id
        let menu = NSMenu()
        view.addWritingItems(to: menu, selection: NSRange(location: 20, length: 0))
        XCTAssertEqual(menu.items.first?.title, "Quick edit — Document…")
        XCTAssertEqual(menu.items[1].title, "Improve clarity — Document")
        let session = try XCTUnwrap(menu.items[1].representedObject as? AISession)
        XCTAssertEqual(session.original, document.text)
        XCTAssertEqual(session.range.nsRange, NSRange(location: 0, length: document.text.utf16.count))
        session.result = try OpenAIWire.parseResult(Data(#"{"text":"New proposal","explanation":"","tone":"","warnings":[],"recommendations":[],"edits":[]}"#.utf8))
        state.library.documents[0].update(text: "Changed while generating")
        session.apply(state: state)
        XCTAssertFalse(session.applied)
        XCTAssertTrue(session.stale)
        XCTAssertEqual(state.current?.text, "Changed while generating")
    }

    @MainActor
    func testQuickEditAnchorFollowsSelectionAndStaysVisible() {
        let view = ClearlineTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.string = "First line.\nSecond line with a selection.\nThird line."
        let selection = (view.string as NSString).range(of: "selection")
        let anchor = view.quickEditAnchor(for: selection)
        let caret = view.quickEditAnchor(for: NSRange(location: selection.location, length: 0))
        XCTAssertGreaterThan(anchor.width, 1)
        XCTAssertEqual(anchor.minX, caret.minX, accuracy: 1)
        XCTAssertEqual(anchor.minY, caret.minY, accuracy: 1)
        XCTAssertGreaterThan(anchor.minY, view.quickEditAnchor(for: NSRange(location: 0, length: 5)).minY)
        XCTAssertTrue(view.visibleRect.contains(anchor))
        XCTAssertGreaterThanOrEqual(caret.width, 1)
    }

    @MainActor
    func testWritingSessionRejectsInvalidSelection() {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let document = WritingDocument(text: "Text")
        state.library.documents = [document]; state.library.selectedID = document.id
        XCTAssertNil(state.makeWritingSession(selection: NSRange(location: NSNotFound, length: 0)))
        XCTAssertNil(state.makeWritingSession(selection: NSRange(location: 3, length: 10)))
    }

    @MainActor
    func testWritingChoicesPersistWithoutGeneratingAndRestoreInNewSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(directory: directory, autoload: false)
        let document = WritingDocument(text: "A message")
        state.library.documents = [document]; state.library.selectedID = document.id
        state.startAI()
        let session = try XCTUnwrap(state.aiSession)
        state.setWritingAction(.friendly, session: session)
        state.setWritingModel("gpt-6-astra", session: session)
        state.setWritingEffort("high", session: session)
        state.setShowWritingChanges(false)
        state.startAI()
        XCTAssertEqual(state.aiSession?.action, .friendly)
        XCTAssertEqual(state.aiSession?.model, "gpt-6-astra")
        XCTAssertEqual(state.aiSession?.effort, "high")

        // The picker changes autosave even if the user closes without generating.
        try await Task.sleep(for: .milliseconds(600))
        let restored = AppState(directory: directory, autoload: false)
        restored.preferences = try await restored.store.loadPreferences()
        XCTAssertEqual(restored.preferences.writingAction, .friendly)
        XCTAssertFalse(restored.preferences.showWritingChanges)
        let next = AISession(original: "Next message", documentID: nil, revision: nil, range: UTF16Range(0, 12), preferences: restored.preferences)
        XCTAssertEqual(next.action, .friendly)
        XCTAssertEqual(next.model, "gpt-6-astra")
        XCTAssertEqual(next.effort, "high")

        state.startAI(.summarize)
        XCTAssertEqual(state.aiSession?.action, .summarize)
        state.startAI()
        XCTAssertEqual(state.aiSession?.action, .friendly)

        state.setWritingModel("gpt-4.1-mini", session: next)
        XCTAssertEqual(state.preferences.effort, "")
        state.setWritingModel("gpt-6-astra", session: next)
        XCTAssertEqual(state.preferences.effort, "medium")
        try await Task.sleep(for: .milliseconds(600))
        let normalized = try await state.store.loadPreferences()
        XCTAssertEqual(normalized.model, "gpt-6-astra")
        XCTAssertEqual(normalized.effort, "medium")
    }
    @MainActor
    func testWritingSessionNormalizesEffortWhenOpeningAndSwitchingModels() {
        var prefs = WritingPreferences(); prefs.model = "gpt-5.6-terra"; prefs.effort = ""
        let session = AISession(original: "Text", documentID: nil, revision: nil, range: UTF16Range(0, 4), action: .clarity, preferences: prefs)
        XCTAssertEqual(session.effort, "medium")
        session.effort = "none"
        session.changeModel("gpt-6-astra")
        XCTAssertEqual(session.model, "gpt-6-astra")
        XCTAssertEqual(session.effort, "medium")
        XCTAssertFalse(session.selectionNotice.isEmpty)
        session.effort = "high"
        session.changeModel("gpt-5.5")
        XCTAssertEqual(session.effort, "high")
    }
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

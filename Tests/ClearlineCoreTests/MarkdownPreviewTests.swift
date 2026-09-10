import XCTest
import AppKit
import SwiftUI
@testable import ClearlineCore
@testable import ClearlineApp

final class MarkdownPreviewTests: XCTestCase {
    @MainActor
    func testHeadingInlineFormattingAndCodeFence() throws {
        let rendered = MarkdownRenderer.render("### Consistent local signing\n\n**Use the same** identity and `build.sh`.\n\n```sh\nsecurity find-identity\n./scripts/build.sh\n```", textSize: 18)
        XCTAssertEqual(rendered.string, "Consistent local signing\nUse the same identity and build.sh.\nsecurity find-identity\n./scripts/build.sh\n")
        let heading = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(heading.pointSize, 18)
        let boldRange = (rendered.string as NSString).range(of: "Use the same")
        let bold = try XCTUnwrap(rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let codeRange = (rendered.string as NSString).range(of: "security")
        let code = try XCTUnwrap(rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(code.isFixedPitch)
    }

    @MainActor
    func testNestedListsAndSeparateParagraphs() {
        let rendered = MarkdownRenderer.render("- **one** item\n- two\n  - nested\n\n3. third\n4. fourth\n\n> quoted\n\nFinal paragraph", textSize: 18)
        XCTAssertEqual(rendered.string, "•\tone item\n•\ttwo\n•\tnested\n3.\tthird\n4.\tfourth\nquoted\nFinal paragraph")
        let nested = (rendered.string as NSString).range(of: "nested")
        let paragraph = rendered.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.headIndent, 48)
    }

    @MainActor
    func testSafeLinksAndLiteralCode() {
        let rendered = MarkdownRenderer.render("[Web](https://example.com) [Local](file:///tmp/test)\n\n```html\n<script>alert('hi')</script>\n```", textSize: 18)
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        let local = (rendered.string as NSString).range(of: "Local")
        XCTAssertNil(rendered.attribute(.link, at: local.location, effectiveRange: nil))
        XCTAssertTrue(rendered.string.contains("<script>alert('hi')</script>"))
        XCTAssertEqual(MarkdownRenderer.render("", textSize: 18).string, "")
    }

    @MainActor
    func testTableCellsRemainSeparated() {
        let rendered = MarkdownRenderer.render("| A | B |\n|---|---|\n| x | y |", textSize: 18)
        XCTAssertEqual(rendered.string, "A\tB\nx\ty")
    }

    @MainActor
    func testPreviewPreservesEditorAndUndoWhenToggling() throws {
        let state = AppState(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), autoload: false)
        let document = WritingDocument(text: "# Original", format: .md)
        state.library.documents = [document]
        state.library.selectedID = document.id
        let host = NSHostingView(rootView: NativeEditor(state: state, document: document))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(state.editor.textView)
        view.insertText(" draft", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
        view.breakUndoCoalescing()
        let source = view.string
        let selection = view.selectedRange()
        state.showMarkdownPreview = true
        host.rootView = NativeEditor(state: state, document: try XCTUnwrap(state.current))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(state.editor.textView === view)
        XCTAssertTrue(view.enclosingScrollView?.isHidden == true)
        XCTAssertEqual(state.current?.text, source)
        XCTAssertEqual(view.selectedRange(), selection)
        state.showMarkdownPreview = false
        host.rootView = NativeEditor(state: state, document: try XCTUnwrap(state.current))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(state.editor.textView === view)
        XCTAssertTrue(view.enclosingScrollView?.isHidden == false)
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "# Original")
        XCTAssertEqual(state.current?.text, "# Original")
    }
}

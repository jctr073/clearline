import XCTest
@testable import ClearlineCore

final class EditIntegrityTests: XCTestCase {
    func suggestion(_ doc: WritingDocument, _ original: String, _ replacement: String, range: NSRange? = nil, category: SuggestionCategory = .spelling) -> Suggestion {
        Suggestion(revision: doc.revision, category: category, rule: "local.test", original: original, replacement: replacement, explanation: "Test", range: UTF16Range(range ?? (doc.text as NSString).range(of: original)))
    }
    func testAcceptAdvancesRevision() throws {
        let doc = WritingDocument(text: "A mispelled word", revision: 8)
        let output = try EditEngine.apply([suggestion(doc, "mispelled", "misspelled")], to: doc)
        XCTAssertEqual(output.text, "A misspelled word"); XCTAssertEqual(output.revision, 9); XCTAssertEqual(output.id, doc.id)
    }
    func testStaleRevisionRejectedEvenWhenTextMatches() {
        var doc = WritingDocument(text: "same")
        let edit = suggestion(doc, "same", "different"); doc.update(text: "same")
        XCTAssertThrowsError(try EditEngine.apply([edit], to: doc)) { XCTAssertEqual($0 as? EditError, .stale) }
    }
    func testMismatchRejected() {
        let doc = WritingDocument(text: "wrong")
        let edit = suggestion(doc, "other", "right", range: NSRange(location: 0, length: 5))
        XCTAssertThrowsError(try EditEngine.apply([edit], to: doc)) { XCTAssertEqual($0 as? EditError, .mismatch) }
    }
    func testOutOfBoundsAndOverflowRejected() {
        for range in [UTF16Range(-1, 1), UTF16Range(0, -1), UTF16Range(2, 4), UTF16Range(Int.max, Int.max)] {
            XCTAssertThrowsError(try EditEngine.substring("abc", range: range))
        }
    }
    func testSurrogateAndGraphemeBoundariesRejected() {
        XCTAssertThrowsError(try EditEngine.substring("😀", range: UTF16Range(0, 1)))
        XCTAssertThrowsError(try EditEngine.substring("e\u{301}", range: UTF16Range(0, 1)))
        XCTAssertThrowsError(try EditEngine.substring("👨‍👩‍👧‍👦", range: UTF16Range(0, 2)))
        XCTAssertThrowsError(try EditEngine.substring("e\u{301}", range: UTF16Range(1, 0)))
    }
    func testUnicodeAndMultilineEdits() throws {
        for prefix in ["😀 ", "e\u{301} ", "שלום ", "مرحبا ", "日本語\n", "👨‍👩‍👧‍👦\n"] {
            let doc = WritingDocument(text: prefix + "bad\nword")
            let result = try EditEngine.apply([suggestion(doc, "bad\nword", "good\nwords")], to: doc)
            XCTAssertEqual(result.text, prefix + "good\nwords")
        }
    }
    func testOverlapsRejectedAtomically() {
        let doc = WritingDocument(text: "abcdef")
        XCTAssertThrowsError(try EditEngine.apply([suggestion(doc, "abc", "x"), suggestion(doc, "bc", "y")], to: doc)) { XCTAssertEqual($0 as? EditError, .overlap) }
        XCTAssertEqual(doc.text, "abcdef")
    }
    func testBatchAppliesDescendingAndAdvancesOnce() throws {
        let doc = WritingDocument(text: "bad thing is bad")
        let edits = [suggestion(doc, "bad", "excellent", range: NSRange(location: 0, length: 3)), suggestion(doc, "bad", "good", range: NSRange(location: 13, length: 3))]
        let result = try EditEngine.apply(edits, to: doc, batch: true)
        XCTAssertEqual(result.text, "excellent thing is good"); XCTAssertEqual(result.revision, 1)
    }
    func testMeaningChangingBatchRejected() {
        let doc = WritingDocument(text: "in order to")
        XCTAssertThrowsError(try EditEngine.apply([suggestion(doc, doc.text, "to", category: .clarity)], to: doc, batch: true)) { XCTAssertEqual($0 as? EditError, .unsafeBatch) }
    }
    func testDuplicateAndOverlapResolutionPrefersMechanicalLocal() {
        let doc = WritingDocument(text: "mispelled word")
        let local = suggestion(doc, "mispelled", "misspelled")
        var ai = suggestion(doc, doc.text, "different text", category: .clarity); ai.rule = "openai.analysis"; ai.optional = true
        let results = EditEngine.resolve([ai, local, local], in: doc)
        XCTAssertEqual(results.count, 1); XCTAssertEqual(results.first?.id, local.id)
    }
    func testInsertionAtEndAndEmptyDocument() throws {
        let doc = WritingDocument(text: "")
        let result = try EditEngine.apply([suggestion(doc, "", "new draft", range: NSRange(location: 0, length: 0))], to: doc)
        XCTAssertEqual(result.text, "new draft")
    }
    func testDiffCanReconstructBothVersions() {
        let a = "A little  more\nclarity 😀", b = "Much more\nclarity 😀 today"
        let tokens = TextDiff.tokens(before: a, after: b)
        XCTAssertEqual(tokens.filter { $0.kind != .added }.map(\.text).joined(), a)
        XCTAssertEqual(tokens.filter { $0.kind != .removed }.map(\.text).joined(), b)
    }
}

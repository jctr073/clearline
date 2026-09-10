import XCTest
@testable import ClearlineCore

final class AnalysisAndStorageTests: XCTestCase {
    func testSavedModelKeepsItsIdentityAndNormalizesNewlyKnownEffort() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(directory: directory)
        var prefs = WritingPreferences()
        for (model, saved, expected) in [("gpt-5.6-terra", "", "medium"), ("gpt-6-astra", "none", "medium"), ("gpt-5.6-sol", "high", "high"), ("gpt-4.1-mini", "", "")] {
            prefs.model = model; prefs.effort = saved
            try await store.savePreferences(prefs)
            let restored = try await store.loadPreferences()
            XCTAssertEqual(restored.model, model)
            XCTAssertEqual(restored.effort, expected)
        }
    }
    func testRealRulesFindSpacingWordinessAndRepetition() {
        let doc = WritingDocument(text: "In order to write  clearly, avoid the the repetition.")
        let issues = LocalRules.analyze(doc, preferences: .init())
        XCTAssertTrue(issues.contains { $0.category == .spacing && $0.replacement == " " })
        XCTAssertTrue(issues.contains { $0.category == .clarity && $0.replacement == "To" && $0.optional })
        XCTAssertTrue(issues.contains { $0.category == .repetition })
    }
    func testProtectedSpansExcluded() {
        let text = "`in order to`\n```\na  b\n```\n“in order to”\nhttps://test.example.com/a\nIn order to write."
        let issues = LocalRules.analyze(WritingDocument(text: text), preferences: .init())
        XCTAssertEqual(issues.count, 1); XCTAssertEqual(issues.first?.original, "In order to")
    }
    func testDisabledRulesAndTerms() {
        var prefs = WritingPreferences(); prefs.disabledCategories = [.clarity]; prefs.preferredTerms = ["utilize": "use"]
        let issues = LocalRules.analyze(WritingDocument(text: "In order to utilize it."), preferences: prefs)
        XCTAssertEqual(issues.count, 1); XCTAssertEqual(issues.first?.replacement, "use")
    }
    func testAdditivePreferenceMigrationAndIndividualRule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"model":"gpt-5.4","effort":"high"}"#.utf8).write(to: directory.appendingPathComponent("preferences.json"))
        var prefs = try await DocumentStore(directory: directory).loadPreferences()
        XCTAssertEqual(prefs.model, "gpt-5.4"); XCTAssertEqual(prefs.effort, "high"); XCTAssertTrue(prefs.disabledRules.isEmpty)
        prefs.disabledRules.insert("local.spaces")
        XCTAssertTrue(LocalRules.analyze(WritingDocument(text: "two  spaces"), preferences: prefs).isEmpty)
    }
    func testEnglishRulesDoNotRunForOtherLanguages() {
        var prefs = WritingPreferences(); prefs.language = "fr"
        XCTAssertTrue(LocalRules.analyze(WritingDocument(text: "In order to write."), preferences: prefs).isEmpty)
    }
    func testChunkOwnershipCoversUnicodeExactlyOnce() throws {
        let text = String(repeating: "😀 e\u{301} 日本語 hello\n", count: 1000)
        let chunks = LocalRules.chunks(text, limit: 137, overlap: 20)
        var reconstructed = ""
        for chunk in chunks { reconstructed += try EditEngine.substring(chunk.text, range: UTF16Range(0, chunk.owned)) }
        XCTAssertEqual(reconstructed, text)
    }
    func testPreservationFlagsQuantitiesAndProtectedContent() {
        let warnings = PreservationCheck.warnings(before: "Ada wrote `foo_bar` on May 12 for 40 clients.", after: "Ada wrote bar on May 13 for 50 clients.", preferences: .init())
        XCTAssertEqual(warnings.count, 2)
    }
    func testMetricsHandleEmptyAndNonLatin() {
        XCTAssertEqual(TextMetrics("").words, 0); XCTAssertEqual(TextMetrics("").readingMinutes, 0)
        XCTAssertEqual(TextMetrics("Hello 世界 😀").characters, 10)
    }
    func testStoreRoundTripAndPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(directory: directory)
        var library = Library(); let doc = WritingDocument(title: "Notes", text: "😀 café\nשלום", revision: 42)
        library.documents = [doc]; library.selectedID = doc.id; library.revisions = [Revision(document: doc)]
        try await store.save(library)
        let result = try await store.load()
        XCTAssertEqual(result.0.documents, [doc]); XCTAssertEqual(result.0.selectedID, doc.id); XCTAssertFalse(result.recovered)
        var prefs = WritingPreferences(); prefs.model = "gpt-5.4"; prefs.effort = "high"; prefs.dictionary = ["clearline"]
        try await store.savePreferences(prefs)
        let loaded = try await store.loadPreferences(); XCTAssertEqual(loaded, prefs)
    }
    func testCorruptPrimaryRecoversBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(directory: directory)
        var library = Library(); library.documents = [WritingDocument(text: "before")]
        try await store.save(library); library.documents[0].update(text: "after"); try await store.save(library)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("library.json"))
        let result = try await store.load()
        XCTAssertTrue(result.recovered); XCTAssertEqual(result.0.documents.first?.text, "before")
    }
    func testUnknownSchemaDoesNotFallBackOrOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(directory: directory)
        try await store.save(Library()); try await store.save(Library())
        var future = Library(); future.schema = 99
        let data = try JSONEncoder().encode(future)
        try data.write(to: directory.appendingPathComponent("library.json"))
        do { _ = try await store.load(); XCTFail("Must reject future schema") } catch { XCTAssertEqual(error as? StoreError, .unsupportedSchema) }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("library.json")), data)
    }
    func testDeletionPurgesRecoveryCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DocumentStore(directory: directory)
        var library = Library(); library.documents = [WritingDocument(text: "private")]
        try await store.save(library); try await store.save(Library(), purgeBackup: true)
        let backup = try JSONDecoder().decode(Library.self, from: Data(contentsOf: directory.appendingPathComponent("library.backup.json")))
        XCTAssertTrue(backup.documents.isEmpty)
    }
    func testTenThousandWordLocalAnalysisPerformance() {
        let text = String(repeating: "Clear writing gives every reader more time to think deeply. ", count: 1000)
        let start = Date()
        _ = LocalRules.analyze(WritingDocument(text: text), preferences: .init())
        let elapsed = Date().timeIntervalSince(start)
        print("PERFORMANCE local rules: 10,000 words, \(Int(elapsed * 1000)) ms; \(ProcessInfo.processInfo.operatingSystemVersionString)")
        XCTAssertLessThan(elapsed, 5, "Offline rules must remain bounded")
    }
}

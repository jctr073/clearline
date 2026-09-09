import XCTest
@testable import ClearlineCore

final class APIUsageTests: XCTestCase {
    private func usage() throws -> TokenUsage {
        try XCTUnwrap(TokenUsage.parse([
            "input_tokens": 100, "output_tokens": 40,
            "input_tokens_details": ["cached_tokens": 30],
            "output_tokens_details": ["reasoning_tokens": 10]
        ]))
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testMissingAndInvalidUsageRemainUnknown() {
        XCTAssertNil(TokenUsage.parse(nil))
        XCTAssertNil(TokenUsage.parse(["total_tokens": 100]))
        XCTAssertNil(TokenUsage.parse(["input_tokens": -1, "output_tokens": 10]))
        XCTAssertNil(TokenUsage.parse(["input_tokens": 10, "output_tokens": 10, "input_tokens_details": ["cached_tokens": 11]]))
        XCTAssertNil(TokenUsage.parse(["input_tokens": true, "output_tokens": 10]))
        let valid = TokenUsage.parse(["input_tokens": 10, "output_tokens": 0])
        XCTAssertNotNil(valid)
        XCTAssertNil(valid?.input_tokens_details)
    }
    func testUTCPeriodsModelsAndSubsetTotals() throws {
        var ledger = UsageLedger()
        ledger.record(model: "first", usage: try usage(), at: date("2026-08-31T23:59:59Z"))
        ledger.record(model: "first", usage: try usage(), at: date("2026-09-01T00:00:00Z"))
        ledger.record(model: "second", usage: try usage(), at: date("2026-09-09T00:00:00Z"))
        let now = date("2026-09-09T01:00:00Z")
        XCTAssertEqual(ledger.totals(.today, now: now).responses, 1)
        XCTAssertEqual(ledger.totals(.month, now: now).responses, 2)
        let all = ledger.totals(.all, now: now)
        XCTAssertEqual(all.responses, 3)
        XCTAssertEqual(all.total, 420) // Cached and reasoning are subsets, not extra tokens.
        XCTAssertEqual(all.cached, 90)
        XCTAssertEqual(all.reasoning, 30)
        XCTAssertEqual(ledger.byModel(.all)["first"]?.input, 200)
    }
    func testConcurrentRecordingPersistsAcrossRelaunchAndReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(directory: directory), tokens = try usage()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await store.record(model: "model", usage: tokens) } }
            try await group.waitForAll()
        }
        let restored = try await UsageStore(directory: directory).load()
        XCTAssertEqual(restored.totals(.all).responses, 20)
        XCTAssertEqual(restored.totals(.all).total, 2800)
        let reset = try await store.reset()
        XCTAssertGreaterThan(reset.revision, restored.revision)
        let empty = try await UsageStore(directory: directory).load()
        XCTAssertEqual(empty.totals(.all).responses, 0)
    }
    func testCorruptUsageIsPreservedUntilExplicitReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("api-usage.json"), bad = Data("broken usage".utf8)
        try bad.write(to: file)
        let store = UsageStore(directory: directory)
        do { _ = try await store.record(model: "model", usage: usage()); XCTFail("Must preserve damaged data") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bad)
        _ = try await store.reset()
        let restored = try await UsageStore(directory: directory).load()
        XCTAssertTrue(restored.buckets.isEmpty)
    }
    func testUnknownSchemaAndNegativeCountersAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var ledger = UsageLedger(); ledger.schema = 2
        let file = directory.appendingPathComponent("api-usage.json")
        try JSONEncoder().encode(ledger).write(to: file)
        do { _ = try await UsageStore(directory: directory).load(); XCTFail("Must reject future schema") } catch {}
        ledger.schema = 1; ledger.record(model: "model", usage: try usage())
        ledger.buckets[0].totals.input = -1
        try JSONEncoder().encode(ledger).write(to: file)
        do { _ = try await UsageStore(directory: directory).load(); XCTFail("Must reject invalid counters") } catch {}
    }
}

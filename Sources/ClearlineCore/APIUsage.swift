import Foundation

/// Provider metadata only. Never derive usage from the generated proposal.
public struct TokenUsage: Codable, Equatable, Sendable {
    public struct InputDetails: Codable, Equatable, Sendable { public let cached_tokens: Int? }
    public struct OutputDetails: Codable, Equatable, Sendable { public let reasoning_tokens: Int? }
    public let input_tokens: Int
    public let output_tokens: Int
    public let input_tokens_details: InputDetails?
    public let output_tokens_details: OutputDetails?

    public static func parse(_ object: Any?) -> TokenUsage? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let usage = try? JSONDecoder().decode(Self.self, from: data),
              (0...1_000_000_000).contains(usage.input_tokens),
              (0...1_000_000_000).contains(usage.output_tokens) else { return nil }
        if let cached = usage.input_tokens_details?.cached_tokens, !(0...usage.input_tokens).contains(cached) { return nil }
        if let reasoning = usage.output_tokens_details?.reasoning_tokens, !(0...usage.output_tokens).contains(reasoning) { return nil }
        return usage
    }
}

public struct UsageTotals: Codable, Equatable, Sendable {
    public var responses = 0
    public var input = 0
    public var output = 0
    public var cached = 0
    public var reasoning = 0
    public var cachedReports = 0
    public var reasoningReports = 0
    public var total: Int { input + output }
    public init() {}
    public mutating func add(_ other: UsageTotals) {
        responses += other.responses; input += other.input; output += other.output
        cached += other.cached; reasoning += other.reasoning
        cachedReports += other.cachedReports; reasoningReports += other.reasoningReports
    }
    mutating func record(_ usage: TokenUsage) {
        responses += 1; input += usage.input_tokens; output += usage.output_tokens
        if let value = usage.input_tokens_details?.cached_tokens { cached += value; cachedReports += 1 }
        if let value = usage.output_tokens_details?.reasoning_tokens { reasoning += value; reasoningReports += 1 }
    }
}

public enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", month = "This month", all = "All recorded"
    public var id: String { rawValue }
}

public struct UsageBucket: Codable, Sendable {
    public let day: String
    public let model: String
    public var totals = UsageTotals()
}

public struct UsageLedger: Codable, Sendable {
    public var schema = 1
    public var revision = 0
    public var since = Date()
    public var buckets: [UsageBucket] = []
    public init() {}
    public static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public mutating func record(model: String, usage: TokenUsage, at date: Date = Date()) {
        let day = Self.day(date)
        if let index = buckets.firstIndex(where: { $0.day == day && $0.model == model }) {
            buckets[index].totals.record(usage)
        } else {
            var bucket = UsageBucket(day: day, model: model)
            bucket.totals.record(usage); buckets.append(bucket)
        }
        revision += 1
    }
    public func byModel(_ period: UsagePeriod, now: Date = Date()) -> [String: UsageTotals] {
        let day = Self.day(now)
        var result: [String: UsageTotals] = [:]
        for bucket in buckets where period == .all || (period == .today ? bucket.day == day : bucket.day.prefix(7) == day.prefix(7)) {
            result[bucket.model, default: UsageTotals()].add(bucket.totals)
        }
        return result
    }
    public func totals(_ period: UsagePeriod, now: Date = Date()) -> UsageTotals {
        byModel(period, now: now).values.reduce(into: UsageTotals()) { $0.add($1) }
    }
}

/// Serializes updates and atomically persists daily aggregates separately from documents.
public actor UsageStore {
    private let file: URL
    private var ledger: UsageLedger?
    public init(directory: URL) { file = directory.appendingPathComponent("api-usage.json") }
    public func load() throws -> UsageLedger {
        if let ledger { return ledger }
        guard FileManager.default.fileExists(atPath: file.path) else {
            let empty = UsageLedger(); ledger = empty; return empty
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 10_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let decoded = try JSONDecoder().decode(UsageLedger.self, from: data)
        guard decoded.schema == 1 else { throw CocoaError(.fileReadUnknown) }
        guard decoded.revision >= 0, decoded.revision < Int.max - 1,
              decoded.since.timeIntervalSince1970.isFinite, decoded.buckets.count <= 100_000,
              decoded.buckets.allSatisfy({ bucket in
                  let t = bucket.totals
                  return bucket.day.count == 10 && !bucket.model.isEmpty &&
                      [t.responses, t.input, t.output, t.cached, t.reasoning, t.cachedReports, t.reasoningReports]
                        .allSatisfy { (0...1_000_000_000_000).contains($0) } &&
                      t.cached <= t.input && t.reasoning <= t.output &&
                      t.cachedReports <= t.responses && t.reasoningReports <= t.responses
              }) else { throw CocoaError(.fileReadCorruptFile) }
        ledger = decoded
        return decoded
    }
    public func record(model: String, usage: TokenUsage, at date: Date = Date()) throws -> UsageLedger {
        var updated = try load()
        updated.record(model: model, usage: usage, at: date)
        // Keep received usage in memory even if persistence temporarily fails.
        ledger = updated
        try save(updated)
        return updated
    }
    public func reset() throws -> UsageLedger {
        var empty = UsageLedger()
        empty.revision = (ledger?.revision ?? 0) + 1
        try save(empty); ledger = empty; return empty
    }
    private func save(_ value: UsageLedger) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }
}

import Foundation

public enum Brand {
    public static let name = "Clearline"
    public static let bundleID = "com.clearline.desktop"
    public static let tagline = "Make room for better writing."
    public static let version = "0.1.0"
    public static let keychainService = bundleID + ".openai"
}

public enum DocumentFormat: String, Codable, CaseIterable, Sendable { case txt, md, rtf }

public struct WritingDocument: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var revision: Int
    public var modified: Date
    public var format: DocumentFormat
    public var richText: Data?
    public init(id: UUID = UUID(), title: String = "Untitled", text: String = "", revision: Int = 0, format: DocumentFormat = .md) {
        self.id = id; self.title = title; self.text = text; self.revision = revision
        self.modified = Date(); self.format = format
    }
    public mutating func update(text: String, richText: Data? = nil) {
        self.text = text; self.richText = richText; revision += 1; modified = Date()
    }
}

public struct Revision: Codable, Identifiable, Sendable {
    public let id: UUID
    public let document: WritingDocument
    public let date: Date
    public init(document: WritingDocument) { id = UUID(); self.document = document; date = Date() }
}

public enum SuggestionCategory: String, Codable, CaseIterable, Sendable {
    case spelling = "Spelling", grammar = "Grammar", punctuation = "Punctuation", spacing = "Spacing"
    case repetition = "Repetition", clarity = "Clarity", style = "Style", vocabulary = "Vocabulary"
    public var mechanical: Bool { [.spelling, .spacing, .punctuation].contains(self) }
}

/// All persisted and provider ranges are UTF-16 offsets, never Swift Character counts.
public struct UTF16Range: Codable, Equatable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public init(_ range: NSRange) { location = range.location; length = range.length }
    public init(_ location: Int, _ length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public struct Suggestion: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var revision: Int
    public var category: SuggestionCategory
    public var rule: String
    public var original: String
    public var replacement: String
    public var explanation: String
    public var range: UTF16Range
    public var optional: Bool
    public init(revision: Int, category: SuggestionCategory, rule: String, original: String, replacement: String,
                explanation: String, range: UTF16Range, optional: Bool = false) {
        id = UUID(); self.revision = revision; self.category = category; self.rule = rule
        self.original = original; self.replacement = replacement; self.explanation = explanation
        self.range = range; self.optional = optional
    }
    public var dismissalKey: String { "\(revision):\(rule):\(range.location):\(original)" }
    public var batchSafe: Bool { category.mechanical && !optional && rule.hasPrefix("local.") }
}

public struct WritingPreferences: Codable, Equatable, Sendable {
    public var language = "en_US"
    public var audience = "General"
    public var context = "Professional document"
    public var tone = "Neutral"
    public var instructions = ""
    public var dictionary: Set<String> = []
    public var disabledCategories: Set<SuggestionCategory> = []
    public var disabledRules: Set<String> = []
    public var passiveVoice = false
    public var protectCode = true
    public var protectQuotes = true
    public var preferredTerms: [String: String] = [:]
    public var punctuationStyle = "Preserve"
    public var voiceSamples = ""
    public var voiceProfile = ""
    public var voiceEnabled = false
    public var model = "gpt-5.6-terra"
    public var effort = "medium"
    public var maxOutputTokens = 4096
    public var timeoutSeconds = 90
    public var maxInputCharacters = 24000
    public var cloudAutomatic = false
    public var crossAppEnabled = false
    public var allowedApps: Set<String> = ["com.apple.TextEdit"]
    public var blockedApps: Set<String> = []
    public var shortcutKey: UInt32 = 49 // Space
    public var shortcutModifiers: UInt32 = 0x0100 | 0x0800 // command + option
    public var textSize: Double = 18
    public var appearance = "System"
    public var useAgentService = false
    public init() {}
}

public struct TextMetrics: Sendable {
    public let words: Int
    public let characters: Int
    public let readingMinutes: Int
    public let averageSentenceWords: Int
    public init(_ text: String) {
        words = text.split { $0.isWhitespace || $0.isNewline }.count
        characters = text.count
        readingMinutes = words == 0 ? 0 : max(1, Int(ceil(Double(words) / 225)))
        let sentences = max(1, text.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
        averageSentenceWords = words / sentences
    }
}

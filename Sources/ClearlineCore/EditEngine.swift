import Foundation

public enum EditError: String, Error, LocalizedError {
    case stale = "The source has changed. Check it again before applying this edit."
    case invalidRange = "This edit does not have a valid Unicode text range."
    case mismatch = "The original text no longer matches. No changes were made."
    case overlap = "These edits overlap. Review them individually."
    case unsafeBatch = "Meaning-changing edits need individual review."
    public var errorDescription: String? { rawValue }
}

public enum EditEngine {
    public static func substring(_ text: String, range: UTF16Range) throws -> String {
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let swiftRange = Range(range.nsRange, in: text) else { throw EditError.invalidRange }
        // Reject boundaries inside an extended grapheme cluster, including combining marks and ZWJ emoji.
        let source = text as NSString
        if range.length > 0 {
            guard source.rangeOfComposedCharacterSequences(for: range.nsRange) == range.nsRange else { throw EditError.invalidRange }
        } else if range.location < source.length {
            guard source.rangeOfComposedCharacterSequence(at: range.location).location == range.location else { throw EditError.invalidRange }
        }
        return String(text[swiftRange])
    }
    public static func validate(_ suggestion: Suggestion, in document: WritingDocument) throws {
        guard suggestion.revision == document.revision else { throw EditError.stale }
        guard try substring(document.text, range: suggestion.range) == suggestion.original else { throw EditError.mismatch }
    }
    public static func approved(_ suggestions: [Suggestion], in document: WritingDocument, batch: Bool = false) throws -> [Suggestion] {
        var end = -1
        let sorted = suggestions.sorted { $0.range.location < $1.range.location }
        for edit in sorted {
            try validate(edit, in: document)
            if batch && !edit.batchSafe { throw EditError.unsafeBatch }
            guard edit.range.location >= end else { throw EditError.overlap }
            end = edit.range.location + max(edit.range.length, 1)
        }
        return sorted.reversed()
    }
    public static func apply(_ suggestions: [Suggestion], to document: WritingDocument, batch: Bool = false) throws -> WritingDocument {
        let edits = try approved(suggestions, in: document, batch: batch)
        let result = NSMutableString(string: document.text)
        for edit in edits { result.replaceCharacters(in: edit.range.nsRange, with: edit.replacement) }
        var updated = document
        if !edits.isEmpty { updated.update(text: result as String) }
        return updated
    }
    public static func resolve(_ suggestions: [Suggestion], in document: WritingDocument) -> [Suggestion] {
        var result: [Suggestion] = []
        for candidate in suggestions.sorted(by: {
            if $0.optional != $1.optional { return !$0.optional }
            if $0.rule.hasPrefix("local.") != $1.rule.hasPrefix("local.") { return $0.rule.hasPrefix("local.") }
            return $0.range.length < $1.range.length
        }) where (try? validate(candidate, in: document)) != nil {
            if !result.contains(where: { NSIntersectionRange($0.range.nsRange, candidate.range.nsRange).length > 0 || $0.range == candidate.range }) {
                result.append(candidate)
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
}

public struct DiffToken: Identifiable, Sendable {
    public enum Kind: Sendable { case unchanged, removed, added }
    public let id: Int
    public let text: String
    public let kind: Kind
}

public enum TextDiff {
    public static func tokens(before: String, after: String) -> [DiffToken] {
        func split(_ text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "\\s+|[^\\s]+")
            return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map { (text as NSString).substring(with: $0.range) }
        }
        let a = split(before), b = split(after)
        // CollectionDifference uses an efficient Myers diff. Cap pathological inputs.
        guard a.count + b.count <= 12000 else {
            return [DiffToken(id: 0, text: before, kind: .removed), DiffToken(id: 1, text: after, kind: .added)]
        }
        let diff = b.difference(from: a)
        var removed = Set<Int>(), added = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let i, _, _): removed.insert(i)
            case .insert(let i, _, _): added.insert(i)
            }
        }
        var result: [DiffToken] = [], i = 0, j = 0
        func append(_ text: String, _ kind: DiffToken.Kind) { result.append(DiffToken(id: result.count, text: text, kind: kind)) }
        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) { append(a[i], .removed); i += 1 }
            else if j < b.count && added.contains(j) { append(b[j], .added); j += 1 }
            else if j < b.count { append(b[j], .unchanged); i += 1; j += 1 }
            else { break }
        }
        return result
    }
}

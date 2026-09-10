import Foundation
import NaturalLanguage

public enum LocalRules {
    public static func protectedRanges(_ text: String, preferences: WritingPreferences) -> [NSRange] {
        var patterns = [#"https?://[^\s<>]+|\b\w+[._]\w+(?:[._]\w+)*\b|\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+\b"#]
        if preferences.protectCode { patterns += [#"(?s)```.*?```|`[^`\n]+`"#] }
        if preferences.protectQuotes { patterns += [#"“[^”]*”|"[^"\n]*""#] }
        var ranges = patterns.flatMap { pattern in
            (try? NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map(\.range)) ?? []
        }
        ranges += MarkdownTable.syntaxRanges(in: text)
        let names = NLTagger(tagSchemes: [.nameType]); names.string = text
        names.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) { ranges.append(NSRange(range, in: text)) }
            return !Task.isCancelled
        }
        return ranges
    }
    public static func analyze(_ document: WritingDocument, preferences: WritingPreferences) -> [Suggestion] {
        let text = document.text, source = text as NSString
        let protected = protectedRanges(text, preferences: preferences)
        var output: [Suggestion] = []
        func rule(_ pattern: String, _ replacement: String, _ category: SuggestionCategory, _ id: String, _ explanation: String, optional: Bool = false) {
            guard !Task.isCancelled, !preferences.disabledCategories.contains(category), !preferences.disabledRules.contains("local.\(id)"), let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                      (try? EditEngine.substring(text, range: UTF16Range(match.range))) != nil else { continue }
                let original = source.substring(with: match.range)
                if preferences.dictionary.contains(original.lowercased()) { continue }
                var proposed = regex.replacementString(for: match, in: text, offset: 0, template: replacement)
                if original.first?.isUppercase == true, let first = proposed.first { proposed = first.uppercased() + proposed.dropFirst() }
                output.append(Suggestion(revision: document.revision, category: category, rule: "local.\(id)", original: original,
                                         replacement: proposed, explanation: explanation, range: UTF16Range(match.range), optional: optional))
            }
        }
        rule(#"(?<=\S)[ \t]{2,}(?=\S)"#, " ", .spacing, "spaces", "Use a single space between words.")
        rule(#"\b([\p{L}]+)\s+\1\b"#, "$1", .repetition, "repeated-word", "This word appears twice in a row. Check whether the repetition is intentional.", optional: true)
        rule(#"[ \t]+([,;:!?])"#, "$1", .punctuation, "space-before-punctuation", "Remove the space before this punctuation mark.")
        guard preferences.language.hasPrefix("en") else { return output }
        rule(#"\bi\b"#, "I", .grammar, "capital-i", "Capitalize the English pronoun I.")
        for (phrase, replacement) in [("in order to", "to"), ("at this point in time", "now"), ("due to the fact that", "because"), ("a large number of", "many"), ("each and every", "each"), ("very unique", "unique"), ("in the event that", "if"), ("for the purpose of", "for")] {
            rule("\\b" + phrase + "\\b", replacement, .clarity, "wordiness", "A shorter phrase may make this sentence easier to read. This is a style preference.", optional: true)
        }
        for (term, replacement) in preferences.preferredTerms where !term.isEmpty && !replacement.isEmpty {
            rule("\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b", NSRegularExpression.escapedTemplate(for: replacement), .vocabulary, "terminology", "Your writing preferences favor ‘\(replacement)’.", optional: true)
        }
        if preferences.punctuationStyle == "Avoid em dashes" {
            rule("—", ", ", .style, "em-dash", "Your style preference avoids em dashes. Review sentence structure before replacing.", optional: true)
        }
        if preferences.passiveVoice {
            rule(#"\b(?:was|were|is|are|been|be)\s+(?:\w+ed|written|given|known|shown|seen|made|taken)\s+by\b"#, "$0", .style, "passive", "Possible passive voice. Consider naming the person doing the action. Passive voice can also be appropriate.", optional: true)
        }
        return output
    }
    /// Chunks overlap for sentence context; only suggestions starting inside the owned range are retained.
    public static func chunks(_ text: String, limit: Int = 6000, overlap: Int = 300) -> [(text: String, offset: Int, owned: Int)] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        var result: [(String, Int, Int)] = [], start = 0
        while start < source.length {
            var owned = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(limit, source.length - start)))
            if NSMaxRange(owned) < source.length {
                let tail = NSRange(location: max(start, NSMaxRange(owned) - min(512, limit / 2)), length: min(512, limit / 2, owned.length))
                let boundary = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: tail)
                if boundary.location != NSNotFound { owned.length = NSMaxRange(boundary) - start }
            }
            let check = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(owned.length + overlap, source.length - start)))
            result.append((source.substring(with: check), start, owned.length))
            start += owned.length
        }
        return result
    }
}

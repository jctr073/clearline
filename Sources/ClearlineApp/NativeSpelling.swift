import AppKit
import NaturalLanguage
import ClearlineCore

@MainActor
final class NativeSpelling {
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()
    var languages: [String] { NSSpellChecker.shared.availableLanguages }
    func engineLanguage(_ requested: String) -> String? {
        if languages.contains(requested) { return requested }
        // Apple's U.S. English dictionary is advertised as "en", not "en_US".
        if requested == "en_US", languages.contains("en") { return "en" }
        return nil
    }
    func analyze(_ document: WritingDocument, preferences: WritingPreferences) async -> [Suggestion] {
        guard let language = engineLanguage(preferences.language) else { return [] }
        let checker = NSSpellChecker.shared
        checker.setIgnoredWords(Array(preferences.dictionary) + [Brand.name], inSpellDocumentWithTag: tag)
        let protected = await Task.detached(priority: .utility) { LocalRules.protectedRanges(document.text, preferences: preferences) }.value
        var suggestions: [Suggestion] = []
        for chunk in LocalRules.chunks(document.text) {
            if Task.isCancelled { return [] }
            let results: [NSTextCheckingResult] = await withCheckedContinuation { continuation in
                checker.requestChecking(of: chunk.text, range: NSRange(location: 0, length: chunk.text.utf16.count),
                    types: NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue,
                    options: [.orthography: NSOrthography.defaultOrthography(forLanguage: language)], inSpellDocumentWithTag: tag) { _, results, _, _ in
                        continuation.resume(returning: results)
                    }
            }
            if Task.isCancelled { return [] }
            for result in results where result.range.location < chunk.owned {
                if NSMaxRange(result.range) == chunk.text.utf16.count && chunk.offset + chunk.text.utf16.count < document.text.utf16.count { continue }
                if result.range.location == 0 && chunk.offset > 0 && !(document.text as NSString).substring(with: NSRange(location: chunk.offset - 1, length: 1)).unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) { continue }
                let range = NSRange(location: chunk.offset + result.range.location, length: result.range.length)
                guard !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      let original = try? EditEngine.substring(document.text, range: UTF16Range(range)),
                      !preferences.dictionary.contains(original.lowercased()), original != Brand.name else { continue }
                if result.resultType == .spelling && !preferences.disabledCategories.contains(.spelling) {
                    let replacement = checker.guesses(forWordRange: result.range, in: chunk.text, language: language, inSpellDocumentWithTag: tag)?.first
                    suggestions.append(Suggestion(revision: document.revision, category: .spelling, rule: "local.apple-spelling", original: original,
                        replacement: replacement ?? original, explanation: replacement == nil ? "Not in the system dictionary. Add it to your dictionary if this spelling is intentional." : "The macOS spelling service suggests this spelling. Check names and technical terms carefully.", range: UTF16Range(range), optional: replacement == nil))
                } else if result.resultType == .grammar && !preferences.disabledCategories.contains(.grammar) {
                    for detail in result.grammarDetails ?? [] {
                        guard let value = detail[NSGrammarRange] as? NSValue else { continue }
                        let relative = value.rangeValue
                        let detailRange = UTF16Range(range.location + relative.location, relative.length)
                        guard let original = try? EditEngine.substring(document.text, range: detailRange),
                              !protected.contains(where: { NSIntersectionRange($0, detailRange.nsRange).length > 0 }) else { continue }
                        let corrections = detail[NSGrammarCorrections] as? [String] ?? []
                        suggestions.append(Suggestion(revision: document.revision, category: .grammar, rule: "local.apple-grammar", original: original,
                            replacement: corrections.first ?? original, explanation: detail[NSGrammarUserDescription] as? String ?? "Review this construction. Grammar coverage depends on the macOS language service.", range: detailRange, optional: corrections.isEmpty))
                    }
                }
            }
            await Task.yield()
        }
        return suggestions.filter { !preferences.disabledRules.contains($0.rule) }
    }
    static func detectedLanguage(_ text: String) -> String? { NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(4000)))?.rawValue }
}

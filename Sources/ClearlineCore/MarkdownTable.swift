import Foundation

/// Source-backed, top-level GFM tables. Cell strings retain inline Markdown.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: String, CaseIterable, Sendable {
        case left, center, right
        public var delimiter: String { switch self { case .left: return "---"; case .center: return ":---:"; case .right: return "---:" } }
    }
    public var header: [String]
    public var rows: [[String]]
    public var alignments: [Alignment]
    public init(header: [String] = ["Column 1", "Column 2", "Column 3"], rows: [[String]] = Array(repeating: Array(repeating: "", count: 3), count: 3), alignments: [Alignment] = [.left, .left, .left]) {
        self.header = header; self.rows = rows; self.alignments = alignments
    }
    public var markdown: String {
        func row(_ cells: [String]) -> String { "| " + cells.map(Self.escapePipes).joined(separator: " | ") + " |" }
        return ([row(header), row(header.indices.map { ($0 < alignments.count ? alignments[$0] : .left).delimiter })] + rows.map(row)).joined(separator: "\n")
    }
    public static func escapePipes(_ text: String) -> String {
        var output = "", slashes = 0
        for character in text {
            if character == "|", slashes % 2 == 0 { output += "\\" }
            output.append(character)
            slashes = character == "\\" ? slashes + 1 : 0
        }
        return output
    }
    public struct Block: Sendable {
        public let table: MarkdownTable
        /// Includes the header and data, but excludes the last line ending.
        public let range: NSRange
        public let delimiterRange: NSRange
        public let hasExtraCells: Bool
    }
    private struct Line {
        let text: String
        let range: NSRange
    }
    public static func blocks(in text: String) -> [Block] {
        let source = text as NSString
        var lines: [Line] = [], offset = 0
        while offset < source.length {
            var start = 0, end = 0, contentEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
            let range = NSRange(location: start, length: contentEnd - start)
            lines.append(Line(text: source.substring(with: range), range: range)); offset = end
        }
        var result: [Block] = [], index = 0
        var fence: (Character, Int)?
        var htmlEnd: String?
        var htmlUntilBlank = false
        while index < lines.count {
            let line = lines[index].text
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let end = htmlEnd {
                if trimmed.lowercased().contains(end) { htmlEnd = nil }
                index += 1; continue
            }
            if htmlUntilBlank {
                if trimmed.isEmpty { htmlUntilBlank = false }
                index += 1; continue
            }
            let marker = trimmed.first
            let count = marker.map { mark in trimmed.prefix(while: { $0 == mark }).count } ?? 0
            if let active = fence {
                if marker == active.0 && count >= active.1 && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                index += 1; continue
            }
            if (marker == "`" || marker == "~") && count >= 3 && !line.hasPrefix("    ") && !line.hasPrefix("\t") {
                fence = (marker!, count); index += 1; continue
            }
            // Leave raw HTML blocks alone, even if they contain table-shaped text.
            let lower = trimmed.lowercased()
            if lower.hasPrefix("<!--") {
                if !lower.contains("-->") { htmlEnd = "-->" }
                index += 1; continue
            }
            if let tag = ["script", "style", "pre", "textarea"].first(where: { lower.hasPrefix("<" + $0 + ">") || lower.hasPrefix("<" + $0 + " ") }) {
                if !lower.contains("</" + tag + ">") { htmlEnd = "</" + tag + ">" }
                index += 1; continue
            }
            if trimmed.range(of: #"^</?[A-Za-z][A-Za-z0-9-]*(?:\s|/?>)"#, options: .regularExpression) != nil {
                htmlUntilBlank = true; index += 1; continue
            }
            // Indented/container tables remain editable in source; never rewrite their containers.
            guard index + 1 < lines.count, !line.hasPrefix(" "), !line.hasPrefix("\t"), !startsBlock(line), line.contains("|"),
                  let header = cells(line), let delimiters = cells(lines[index + 1].text), header.count == delimiters.count,
                  !header.isEmpty, delimiters.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) else { index += 1; continue }
            let alignment: [Alignment] = delimiters.map { $0.hasSuffix(":") ? ($0.hasPrefix(":") ? .center : .right) : .left }
            var rows: [[String]] = [], endIndex = index + 1, extra = false
            while endIndex + 1 < lines.count {
                let next = lines[endIndex + 1].text
                guard !next.trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(next), !next.hasPrefix("    "), !next.hasPrefix("\t"), let parsed = cells(next) else { break }
                extra = extra || parsed.count > header.count
                rows.append(Array(parsed.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - parsed.count)))
                endIndex += 1
            }
            let range = NSRange(location: lines[index].range.location, length: NSMaxRange(lines[endIndex].range) - lines[index].range.location)
            result.append(Block(table: MarkdownTable(header: header, rows: rows, alignments: alignment), range: range, delimiterRange: lines[index + 1].range, hasExtraCells: extra))
            index = endIndex + 1
        }
        return result
    }
    /// Protect delimiters and surrounding padding while allowing checks inside cells.
    public static func syntaxRanges(in text: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        for block in blocks(in: text) {
            ranges.append(block.delimiterRange)
            let body = source.substring(with: block.range) as NSString
            var slashes = 0
            for index in 0..<body.length {
                let character = body.character(at: index)
                if character == 124 && slashes.isMultiple(of: 2) {
                    var start = index, end = index + 1
                    while start > 0 && [32, 9].contains(body.character(at: start - 1)) { start -= 1 }
                    while end < body.length && [32, 9].contains(body.character(at: end)) { end += 1 }
                    ranges.append(NSRange(location: block.range.location + start, length: end - start))
                }
                slashes = character == 92 ? slashes + 1 : 0
            }
        }
        return ranges
    }
    private static func startsBlock(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:>|#{1,6}(?:\s|$)|[-+*]\s|\d+[.)]\s|`{3,}|~{3,}|(?:\*\s*){3,}$|(?:-\s*){3,}$|(?:_\s*){3,}$|<)"#, options: .regularExpression) != nil
    }
    private static func cells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var output: [String] = [], cell = "", slashes = 0
        for character in trimmed {
            if character == "|" && slashes % 2 == 0 { output.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
            slashes = character == "\\" ? slashes + 1 : 0
        }
        output.append(cell.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|") { output.removeFirst() }
        if output.last == "" && trimmed.hasSuffix("|") && output.count > 1 { output.removeLast() }
        return output
    }
    public enum ImportError: String, Error, LocalizedError {
        case empty = "The clipboard has no tab-separated text. Copy cells from a spreadsheet first."
        case multiline = "A pasted cell contains a line break. Markdown table cells must stay on one line. Remove the line breaks and paste again."
        case malformed = "The pasted data has an unclosed quoted cell."
        case tooLarge = "The table editor supports up to 20 columns and 200 body rows."
        public var errorDescription: String? { rawValue }
    }
    /// Handles spreadsheet quoting and trailing empty cells without silently discarding data.
    public static func spreadsheet(_ text: String, firstRowIsHeader: Bool) throws -> MarkdownTable {
        guard !text.isEmpty else { throw ImportError.empty }
        let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var records: [[String]] = [], record: [String] = [], cell = "", quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" && (quoted || cell.isEmpty) {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" { cell.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if !quoted && character == "\t" { record.append(cell); cell = "" }
            else if !quoted && character == "\n" { record.append(cell); records.append(record); record = []; cell = "" }
            else { cell.append(character) }
            index += 1
        }
        guard !quoted else { throw ImportError.malformed }
        if !cell.isEmpty || !record.isEmpty || characters.last != "\n" { record.append(cell); records.append(record) }
        guard !records.isEmpty else { throw ImportError.empty }
        guard !records.flatMap({ $0 }).contains(where: { $0.contains("\n") }) else { throw ImportError.multiline }
        let columns = records.map(\.count).max() ?? 1
        guard columns <= 20, records.count <= (firstRowIsHeader ? 201 : 200) else { throw ImportError.tooLarge }
        // Spreadsheet content is literal text; Markdown typed in the grid remains Markdown.
        records = records.map { row in row.map { value in
            value.reduce(into: "") { output, character in
                if "\\`*_[]<>|&".contains(character) { output.append("\\") }; output.append(character)
            }
        } + Array(repeating: "", count: columns - row.count) }
        let header = firstRowIsHeader ? records.removeFirst() : (1...columns).map { "Column \($0)" }
        return MarkdownTable(header: header, rows: records, alignments: Array(repeating: .left, count: columns))
    }
}

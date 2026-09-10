import AppKit
import SwiftUI
import ClearlineCore

@MainActor
final class MarkdownTableSession: ObservableObject, Identifiable {
    let id = UUID()
    let documentID: UUID
    let revision: Int
    let range: NSRange
    let original: String
    let editing: Bool
    @Published var table: MarkdownTable
    @Published var error: String?

    init(document: WritingDocument, range: NSRange, table: MarkdownTable, editing: Bool) {
        documentID = document.id; revision = document.revision; self.range = range
        original = (document.text as NSString).substring(with: range)
        self.table = table; self.editing = editing
    }
    func paste(firstRowIsHeader: Bool = true) {
        guard let text = NSPasteboard.general.string(forType: .string) else { error = MarkdownTable.ImportError.empty.localizedDescription; return }
        do { table = try MarkdownTable.spreadsheet(text, firstRowIsHeader: firstRowIsHeader); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func apply(to state: AppState) -> Bool {
        guard let document = state.current, document.id == documentID, document.revision == revision else {
            error = "The document changed while this table was open. Cancel and reopen the table to edit the latest version."; return false
        }
        guard !(table.header + table.rows.flatMap { $0 }).contains(where: { $0.contains(where: \.isNewline) }) else {
            error = MarkdownTable.ImportError.multiline.localizedDescription; return false
        }
        let newline = document.text.contains("\r\n") ? "\r\n" : "\n"
        var replacement = table.markdown.replacingOccurrences(of: "\n", with: newline)
        let source = document.text as NSString
        if !editing {
            let before = source.substring(to: range.location)
            let after = source.substring(from: NSMaxRange(range))
            if !before.isEmpty { replacement = (before.hasSuffix(newline + newline) ? "" : before.hasSuffix(newline) ? newline : newline + newline) + replacement }
            if !after.isEmpty { replacement += after.hasPrefix(newline + newline) ? "" : after.hasPrefix(newline) ? newline : newline + newline }
        }
        do {
            try state.editor.replaceTable(in: document, range: range, original: original, replacement: replacement, action: editing ? "Edit table" : "Insert table")
            return true
        } catch { self.error = "Could not apply the table. The document or editor changed; cancel and reopen the table."; return false }
    }
}

extension AppState {
    func openTable(paste: Bool = false, firstRowIsHeader: Bool = true) {
        guard tableSession == nil, let document = current, document.format == .md,
              editor.documentID == document.id, let view = editor.textView,
              view.string == document.text, !view.hasMarkedText() else { return }
        let selection = view.selectedRange()
        let blocks = MarkdownTable.blocks(in: document.text)
        let block = blocks.first {
            selection.location >= $0.range.location && selection.location <= NSMaxRange($0.range)
        }
        if let block, !paste {
            guard NSMaxRange(selection) <= NSMaxRange(block.range) else { error = "Select within one table to edit it."; return }
            guard !block.hasExtraCells else { error = "This table has rows with more cells than its header. Fix the extra cells in Markdown source before using the grid editor, so no content is lost."; return }
            guard block.table.header.count <= 20, block.table.rows.count <= 200 else { error = MarkdownTable.ImportError.tooLarge.localizedDescription; return }
            tableSession = MarkdownTableSession(document: document, range: block.range, table: block.table, editing: true)
        } else {
            // Inserting a second table inside a table would produce ambiguous source.
            guard block == nil else { error = "Move the cursor outside the table to paste a new table, or use Edit Table to replace its grid."; return }
            guard !blocks.contains(where: { NSIntersectionRange($0.range, selection).length > 0 }) else {
                error = "Select within one table to edit it, or move the cursor outside the table to insert a new one."; return
            }
            tableSession = MarkdownTableSession(document: document, range: selection, table: MarkdownTable(), editing: false)
            if paste { tableSession?.paste(firstRowIsHeader: firstRowIsHeader) }
        }
    }
}

extension EditorBridge {
    func replaceTable(in document: WritingDocument, range: NSRange, original: String, replacement: String, action: String) throws {
        guard document.format == .md, documentID == document.id, let view = textView,
              view.string == document.text, !view.hasMarkedText(),
              try EditEngine.substring(document.text, range: UTF16Range(range)) == original,
              view.shouldChangeText(in: range, replacementString: replacement) else { throw EditError.stale }
        showSource?()
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.textStorage?.replaceCharacters(in: range, with: replacement)
        view.didChangeText()
        view.undoManager?.endUndoGrouping()
        view.undoManager?.setActionName(action)
        view.setSelectedRange(NSRange(location: range.location, length: replacement.utf16.count))
        view.scrollRangeToVisible(view.selectedRange())
        view.window?.makeFirstResponder(view)
    }
}

struct MarkdownTableEditor: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: MarkdownTableSession
    @FocusState private var focused: Cell?
    private struct Cell: Hashable { let row: Int; let column: Int }
    private var columns: Int { session.table.header.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.editing ? "Edit Table" : "Insert Table").font(.title2.bold())
                    Text("\(columns) columns · \(session.table.rows.count) body rows").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Column", systemImage: "plus") { insertColumn(at: columns) }.disabled(columns >= 20)
                Button("Add Row", systemImage: "plus") { insertRow(at: session.table.rows.count) }.disabled(session.table.rows.count >= 200)
            }
            HStack {
                Menu("Replace Grid from Clipboard") {
                    Button("Use First Row as Headers") { focused = nil; session.paste() }
                    Button("Generate Column Headers") { focused = nil; session.paste(firstRowIsHeader: false) }
                }.fixedSize()
                Text("Paste cells copied from a spreadsheet.").foregroundStyle(.secondary)
            }.font(.callout)
            Text("Tab and Shift-Tab move between cells. Use column and row menus to insert or remove them. Cells support inline Markdown.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Header").font(.caption.bold()).frame(width: 76)
                        ForEach(0..<columns, id: \.self) { column in
                            VStack(spacing: 8) {
                                HStack {
                                    Menu("Column \(column + 1)") {
                                        Button("Insert Column Before") { insertColumn(at: column) }.disabled(columns >= 20)
                                        Button("Insert Column After") { insertColumn(at: column + 1) }.disabled(columns >= 20)
                                        Button("Delete Column", role: .destructive) { deleteColumn(column) }.disabled(columns <= 1)
                                    }.menuStyle(.borderlessButton)
                                }
                                cell(row: -1, column: column)
                                Picker("Column \(column + 1) alignment", selection: Binding(get: {
                                    session.table.alignments.indices.contains(column) ? session.table.alignments[column] : .left
                                }, set: { value in
                                    if session.table.alignments.indices.contains(column) { session.table.alignments[column] = value }
                                })) {
                                    ForEach(MarkdownTable.Alignment.allCases, id: \.self) { alignment in Text(alignment.rawValue.capitalized).tag(alignment) }
                                }.labelsHidden()
                            }.padding(10).frame(width: 190).background(Color.accentColor.opacity(0.08))
                                .overlay { Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5) }
                        }
                    }
                    ForEach(session.table.rows.indices, id: \.self) { row in
                        HStack(spacing: 0) {
                            Menu("Row \(row + 1)") {
                                Button("Insert Row Above") { insertRow(at: row) }.disabled(session.table.rows.count >= 200)
                                Button("Insert Row Below") { insertRow(at: row + 1) }.disabled(session.table.rows.count >= 200)
                                Button("Delete Row", role: .destructive) { focused = nil; session.table.rows.remove(at: row) }
                            }.menuStyle(.borderlessButton).frame(width: 76).accessibilityLabel("Row \(row + 1) actions")
                            ForEach(0..<columns, id: \.self) { column in
                                cell(row: row, column: column).padding(10).frame(width: 190)
                                    .background(row.isMultiple(of: 2) ? Color.secondary.opacity(0.035) : .clear)
                                    .overlay { Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5) }
                            }
                        }
                    }
                }.padding(1)
            }.background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
            if let error = session.error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(!session.editing && session.range.length > 0 ? "Inserting will replace the selected text. Cancel keeps your document unchanged." : "Changes are saved when you apply this table. You can undo them in the document.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { state.tableSession = nil }.keyboardShortcut(.cancelAction)
                Button(session.editing ? "Apply Table" : "Insert Table") { if session.apply(to: state) { state.tableSession = nil } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 820, height: 570)
    }
    private func cell(row: Int, column: Int) -> some View {
        TextField(row == -1 ? "Header" : "", text: Binding(get: {
            guard column < columns else { return "" }
            return row == -1 ? session.table.header[column] : (row < session.table.rows.count ? session.table.rows[row][column] : "")
        }, set: { value in
            guard column < columns else { return }
            if row == -1 { session.table.header[column] = value }
            else if row < session.table.rows.count { session.table.rows[row][column] = value }
        }))
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("\(row == -1 ? "Header" : "Row \(row + 1)"), column \(column + 1)")
        .focused($focused, equals: Cell(row: row, column: column))
        .onKeyPress(keys: [.tab], phases: .down) { press in
            let total = (session.table.rows.count + 1) * columns
            let position = (row + 1) * columns + column
            let next = (position + (press.modifiers.contains(.shift) ? -1 : 1) + total) % total
            focused = Cell(row: next / columns - 1, column: next % columns)
            return .handled
        }
    }
    private func insertRow(at index: Int) {
        focused = nil; session.table.rows.insert(Array(repeating: "", count: columns), at: index)
    }
    private func insertColumn(at index: Int) {
        focused = nil; session.table.header.insert("", at: index); session.table.alignments.insert(.left, at: index)
        for row in session.table.rows.indices { session.table.rows[row].insert("", at: index) }
    }
    private func deleteColumn(_ index: Int) {
        focused = nil; session.table.header.remove(at: index); session.table.alignments.remove(at: index)
        for row in session.table.rows.indices { session.table.rows[row].remove(at: index) }
    }
}

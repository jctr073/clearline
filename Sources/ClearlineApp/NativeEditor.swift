import AppKit
import SwiftUI
import ClearlineCore

@MainActor
final class EditorBridge {
    weak var textView: NSTextView?
    var documentID: UUID?
    func apply(_ suggestions: [Suggestion], document: WritingDocument, batch: Bool = false) throws {
        guard documentID == document.id, let textView, textView.string == document.text, !textView.hasMarkedText() else { throw EditError.stale }
        let edits = try EditEngine.approved(suggestions, in: document, batch: batch)
        guard !edits.isEmpty else { return }
        let oldSelection = textView.selectedRange()
        var cursor = oldSelection.location
        guard textView.shouldChangeText(inRanges: edits.map { NSValue(range: $0.range.nsRange) }, replacementStrings: edits.map(\.replacement)) else { throw EditError.stale }
        textView.undoManager?.beginUndoGrouping()
        for edit in edits {
            textView.textStorage?.replaceCharacters(in: edit.range.nsRange, with: edit.replacement)
            if edit.range.location < cursor { cursor = max(edit.range.location, cursor + edit.replacement.utf16.count - edit.range.length) }
        }
        textView.didChangeText()
        textView.undoManager?.endUndoGrouping(); textView.undoManager?.setActionName(edits.count == 1 ? "Accept suggestion" : "Accept mechanical corrections")
        textView.setSelectedRange(NSRange(location: min(cursor, textView.string.utf16.count), length: 0))
        textView.window?.makeFirstResponder(textView)
    }
    func reveal(_ range: NSRange) { textView?.setSelectedRange(range); textView?.scrollRangeToVisible(range) }
    func replaceAll(_ text: String, richText: Data? = nil, action: String) {
        guard let view = textView, !view.hasMarkedText() else { return }
        view.undoManager?.beginUndoGrouping()
        let range = NSRange(location: 0, length: view.string.utf16.count)
        if view.shouldChangeText(in: range, replacementString: text) {
            if let richText, let attributed = NSAttributedString(rtf: richText, documentAttributes: nil) { view.textStorage?.setAttributedString(attributed) }
            else { view.textStorage?.replaceCharacters(in: range, with: text) }
            view.didChangeText()
        }
        view.undoManager?.endUndoGrouping(); view.undoManager?.setActionName(action)
    }
    func copyAll() { guard let text = textView?.string else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func copySelection() {
        guard let view = textView, let text = try? EditEngine.substring(view.string, range: UTF16Range(view.selectedRange())) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func format(_ kind: String, document: WritingDocument) {
        guard let view = textView else { return }
        if document.format == .rtf && (kind == "bold" || kind == "italic") {
            let trait: NSFontTraitMask = kind == "bold" ? .boldFontMask : .italicFontMask
            let range = view.selectedRange()
            guard range.length > 0, view.shouldChangeText(in: range, replacementString: nil) else { return }
            view.textStorage?.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 18)
                let manager = NSFontManager.shared
                let newFont = manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
                view.textStorage?.addAttribute(.font, value: newFont, range: subrange)
            }
            view.didChangeText(); return
        }
        if document.format == .rtf {
            var range = view.selectedRange()
            var attributes: [NSAttributedString.Key: Any] = [:]
            if kind == "heading" {
                range = (view.string as NSString).paragraphRange(for: range)
                attributes[.font] = NSFont.systemFont(ofSize: 26, weight: .semibold)
            } else if kind == "list" {
                range = (view.string as NSString).paragraphRange(for: range)
                let paragraph = NSMutableParagraphStyle()
                paragraph.textLists = [NSTextList(markerFormat: .disc, options: 0)]
                paragraph.headIndent = 24; paragraph.firstLineHeadIndent = 8
                attributes[.paragraphStyle] = paragraph
            } else if kind == "link" {
                guard range.length > 0 else { return }
                let alert = NSAlert(); alert.messageText = "Add a link"; alert.informativeText = "Enter the web address for the selected text."
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.placeholderString = "https://example.com"
                alert.accessoryView = field; alert.addButton(withTitle: "Add link"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue), ["https", "http"].contains(url.scheme) else { return }
                attributes[.link] = url
            }
            guard range.length > 0, !attributes.isEmpty, view.shouldChangeText(in: range, replacementString: nil) else { return }
            view.textStorage?.addAttributes(attributes, range: range); view.didChangeText(); return
        }
        let range = view.selectedRange(), selected = (view.string as NSString).substring(with: range)
        let replacement: String
        switch kind {
        case "bold": replacement = "**\(selected)**"
        case "italic": replacement = "*\(selected)*"
        case "heading": replacement = "## \(selected)"
        case "list": replacement = selected.components(separatedBy: "\n").map { "- " + $0 }.joined(separator: "\n")
        case "link": replacement = "[\(selected)](https://example.com)"
        default: return
        }
        view.insertText(replacement, replacementRange: range)
    }
}

struct NativeEditor: NSViewRepresentable {
    @ObservedObject var state: AppState
    let document: WritingDocument
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let view = ClearlineTextView(frame: .zero)
        view.isRichText = document.format == .rtf; view.allowsUndo = true; view.isEditable = true; view.isSelectable = true
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.drawsBackground = false; view.textColor = .labelColor; view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 38, height: 20)
        view.minSize = NSSize(width: 0, height: 0); view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.state = state
        view.setAccessibilityLabel("Document editor")
        scroll.documentView = view; context.coordinator.view = view
        state.editor.textView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ClearlineTextView else { return }
        state.editor.textView = view
        let switching = state.editor.documentID != document.id
        if switching {
            context.coordinator.updating = true
            view.undoManager?.removeAllActions()
            view.isRichText = document.format == .rtf
            if document.format == .rtf, let data = document.richText, let content = NSAttributedString(rtf: data, documentAttributes: nil) { view.textStorage?.setAttributedString(content) }
            else { view.string = document.text }
            view.setSelectedRange(NSRange(location: 0, length: 0)); state.editor.documentID = document.id
            context.coordinator.updating = false
        }
        if !view.hasMarkedText() {
            if !view.isRichText { view.font = NSFont.systemFont(ofSize: state.preferences.textSize); view.textColor = .labelColor }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 9; paragraph.paragraphSpacing = 10
            view.defaultParagraphStyle = paragraph
            if !view.isRichText || switching { view.typingAttributes = [.font: NSFont.systemFont(ofSize: state.preferences.textSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph] }
            if !view.isRichText { view.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: view.string.utf16.count)) }
            if let layout = view.layoutManager {
                let full = NSRange(location: 0, length: view.string.utf16.count)
                layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
                layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
                for issue in state.suggestions where issue.revision == document.revision && (try? EditEngine.validate(issue, in: document)) != nil {
                    let color: NSColor = issue.optional ? .systemOrange : .systemRed
                    layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: color], forCharacterRange: issue.range.nsRange)
                    if state.selectedIssue == issue.id { layout.addTemporaryAttribute(.backgroundColor, value: color.withAlphaComponent(0.1), forCharacterRange: issue.range.nsRange) }
                }
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: AppState
        weak var view: NSTextView?
        var updating = false
        init(state: AppState) { self.state = state }
        func textDidChange(_ notification: Notification) {
            guard !updating, let view else { return }
            if view.hasMarkedText() { state.compositionBegan(); return }
            let rich = view.isRichText ? view.rtf(from: NSRange(location: 0, length: view.string.utf16.count)) : nil
            state.textChanged(view.string, richText: rich)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view else { return }
            let selection = view.selectedRange()
            DispatchQueue.main.async { self.state.selection = selection }
        }
    }
}

final class ClearlineTextView: NSTextView {
    weak var state: AppState?
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    override func unmarkText() { super.unmarkText(); state?.textChanged(string, richText: isRichText ? rtf(from: NSRange(location: 0, length: string.utf16.count)) : nil); state?.compositionEnded() }
}

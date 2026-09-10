import SwiftUI
import AppKit
import ClearlineCore

enum Palette {
    static let ink = Color(red: 0.08, green: 0.15, blue: 0.17)
    static let mint = Color(red: 0.72, green: 0.88, blue: 0.73)
    static let teal = Color(nsColor: NSColor(name: "Clearline accent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.49, green: 0.77, blue: 0.63, alpha: 1)
            : NSColor(red: 0.13, green: 0.39, blue: 0.32, alpha: 1)
    })
    static let onAccent = Color(nsColor: NSColor(name: "Clearline accent text") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    })
    static let paper = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .windowBackgroundColor)
}

struct WorkspaceView: View {
    @ObservedObject var state: AppState
    @State private var category: SuggestionCategory?
    @State private var deleting: WritingDocument?
    var body: some View {
        HSplitView {
            navigation.frame(minWidth: 210, idealWidth: 235, maxWidth: 300)
            editorPane.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            suggestionPane.frame(minWidth: 290, idealWidth: 320, maxWidth: 390)
        }
        .background(Palette.paper)
        .frame(minWidth: 960, minHeight: 640)
        .tint(Palette.teal)
        .preferredColorScheme(state.preferences.appearance == "Dark" ? .dark : state.preferences.appearance == "Light" ? .light : nil)
        .sheet(isPresented: $state.showOnboarding) { OnboardingView(state: state) }
        .sheet(isPresented: $state.showSettings) { SettingsView(state: state) }
        .sheet(item: $state.tableSession) { session in MarkdownTableEditor(state: state, session: session) }
        .sheet(isPresented: $state.showHistory) { HistoryView(state: state) }
        .sheet(item: $state.aiSession) { session in AIReviewView(state: state, session: session, close: { session.cancel(); state.aiSession = nil }).frame(width: 780, height: 750) }
        .alert("\(Brand.name) needs your attention", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) { Button("OK") { state.error = nil } } message: { Text(state.error ?? "") }
        .alert("Delete this document?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let deleting { state.delete(deleting) }; deleting = nil }
        } message: { Text("The document and its local revision history will be deleted, including recovery copies. This cannot be undone.") }
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack { RoundedRectangle(cornerRadius: 10).fill(Palette.mint).frame(width: 32, height: 34); Image(systemName: "text.alignleft").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink) }
                Text(Brand.name).font(.system(size: 22, weight: .semibold, design: .rounded)).tracking(-0.7)
            }.padding(.top, 30).padding(.bottom, 28)
            Text("A LITTLE SPACE TO THINK").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.white.opacity(0.48)).padding(.bottom, 20)
            Button { state.newDocument() } label: {
                HStack { Image(systemName: "plus"); Text("New document"); Spacer(); Text("⌘N").font(.caption).opacity(0.6) }.font(.system(size: 12, weight: .medium)).padding(12).background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(!state.ready)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5)); TextField("Search your writing", text: $state.search).textFieldStyle(.plain).font(.system(size: 12)) }.padding(.vertical, 18)
            HStack { Text("YOUR DOCUMENTS").tracking(1.4); Spacer(); Text("\(state.library.documents.count)") }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(state.filteredDocuments) { document in
                        Button { state.select(document.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: document.format == .md ? "doc.plaintext" : "doc.text").font(.system(size: 16)).foregroundStyle(state.library.selectedID == document.id ? Palette.mint : .white.opacity(0.45)).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(document.title.isEmpty ? "Untitled" : document.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(document.modified.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(state.library.selectedID == document.id ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).contextMenu {
                            Button("Duplicate") { state.duplicate(document) }
                            Button("Delete", role: .destructive) { deleting = document }
                        }.accessibilityLabel("Open \(document.title)")
                    }
                }
            }
            Spacer(minLength: 10)
            HStack {
                Button { state.showSettings = true } label: { Label("Settings", systemImage: "gearshape").font(.system(size: 12)) }.buttonStyle(.plain)
                Spacer()
                Button { state.togglePause() } label: { Image(systemName: state.paused ? "play.circle" : "pause.circle") }.buttonStyle(.plain).help(state.paused ? "Resume checking" : "Pause checking")
            }.foregroundStyle(.white.opacity(0.7)).padding(.top, 20).padding(.bottom, 24)
        }.padding(.horizontal, 18).foregroundStyle(.white).background(Palette.ink).frame(maxHeight: .infinity)
    }
    private var editorPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("WORKSPACE", systemImage: "square.split.2x1").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Import text, Markdown, RTF, or DOCX…") { state.importDocument() }
                    Button("Export…") { state.exportDocument() }.disabled(state.current == nil)
                    Button("Copy full document") { state.editor.copyAll() }.disabled(state.current == nil)
                    Button("Copy selected text") { state.editor.copySelection() }.disabled(state.selection.length == 0)
                    Button("Revision history…") { state.showHistory = true }.disabled(state.current == nil)
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 24) }.menuStyle(.borderlessButton).frame(width: 32)
            }.padding(.horizontal, 30).frame(height: 59)
            Divider()
            if let document = state.current {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(document.format == .md ? "MARKDOWN" : document.format == .rtf ? "RICH TEXT" : "PLAIN TEXT").font(.system(size: 9, weight: .medium)).tracking(1.6).foregroundStyle(Palette.teal)
                        Spacer()
                        Label(state.saveStatus, systemImage: state.saveStatus == "Save failed" ? "exclamationmark.triangle" : "checkmark.icloud").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    TextField("Untitled", text: Binding(get: { state.current?.title ?? "" }, set: { state.rename($0) })).textFieldStyle(.plain).font(.system(size: 31, weight: .semibold, design: .serif)).accessibilityLabel("Document title")
                    HStack(spacing: 4) {
                        ForEach([("heading", "textformat.size"), ("bold", "bold"), ("italic", "italic"), ("list", "list.bullet"), ("link", "link")], id: \.0) { item in
                            Button { state.editor.format(item.0, document: document) } label: { Image(systemName: item.1).frame(width: 28, height: 26) }.buttonStyle(.plain).help("Insert \(item.0)").accessibilityLabel("Insert \(item.0)")
                                .disabled(document.format == .txt || state.isMarkdownPreview)
                        }
                        if document.format == .md {
                            Button { state.openTable() } label: { Image(systemName: "tablecells").frame(width: 28, height: 26) }
                                .buttonStyle(.plain).help("Insert or edit table").accessibilityLabel("Insert or edit table")
                                .disabled(state.isMarkdownPreview)
                        }
                        Spacer()
                        if document.format == .md {
                            Picker("Markdown view", selection: $state.showMarkdownPreview) {
                                Text("Edit").tag(false)
                                Text("Preview").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                                .help("Switch between Markdown source and preview · ⇧⌘P")
                        }
                        Button { state.showHistory = true } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 26, height: 26) }.buttonStyle(.plain).help("Revision history")
                    }.foregroundStyle(.secondary).font(.system(size: 12))
                }.padding(.horizontal, 38).padding(.top, 33).padding(.bottom, 12)
                ZStack {
                    // Keep the editor mounted so preview never resets selection or undo history.
                    NativeEditor(state: state, document: document)
                        .accessibilityHidden(state.isMarkdownPreview)
                    if state.isMarkdownPreview {
                        MarkdownPreview(text: document.text, textSize: state.preferences.textSize, documentID: document.id, zoom: state.workspaceZoom)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    editorFooter(fullMetrics: true)
                    editorFooter(fullMetrics: false)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 43).overlay(alignment: .top) { Divider() }
            } else {
                Spacer()
                Image(systemName: "square.and.pencil").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(Palette.teal)
                Text("A fresh page awaits.").font(.system(size: 26, design: .serif)).padding(12)
                Button("Create a document") { state.newDocument() }.buttonStyle(.borderedProminent).disabled(!state.ready)
                Spacer()
            }
        }.background(Palette.paper)
    }
    private func editorFooter(fullMetrics: Bool) -> some View {
        HStack(spacing: 18) {
            Text("\(state.metrics.words) words").fixedSize()
            if fullMetrics { Text("\(state.metrics.characters) characters").fixedSize() }
            Spacer(minLength: 8)
            WorkspaceZoomControl(state: state)
            if fullMetrics { Text("\(state.metrics.readingMinutes) min read").fixedSize() }
        }
    }
    private var suggestionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Writing assistant").font(.system(size: 13, weight: .semibold)); Spacer(); Image(systemName: "sparkle").foregroundStyle(Palette.teal) }.padding(.horizontal, 22).frame(height: 59)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Image(systemName: state.paused ? "pause.circle" : state.status.contains("Checking") ? "arrow.triangle.2.circlepath" : "checkmark.circle").foregroundStyle(Palette.teal); Text(state.status).font(.system(size: 11, weight: .medium)); Spacer(); Text(state.status.contains("OpenAI") ? "OPENAI CLOUD" : "ON DEVICE").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }
                        Text(state.suggestions.isEmpty ? "Write freely. Suggestions will appear here as you go." : "\(state.suggestions.count) \(state.suggestions.count == 1 ? "thing" : "things") to consider. You have the final say.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    }.padding(.top, 24)
                    HStack {
                        Menu { Button("All suggestions") { category = nil }; ForEach(SuggestionCategory.allCases, id: \.self) { item in Button("\(item.rawValue) (\(state.suggestions.filter { $0.category == item }.count))") { category = item } } }
                        label: { HStack { Text(category?.rawValue ?? "All suggestions"); Image(systemName: "chevron.down") }.font(.system(size: 10, weight: .medium)) }.menuStyle(.borderlessButton)
                        Spacer()
                        Button { state.nextIssue(-1) } label: { Image(systemName: "chevron.up") }.help("Previous suggestion · ⌥⌘↑")
                        Button { state.nextIssue(1) } label: { Image(systemName: "chevron.down") }.help("Next suggestion · ⌥⌘↓")
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    if state.suggestions.filter(\.batchSafe).count > 1 {
                        Button("Accept \(state.suggestions.filter(\.batchSafe).count) mechanical fixes") { state.acceptMechanical() }.font(.system(size: 10)).buttonStyle(.bordered)
                    }
                    LazyVStack(spacing: 12) {
                        ForEach(state.suggestions.filter { category == nil || $0.category == category }) { issue in
                            SuggestionCard(state: state, issue: issue)
                        }
                    }
                    if state.suggestions.isEmpty && state.status == "Ready" {
                        Label("No issues found by enabled checks.", systemImage: "checkmark.seal").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 15)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Image(systemName: "sparkles"); Text("A fresh perspective").fontWeight(.semibold) }.font(.system(size: 12))
                        Text("Find another way to say it, or start with a first draft.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                        Button { state.startAI() } label: { HStack { Text(state.selection.length > 0 ? "Rewrite selection" : "Explore writing tools"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 11, weight: .medium)).padding(11).background(Palette.teal, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(Palette.onAccent) }.buttonStyle(.plain).disabled(state.current == nil)
                        Text(state.hasKey ? "OpenAI cloud · review before applying" : "Optional · connect OpenAI in Settings").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(16).background(Palette.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text("WRITING GOALS").font(.system(size: 8, weight: .semibold)).tracking(1.4); Spacer(); Button("Edit") { state.showSettings = true }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.teal) }
                        Text("\(state.preferences.audience) audience · \(state.preferences.tone)").font(.system(size: 10))
                        Text(state.preferences.language == "en_GB" ? "British English" : state.preferences.language == "en_US" ? "American English" : state.preferences.language).font(.system(size: 10))
                        if state.metrics.words > 0 { Text("\(state.metrics.averageSentenceWords) words per sentence, on average").font(.system(size: 9)) }
                    }.foregroundStyle(.secondary).padding(.bottom, 20)
                }.padding(.horizontal, 20)
            }
        }.background(Palette.surface)
    }
}

struct SuggestionCard: View {
    @ObservedObject var state: AppState
    let issue: Suggestion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(issue.optional ? Color.orange : Color(red: 0.77, green: 0.29, blue: 0.23)).frame(width: 3, height: 13)
                Text(issue.category.rawValue.uppercased()).font(.system(size: 8, weight: .bold)).tracking(1.2)
                Spacer()
                Text(issue.optional ? "Suggestion" : "Correction").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(issue.original.replacingOccurrences(of: " ", with: "·")).strikethrough(issue.original != issue.replacement).foregroundStyle(.secondary).lineLimit(3)
                if issue.original != issue.replacement { HStack(alignment: .top) { Image(systemName: "arrow.turn.down.right").font(.system(size: 10)); Text(issue.replacement.isEmpty ? "Remove" : issue.replacement).fontWeight(.medium) }.foregroundStyle(Palette.teal) }
            }.font(.system(size: 13))
            Text(issue.explanation).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            HStack {
                if issue.original != issue.replacement { Button("Accept") { state.accept(issue) }.buttonStyle(.borderedProminent).controlSize(.small) }
                Button("Dismiss") { state.dismiss(issue) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if issue.category == .spelling { Button { state.learn(issue) } label: { Image(systemName: "text.badge.plus") }.buttonStyle(.plain).help("Add to personal dictionary") }
            }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Palette.paper, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(state.selectedIssue == issue.id ? Palette.teal.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1))
        .onTapGesture { state.selectedIssue = issue.id; state.editor.reveal(issue.range.nsRange) }
        .accessibilityElement(children: .contain).accessibilityLabel("\(issue.category.rawValue): \(issue.original)")
    }
}

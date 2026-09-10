import AppKit
import SwiftUI
import ClearlineCore

@MainActor
final class AppState: ObservableObject {
    @Published var library = Library()
    @Published var preferences = WritingPreferences()
    @Published var suggestions: [Suggestion] = []
    @Published var selectedIssue: UUID?
    @Published var search = ""
    @Published var status = "Loading"
    @Published var saveStatus = "Opening library"
    @Published var error: String?
    @Published var paused = false
    @Published var ready = false
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var metrics = TextMetrics("")
    @Published var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var showMarkdownPreview = false
    var isMarkdownPreview: Bool { showMarkdownPreview && current?.format == .md }
    var workspaceZoom: Double { WorkspaceZoom.clamped(preferences.workspaceZoom) }
    func setWorkspaceZoom(_ value: Double) {
        preferences.workspaceZoom = WorkspaceZoom.clamped(value)
        preferencesChanged(reanalyze: false)
    }
    @Published var aiSession: AISession?
    @Published var availableModels: [ModelCapability] = []
    @Published var modelStatus = "Connect OpenAI to load available models."
    @Published var hasKey = false
    @Published var apiUsage = UsageLedger()
    @Published var usageError: String?
    @Published var usageLoaded = false
    @Published var crossAppMessage: String?
    let store: DocumentStore
    let usageStore: UsageStore
    let spelling = NativeSpelling()
    let editor = EditorBridge()
    var crossApp: CrossAppController?
    private var analysisTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var preferencesTask: Task<Void, Never>?
    private var dismissed: Set<String> = []
    private var purgeOnSave = false
    private var analysisGeneration = UUID()
    private var lastHistory: [UUID: Date] = [:]
    init(directory: URL? = nil, autoload: Bool = true) {
        let override = ProcessInfo.processInfo.environment["CLEARLINE_DATA_DIR"]
        let root = directory ?? override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Brand.name)
        store = DocumentStore(directory: root)
        usageStore = UsageStore(directory: root)
        editor.showSource = { [weak self] in
            self?.showMarkdownPreview = false
            self?.editor.textView?.enclosingScrollView?.isHidden = false
        }
        if autoload { Task { await refreshUsage(); await load() } }
    }
    var current: WritingDocument? { library.documents.first { $0.id == library.selectedID } }
    var filteredDocuments: [WritingDocument] {
        library.documents.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) }.sorted { $0.modified > $1.modified }
    }
    func load() async {
        do {
            let loaded = try await store.load()
            library = loaded.0
            preferences = try await store.loadPreferences()
            if library.documents.isEmpty {
                let welcome = WritingDocument(title: "A little more clarity", text: "Good writing starts with a little space.\n\nThis is your place to think, draft, and find the right words. Clearline keeps your documents on this Mac and gives you useful feedback as you write.\n\nTry it for yourself\n\nIn order to make this introduction more concise, we can remove a few unnecessary words. There are  two spaces here, and this sentence has a mispelled word.\n\nYour words, your call\n\nReview a suggestion on the right. Accept what helps and dismiss what doesn't. Every change is yours to make—and yours to undo.\n\nWhen you're ready, connect OpenAI in Settings for rewrites, new drafts, and a fresh perspective.")
                library.documents = [welcome]; library.selectedID = welcome.id
            }
            if current == nil { library.selectedID = library.documents.first?.id }
            ready = true; saveStatus = loaded.recovered ? "Recovered from backup" : "Saved on this Mac"
            hasKey = (try? KeychainCredential.read()) != nil
            crossApp = CrossAppController(state: self)
            crossApp?.configure()
            scheduleAnalysis(); scheduleSave()
            if hasKey { await refreshModels() }
        } catch { self.error = "Could not open the library: \(error.localizedDescription)"; status = "Unavailable" }
    }
    func select(_ id: UUID) {
        guard library.selectedID != id else { return }
        library.selectedID = id; selection = NSRange(location: 0, length: 0)
        dismissed.removeAll(); scheduleAnalysis(); scheduleSave()
    }
    func newDocument(text: String = "", title: String = "Untitled", format: DocumentFormat = .md, richText: Data? = nil) {
        guard ready else { return }
        var doc = WritingDocument(title: title, text: text, format: format); doc.richText = richText
        library.documents.append(doc); select(doc.id)
    }
    func rename(_ title: String) {
        guard let index = library.documents.firstIndex(where: { $0.id == library.selectedID }) else { return }
        library.documents[index].title = title; library.documents[index].modified = Date(); scheduleSave()
    }
    func duplicate(_ document: WritingDocument) { newDocument(text: document.text, title: document.title + " copy", format: document.format, richText: document.richText) }
    func delete(_ document: WritingDocument) {
        library.documents.removeAll { $0.id == document.id }; library.revisions.removeAll { $0.document.id == document.id }
        if library.selectedID == document.id { library.selectedID = library.documents.first?.id }
        purgeOnSave = true; scheduleSave(); scheduleAnalysis()
    }
    func recordRevision(_ document: WritingDocument, force: Bool = false) {
        if force || Date().timeIntervalSince(lastHistory[document.id] ?? .distantPast) >= 60 {
            if library.revisions.last(where: { $0.document.id == document.id })?.document != document {
                library.revisions.append(Revision(document: document))
                let ids = library.revisions.filter { $0.document.id == document.id }.suffix(50).map(\.id)
                library.revisions.removeAll { $0.document.id == document.id && !ids.contains($0.id) }
            }
            lastHistory[document.id] = Date()
        }
    }
    func textChanged(_ text: String, richText: Data?) {
        guard let index = library.documents.firstIndex(where: { $0.id == library.selectedID }) else { return }
        let old = library.documents[index]
        guard old.text != text || old.richText != richText else { return }
        recordRevision(old)
        library.documents[index].update(text: text, richText: richText)
        dismissed.removeAll(); suggestions = []; saveStatus = "Saving…"; scheduleSave(); scheduleAnalysis()
    }
    func compositionBegan() { analysisTask?.cancel(); suggestions = []; status = "Waiting for input" }
    func compositionEnded() { scheduleAnalysis() }
    func scheduleSave() {
        guard ready else { return }
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let snapshot = library, purge = purgeOnSave
                try await store.save(snapshot, purgeBackup: purge)
                if purge { purgeOnSave = false }
                saveStatus = "Saved on this Mac"
            } catch is CancellationError {} catch { self.error = "Autosave failed: \(error.localizedDescription)"; saveStatus = "Save failed" }
        }
    }
    func flush() async throws { saveTask?.cancel(); try await store.save(library, purgeBackup: purgeOnSave); try await store.savePreferences(preferences) }
    func preferencesChanged(reanalyze: Bool = true) {
        preferencesTask?.cancel()
        let snapshot = preferences
        preferencesTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)); try await store.savePreferences(snapshot) }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        if reanalyze { scheduleAnalysis() }
    }
    func scheduleAnalysis() {
        analysisTask?.cancel(); suggestions = []; selectedIssue = nil
        let generation = UUID(); analysisGeneration = generation
        guard let document = current else { status = "Ready"; metrics = TextMetrics(""); return }
        guard !paused else { status = "Paused"; return }
        let prefs = preferences
        status = "Checking"
        analysisTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(450))
                let worker = Task.detached(priority: .utility) { (LocalRules.analyze(document, preferences: prefs), TextMetrics(document.text)) }
                let local = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                let native = await spelling.analyze(document, preferences: prefs)
                try Task.checkCancellation()
                guard analysisGeneration == generation, current?.id == document.id, current?.revision == document.revision else { return }
                suggestions = EditEngine.resolve(native + local.0, in: document).filter { !dismissed.contains($0.dismissalKey) }
                metrics = local.1
                status = spelling.engineLanguage(prefs.language) != nil ? "Ready" : "Spelling unavailable"
                if prefs.cloudAutomatic && hasKey && !document.text.isEmpty { await analyzeCloud(document, generation: generation) }
            } catch is CancellationError {} catch { status = "Error"; self.error = error.localizedDescription }
        }
    }
    func accept(_ suggestion: Suggestion) {
        guard let document = current else { return }
        do { try EditEngine.validate(suggestion, in: document); recordRevision(document, force: true); try editor.apply([suggestion], document: document) }
        catch { self.error = error.localizedDescription }
    }
    func acceptMechanical() {
        guard let document = current else { return }
        let safe = suggestions.filter(\.batchSafe)
        do { _ = try EditEngine.approved(safe, in: document, batch: true); recordRevision(document, force: true); try editor.apply(safe, document: document, batch: true) }
        catch { self.error = error.localizedDescription }
    }
    func dismiss(_ suggestion: Suggestion) { dismissed.insert(suggestion.dismissalKey); suggestions.removeAll { $0.id == suggestion.id } }
    func learn(_ suggestion: Suggestion) { preferences.dictionary.insert(suggestion.original.lowercased()); preferencesChanged() }
    func nextIssue(_ direction: Int) {
        guard !suggestions.isEmpty else { return }
        let old = suggestions.firstIndex { $0.id == selectedIssue } ?? (direction > 0 ? -1 : 0)
        let issue = suggestions[(old + direction + suggestions.count) % suggestions.count]
        selectedIssue = issue.id; editor.reveal(issue.range.nsRange)
    }
    func togglePause() { paused.toggle(); crossApp?.invalidate(); scheduleAnalysis() }
    func restore(_ revision: Revision) {
        guard let document = current, document.id == revision.document.id else { return }
        recordRevision(document, force: true)
        editor.replaceAll(revision.document.text, richText: revision.document.richText, action: "Restore revision")
    }
    func deleteHistory() { guard let id = current?.id else { return }; library.revisions.removeAll { $0.document.id == id }; purgeOnSave = true; scheduleSave() }
}

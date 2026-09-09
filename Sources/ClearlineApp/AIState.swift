import AppKit
import SwiftUI
import ClearlineCore

@MainActor
final class AISession: ObservableObject, Identifiable {
    let id = UUID()
    let original: String
    let documentID: UUID?
    let revision: Int?
    let range: UTF16Range
    let external: ExternalSelection?
    @Published var action: WritingAction
    @Published var instructions = ""
    @Published var model: String
    @Published var effort: String
    @Published var selectionNotice = ""
    @Published var result: WritingResult?
    @Published var warnings: [String] = []
    @Published var diff: [DiffToken] = []
    @Published var error: String?
    @Published var running = false
    @Published var received = 0
    @Published var effective = ""
    @Published var stale = false
    @Published var confirmedChanges = false
    @Published var applied = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(original: String, documentID: UUID?, revision: Int?, range: UTF16Range, action: WritingAction, preferences: WritingPreferences, external: ExternalSelection? = nil) {
        self.original = original; self.documentID = documentID; self.revision = revision; self.range = range; self.action = action
        self.model = preferences.model; self.effort = preferences.effort; self.external = external
    }
    func changeModel(_ id: String) {
        model = id
        guard let capability = ModelCapability.catalog.first(where: { $0.id == id }) else { return }
        let normalized = capability.validatedEffort(effort)
        if normalized != effort { selectionNotice = normalized.isEmpty ? "This model does not support adjustable reasoning." : "Reasoning changed to \(normalized), a supported setting for \(id)." }
        effort = normalized
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; running = false }
    func run(state: AppState) {
        cancel()
        let operation = UUID(); generation = operation
        let previous = result?.text
        result = nil; diff = []; warnings = []; confirmedChanges = false; error = nil; received = 0; applied = false
        let capturedAction = action
        do {
            guard state.availableModels.contains(where: { $0.id == model }) else { throw ProviderError.unavailableModel }
            let config = try RequestConfiguration(model: model, effort: effort, maxOutputTokens: state.preferences.maxOutputTokens, timeout: state.preferences.timeoutSeconds)
            let request = WritingRequest(action: capturedAction, text: original, instructions: instructions, previous: previous, preferences: state.preferences, configuration: config)
            let provider = try state.makeProvider()
            effective = "\(config.model) · \(config.effort ?? "no adjustable reasoning") · OpenAI cloud"
            running = true
            task = Task {
                do {
                    let result = try await provider.perform(request) { [weak self] count in await self?.receiveProgress(count, operation: operation) }
                    try Task.checkCancellation()
                    if capturedAction == .analyze {
                        let source = WritingDocument(text: original, revision: revision ?? 0)
                        _ = try result.suggestions(for: source)
                    }
                    let checks = await Task.detached(priority: .utility) {
                        (TextDiff.tokens(before: self.original, after: result.text), PreservationCheck.warnings(before: self.original, after: result.text, preferences: request.preferences))
                    }.value
                    guard generation == operation else { return }
                    self.result = result; self.diff = checks.0; self.warnings = result.warnings + (capturedAction.analysisOnly ? [] : checks.1)
                    running = false
                    if let documentID { stale = state.current?.id != documentID || state.current?.revision != revision }
                } catch is CancellationError { if generation == operation { running = false } }
                catch { if generation == operation { self.error = error.localizedDescription; running = false } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func receiveProgress(_ count: Int, operation: UUID) { if generation == operation { received = count } }
    func apply(state: AppState) {
        guard let result, !running, !applied else { return }
        do {
            if let external {
                guard let controller = state.crossApp else { throw CrossAppError.changed }
                try controller.replace(external, with: result.text)
            } else {
                guard let document = state.current, document.id == documentID, document.revision == revision else { stale = true; throw EditError.stale }
                if action == .analyze {
                    let source = WritingDocument(text: original, revision: document.revision)
                    let edits = try result.suggestions(for: source).map { item -> Suggestion in
                        var moved = item; moved.range.location += range.location; return moved
                    }
                    state.suggestions = EditEngine.resolve(state.suggestions + edits, in: document)
                } else if action == .voice {
                    state.preferences.voiceProfile = result.explanation; state.preferencesChanged()
                } else {
                    let edit = Suggestion(revision: document.revision, category: .clarity, rule: "openai.rewrite", original: original, replacement: result.text, explanation: result.explanation, range: range, optional: true)
                    try EditEngine.validate(edit, in: document); state.recordRevision(document, force: true); try state.editor.apply([edit], document: document)
                }
            }
            applied = true
        } catch { self.error = error.localizedDescription }
    }
    func copy() { guard let result else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.text, forType: .string) }
}

extension AppState {
    func makeProvider() throws -> any WritingProvider {
        guard let key = try KeychainCredential.read() else { throw ProviderError.missingKey }
        if preferences.useAgentService { return AgentProcessProvider(key: key) }
        return OpenAIProvider(key: key)
    }
    func refreshModels() async {
        do {
            guard let key = try KeychainCredential.read() else { hasKey = false; availableModels = []; throw ProviderError.missingKey }
            hasKey = true; modelStatus = "Loading available models…"
            availableModels = try await OpenAIProvider(key: key).models()
            modelStatus = availableModels.isEmpty ? "No verified text models are available to this account." : "\(availableModels.count) verified text models available."
            if !availableModels.contains(where: { $0.id == preferences.model }) { modelStatus += " Choose an available model; your saved choice has not been changed." }
        } catch { modelStatus = error.localizedDescription }
    }
    func startAI(_ action: WritingAction = .clarity, wholeDocument: Bool = false, paragraph: Bool = false) {
        guard let document = current else { return }
        let range = paragraph ? UTF16Range((document.text as NSString).paragraphRange(for: selection)) : !wholeDocument && selection.length > 0 ? UTF16Range(selection) : UTF16Range(0, document.text.utf16.count)
        guard let source = try? EditEngine.substring(document.text, range: range) else { return }
        aiSession?.cancel()
        aiSession = AISession(original: source, documentID: document.id, revision: document.revision, range: range, action: action, preferences: preferences)
    }
    func analyzeCloud(_ document: WritingDocument, generation: UUID) async {
        guard current?.id == document.id, current?.revision == document.revision, !paused else { return }
        do {
            guard availableModels.contains(where: { $0.id == preferences.model }) else { return }
            let configuration = try RequestConfiguration(model: preferences.model, effort: preferences.effort, maxOutputTokens: preferences.maxOutputTokens, timeout: preferences.timeoutSeconds)
            let request = WritingRequest(action: .analyze, text: document.text, instructions: "Offer only clear, useful improvements.", preferences: preferences, configuration: configuration)
            status = "Checking · OpenAI cloud"
            let result = try await makeProvider().perform(request) { _ in }
            try Task.checkCancellation()
            guard current?.id == document.id, current?.revision == document.revision, !paused else { return }
            let proposals = try result.suggestions(for: document).filter { issue in
                !LocalRules.protectedRanges(document.text, preferences: preferences).contains { NSIntersectionRange($0, issue.range.nsRange).length > 0 }
            }
            suggestions = EditEngine.resolve(suggestions + proposals, in: document); status = "Ready"
        } catch is CancellationError {} catch { status = "Cloud unavailable"; self.error = error.localizedDescription }
    }
}

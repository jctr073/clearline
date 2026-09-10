import SwiftUI
import ClearlineCore

struct AIReviewView: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: AISession
    let close: () -> Void
    @State private var showDiff = true
    private var capability: ModelCapability? { state.availableModels.first { $0.id == session.model } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(Palette.teal)
                Text(session.external == nil ? "Find the right words" : "Selected text · \(session.external!.appName)").font(.system(size: 22, weight: .medium, design: .serif))
                Spacer(); Button { session.cancel(); close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close writing tools")
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        Picker("Action", selection: $session.action) { ForEach(WritingAction.allCases.filter { $0 != .voice }) { Text($0.rawValue).tag($0) } }.frame(maxWidth: .infinity)
                        WritingModelPicker(available: state.availableModels, selection: Binding(get: { session.model }, set: { session.changeModel($0) }))
                            .frame(maxWidth: .infinity)
                    }.disabled(session.running)
                    HStack {
                        ReasoningEffortPicker(model: session.model, selection: $session.effort)
                            .frame(width: 280).disabled(session.running)
                        Spacer()
                        Text("Higher effort can increase response time and cost.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if !session.selectionNotice.isEmpty { Text(session.selectionNotice).font(.caption).foregroundStyle(.secondary) }
                    TextField(session.action == .translate ? "Target language (required), e.g. Spanish" : "Add instructions, notes, or a follow-up…", text: $session.instructions, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(session.running)
                    if session.result == nil {
                        Label("OpenAI cloud", systemImage: "cloud").font(.system(size: 11, weight: .semibold))
                        Text("Send only the text shown below, these instructions, and your writing goals. If you regenerate, the previous proposal is also sent. Your original stays unchanged until you accept. Provider data handling is governed by your OpenAI account terms.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !state.hasKey {
                        HStack { Text("Connect an OpenAI key to use these tools."); Spacer(); Button("Open Settings") { close(); state.showSettings = true } }.font(.caption).padding(12).background(Palette.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if session.documentID != nil && state.current?.format == .rtf {
                        Label("A rewrite may flatten formatting inside the selected passage. Formatting outside it is preserved.", systemImage: "textformat").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("ORIGINAL · \(session.original.count) CHARACTERS").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Spacer()
                        if session.external != nil { Text("Transient · not saved").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    Text(session.original.isEmpty ? "Empty document — describe what to draft above." : session.original).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    if let result = session.result {
                        Divider()
                        HStack { Text("PROPOSAL").font(.system(size: 9, weight: .semibold)).tracking(1.2); Spacer(); Toggle("Show changes", isOn: $showDiff).toggleStyle(.switch).controlSize(.mini).font(.caption) }
                        if showDiff && !session.action.analysisOnly { diffText.font(.system(size: 14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8)) }
                        else { Text(result.text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled) }
                        Text(result.explanation).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        if !result.tone.isEmpty { Label("Tone: \(result.tone)", systemImage: "waveform").font(.system(size: 11)) }
                        ForEach(Array(result.recommendations.enumerated()), id: \.offset) { _, recommendation in Label(recommendation, systemImage: "lightbulb").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                        if !session.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(session.warnings.enumerated()), id: \.offset) { _, warning in Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11)) }
                                Toggle("I reviewed these possible changes", isOn: $session.confirmedChanges).font(.system(size: 11))
                            }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("Fact preservation is not guaranteed. Review every proposal.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if session.stale { Label("Your source changed. Copy the proposal or start a fresh capture.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if session.applied { Label("Applied", systemImage: "checkmark.circle").foregroundStyle(Palette.teal) }
                }.padding(24)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text(session.running ? session.effective : "\(session.model) · \(session.effort.isEmpty ? "API-default reasoning" : session.effort) · OpenAI cloud").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    if session.running {
                        ProgressView().controlSize(.small); Text(session.received > 0 ? "Receiving proposal… \(session.received) characters" : "Thinking…").font(.caption)
                        Spacer(); Button("Cancel request") { session.cancel() }
                    } else {
                        Button(session.result == nil ? "Generate proposal" : "Regenerate with instructions") { session.run(state: state) }.buttonStyle(.borderedProminent)
                            .disabled(!state.hasKey || capability == nil || session.stale || (session.action == .translate && session.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        Spacer()
                        if session.result != nil {
                            Button("Copy") { session.copy() }
                            if ![WritingAction.tone, .context, .voice].contains(session.action) {
                                Button(session.action == .analyze ? "Review suggestions" : session.external == nil ? "Accept change" : "Replace selection") { session.apply(state: state) }
                                    .disabled(session.stale || session.applied || (!session.warnings.isEmpty && !session.confirmedChanges))
                            }
                        }
                    }
                }
            }.padding(20)
        }.tint(Palette.teal).background(Palette.paper)
        .onChange(of: state.current?.revision) { _, new in if !session.applied && session.documentID != nil && new != session.revision { session.stale = true } }
        .onChange(of: session.action) { _, _ in session.cancel(); session.result = nil; session.diff = []; session.warnings = [] }
        .onDisappear { session.cancel() }
    }
    private var diffText: Text {
        session.diff.reduce(Text("")) { partial, token in
            switch token.kind {
            case .unchanged: return partial + Text(token.text)
            case .removed: return partial + Text(token.text).foregroundColor(.red).strikethrough()
            case .added: return partial + Text(token.text).foregroundColor(Palette.teal).bold().underline()
            }
        }
    }
}

import SwiftUI
import ClearlineCore

struct QuickWritingView: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: AISession
    let close: () -> Void

    private var stale: Bool {
        state.current?.id != session.documentID || state.current?.revision != session.revision
    }
    private var needsInstructions: Bool { session.action == .translate || session.action == .custom }
    private var canGenerate: Bool {
        !stale && state.hasKey && state.availableModels.contains { $0.id == session.model }
            && (!needsInstructions || !session.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(session.action.rawValue, systemImage: "sparkles").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close proposal")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if session.running {
                        HStack { ProgressView().controlSize(.small); Text("Writing a proposal…") }
                    } else if let result = session.result {
                        if state.preferences.showWritingChanges && !session.action.analysisOnly {
                            diffText.textSelection(.enabled)
                        } else {
                            Text(result.text).textSelection(.enabled)
                        }
                        if session.action.analysisOnly {
                            Text(result.explanation).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        ForEach(Array(result.recommendations.enumerated()), id: \.offset) { _, text in
                            Label(text, systemImage: "lightbulb").font(.caption)
                        }
                        ForEach(Array(session.warnings.enumerated()), id: \.offset) { _, text in
                            Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    } else if needsInstructions {
                        Text(session.action == .translate ? "Enter a target language below." : "Describe how you’d like to rewrite this text.")
                    }
                    if stale { Label("The document changed. Start again from the right-click menu.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if !state.hasKey {
                        Button("Connect OpenAI in Settings") { close(); state.showSettings = true }
                    } else if !state.availableModels.contains(where: { $0.id == session.model }) {
                        Button("Choose an available model in Settings") { close(); state.showSettings = true }
                    }
                }.font(.system(size: 14)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.frame(minHeight: 80, maxHeight: 320)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                TextField(session.action == .translate ? "Target language, e.g. Spanish" : "Instructions or follow-up…", text: $session.instructions, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).disabled(session.running)
                HStack {
                    Text("\(session.model) · \(session.effort.isEmpty ? "Default reasoning" : session.effort) · OpenAI cloud")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if session.result != nil && !session.action.analysisOnly {
                        Toggle("Show changes", isOn: Binding(get: { state.preferences.showWritingChanges }, set: { state.setShowWritingChanges($0) }))
                            .toggleStyle(.checkbox).font(.caption)
                    }
                }
                HStack {
                    if session.running {
                        Button("Cancel") { session.cancel() }
                    } else {
                        Button(session.result == nil ? "Generate" : "Regenerate") { session.run(state: state) }.disabled(!canGenerate)
                    }
                    Spacer()
                    if session.result != nil {
                        Button("Copy") { session.copy() }
                        if !session.action.analysisOnly || session.action == .analyze {
                            Button(session.action == .analyze ? "Review suggestions" : "Replace") {
                                session.apply(state: state)
                                if session.applied { close() }
                            }.disabled(stale || session.running || session.applied)
                        }
                    }
                }
            }.padding(16)
        }.frame(width: 480).tint(Palette.teal)
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

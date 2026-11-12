import SwiftUI
import ClearlineCore

struct QuickWritingView: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: AISession
    /// Quick edit opens on the prompt alone and grows once there is a proposal to review.
    var quickEdit = false
    let close: () -> Void
    @FocusState private var promptFocused: Bool

    private var stale: Bool {
        state.current?.id != session.documentID || state.current?.revision != session.revision
    }
    private var needsInstructions: Bool { session.action == .translate || session.action == .custom }
    private var modelAvailable: Bool { state.availableModels.contains { $0.id == session.model } }
    private var canGenerate: Bool {
        !stale && state.hasKey && modelAvailable
            && (!needsInstructions || !session.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var canReplace: Bool {
        session.result != nil && (!session.action.analysisOnly || session.action == .analyze)
            && !stale && !session.running && !session.applied
    }
    private var compact: Bool {
        quickEdit && session.result == nil && !session.running && session.error == nil
            && !stale && state.hasKey && modelAvailable
    }
    private var scope: String {
        session.original.utf16.count == state.current?.text.utf16.count ? "Whole document" : "Selection"
    }
    private var placeholder: String {
        if session.action == .translate { return "Target language, e.g. Spanish" }
        if quickEdit { return session.result == nil ? "Describe the change…" : "Refine it, or describe another change…" }
        return "Instructions or follow-up…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                HStack {
                    Label(quickEdit ? "Quick edit" : session.action.rawValue, systemImage: "sparkles").font(.headline)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close proposal")
                }.padding(16)
                Divider()
                ScrollView { proposal }.frame(minHeight: quickEdit ? 40 : 80, maxHeight: 320)
                Divider()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if compact { Image(systemName: "sparkles").foregroundStyle(Palette.teal) }
                    TextField(placeholder, text: $session.instructions, axis: .vertical)
                        .lineLimit(1...3).textFieldStyle(.roundedBorder).disabled(session.running)
                        .focused($promptFocused)
                        .onSubmit { if canGenerate && !session.running { session.run(state: state) } }
                        .accessibilityLabel(quickEdit ? "Quick edit instructions" : "Instructions")
                }
                if compact {
                    Text("\(scope) · Return to generate · Esc to close").font(.caption2).foregroundStyle(.secondary)
                } else {
                    controls
                }
            }.padding(16)
        }.frame(width: quickEdit ? 420 : 480).tint(Palette.teal)
        .onAppear { if needsInstructions { DispatchQueue.main.async { promptFocused = true } } }
        // The field is disabled while generating, which drops focus; return it for follow-ups.
        .onChange(of: session.running) { _, running in if !running && needsInstructions { promptFocused = true } }
        .onExitCommand(perform: close)
        .onDisappear { session.cancel() }
    }

    private var proposal: some View {
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
            } else if needsInstructions && !quickEdit {
                Text(session.action == .translate ? "Enter a target language below." : "Describe how you’d like to rewrite this text.")
            }
            if stale { Label("The document changed. Start again from the right-click menu.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !state.hasKey {
                Button("Connect OpenAI in Settings") { close(); state.showSettings = true }
            } else if !modelAvailable {
                Button("Choose an available model in Settings") { close(); state.showSettings = true }
            }
        }.font(.system(size: 14)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    @ViewBuilder private var controls: some View {
        let showsToggle = session.result != nil && !session.action.analysisOnly
        if !quickEdit || showsToggle {
            HStack {
                if !quickEdit {
                    Text("\(session.model) · \(session.effort.isEmpty ? "Default reasoning" : session.effort) · OpenAI cloud")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if showsToggle {
                    Toggle("Show changes", isOn: Binding(get: { state.preferences.showWritingChanges }, set: { state.setShowWritingChanges($0) }))
                        .toggleStyle(.checkbox).font(.caption)
                }
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
                    }.disabled(!canReplace).keyboardShortcut(.return, modifiers: .command).help("⌘Return")
                }
            }
        }
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

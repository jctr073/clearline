import SwiftUI
import ServiceManagement
import AppKit
import ClearlineCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var tab = "Writing"
    @State private var key = ""
    @State private var word = ""
    @State private var discouraged = ""
    @State private var preferred = ""
    @State private var appID = ""
    @State private var message = ""
    @State private var voiceTask: Task<Void, Never>?
    @State private var describingVoice = false
    private let tabs = ["Writing", "OpenAI", "Dictionary", "Cross-app", "Privacy", "Languages"]
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("\(Brand.name) settings").font(.system(size: 23, weight: .medium, design: .serif)); Spacer(); Button("Done") { state.showSettings = false; dismiss() }.keyboardShortcut(.defaultAction) }.padding(24)
            Picker("Settings section", selection: $tab) { ForEach(tabs, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 18)
            Divider()
            ScrollView {
                Form {
                    switch tab {
                    case "OpenAI": openAI
                    case "Dictionary": dictionary
                    case "Cross-app": crossApp
                    case "Privacy": privacy
                    case "Languages": languages
                    default: writing
                    }
                    if !message.isEmpty { Section { Text(message).font(.caption).textSelection(.enabled) } }
                }.formStyle(.grouped).padding(10)
            }
        }.frame(width: 760, height: 710).tint(Palette.teal)
        .onChange(of: state.preferences) { _, _ in state.preferencesChanged() }
        .onDisappear { voiceTask?.cancel() }
    }
    private var writing: some View {
        Group {
            Section("Writing goals") {
                Picker("Audience", selection: $state.preferences.audience) { ForEach(["General", "Knowledgeable", "Expert"], id: \.self) { Text($0) } }
                Picker("Context", selection: $state.preferences.context) { ForEach(["Email", "Professional document", "Casual message", "Technical writing", "Academic writing"], id: \.self) { Text($0) } }
                Picker("Tone", selection: $state.preferences.tone) { ForEach(["Neutral", "Professional", "Friendly", "Confident", "Concise"], id: \.self) { Text($0) } }
                Picker("English dialect", selection: $state.preferences.language) { Text("American English").tag("en_US"); Text("British English").tag("en_GB"); ForEach(state.spelling.languages.filter { !["en_US", "en_GB"].contains($0) }, id: \.self) { Text($0).tag($0) } }
                TextField("Additional style instructions", text: $state.preferences.instructions, axis: .vertical).lineLimit(2...5)
            }
            Section("Local checks") {
                ForEach(SuggestionCategory.allCases, id: \.self) { category in
                    Toggle(category.rawValue, isOn: Binding(get: { !state.preferences.disabledCategories.contains(category) }, set: { if $0 { state.preferences.disabledCategories.remove(category) } else { state.preferences.disabledCategories.insert(category) } }))
                }
                Toggle("Suggest reviewing possible passive voice", isOn: $state.preferences.passiveVoice)
                Picker("Punctuation style", selection: $state.preferences.punctuationStyle) { Text("Preserve").tag("Preserve"); Text("Avoid em dashes").tag("Avoid em dashes") }
                Toggle("Protect code blocks and inline code", isOn: $state.preferences.protectCode)
                Toggle("Protect quoted passages", isOn: $state.preferences.protectQuotes)
                Text("URLs and recognizable identifiers are excluded from local edits. Proper-name detection is conservative and incomplete. Review unfamiliar names before accepting spelling changes.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $state.preferences.appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                Slider(value: $state.preferences.textSize, in: 14...26, step: 1) { Text("Editor text size: \(Int(state.preferences.textSize))") }
                Toggle("Launch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; message = enabled ? "Launch at login registered. System Settings may need approval." : "Launch at login disabled." } catch { message = error.localizedDescription }
                }))
            }
            Section("Individual rules") {
                ForEach(["spaces", "repeated-word", "space-before-punctuation", "capital-i", "wordiness", "terminology", "em-dash", "passive", "apple-spelling", "apple-grammar"], id: \.self) { rule in
                    Toggle(rule.replacingOccurrences(of: "-", with: " ").capitalized, isOn: Binding(get: { !state.preferences.disabledRules.contains("local." + rule) }, set: { enabled in
                        if enabled { state.preferences.disabledRules.remove("local." + rule) } else { state.preferences.disabledRules.insert("local." + rule) }
                    }))
                }
            }
        }
    }
    private var openAI: some View {
        Group {
            Section("Optional cloud writing tools") {
                Text("Your documents remain local. When you request an AI operation, Clearline sends the selected text, your instructions, and writing goals to OpenAI. Regeneration includes the prior proposal. No clipboard or background-app content is sent automatically.").font(.callout)
                Link("Review OpenAI API data controls", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                SecureField("OpenAI API key", text: $key)
                HStack {
                    Button("Save to Keychain") { configureKey { try KeychainCredential.save(key) }; key = "" }.disabled(key.isEmpty)
                    Button("Import from ~/.zshrc") { configureKey { try KeychainCredential.importShellAssignment() } }
                    Button("Remove key", role: .destructive) { do { try KeychainCredential.delete(); state.hasKey = false; state.availableModels = []; state.preferences.cloudAutomatic = false; message = "OpenAI key removed from Keychain." } catch { message = error.localizedDescription } }
                }
                Text("Import reads a literal key assignment without running your shell configuration. Credentials are stored in this Mac's Keychain, never in documents or preferences.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Model defaults") {
                Picker("Model", selection: Binding(get: { state.preferences.model }, set: { new in
                    state.preferences.model = new
                    if let capability = state.availableModels.first(where: { $0.id == new }) {
                        let normalized = capability.validatedEffort(state.preferences.effort)
                        if normalized != state.preferences.effort { message = normalized.isEmpty ? capability.reasoningDescription : "Reasoning set to \(normalized) for \(new)." }
                        state.preferences.effort = normalized
                    }
                })) {
                    if !state.availableModels.contains(where: { $0.id == state.preferences.model }) { Text("\(state.preferences.model) · unavailable").tag(state.preferences.model) }
                    ForEach(state.availableModels) { Text($0.displayName).tag($0.id) }
                }
                if let model = state.availableModels.first(where: { $0.id == state.preferences.model }), !model.efforts.isEmpty {
                    Picker("Reasoning effort", selection: $state.preferences.effort) { ForEach(model.efforts, id: \.self) { Text($0.capitalized).tag($0) } }
                } else { Text(ModelCapability.capability(for: state.preferences.model).reasoningDescription).font(.caption).foregroundStyle(.secondary) }
                Text("Higher reasoning effort may increase response time and cost. Each operation captures its settings when sent.").font(.caption).foregroundStyle(.secondary)
                Text("Refresh checks your account directly. The list includes models for other uses; discovery does not verify writing support.").font(.caption).foregroundStyle(.secondary)
                HStack { Text(state.modelStatus).font(.caption); Spacer(); Button("Refresh models") { Task { await state.refreshModels() } }.disabled(!state.hasKey) }
            }
            UsageSettingsView(state: state)
            Section("Request limits") {
                Stepper("Input limit: \(state.preferences.maxInputCharacters) characters", value: $state.preferences.maxInputCharacters, in: 2000...60000, step: 2000)
                Stepper("Output limit: \(state.preferences.maxOutputTokens) tokens", value: $state.preferences.maxOutputTokens, in: 1024...16384, step: 1024)
                Stepper("Timeout: \(state.preferences.timeoutSeconds) seconds", value: $state.preferences.timeoutSeconds, in: 15...300, step: 15)
                Toggle("Continuously check this editor with OpenAI", isOn: $state.preferences.cloudAutomatic).disabled(!state.hasKey)
                Text("Off by default. When enabled, document text is sent after typing pauses. Each request is bounded by your input limit. Cross-app text is never included.").font(.caption).foregroundStyle(.secondary)
                Toggle("Use local OpenAI Agents SDK runtime", isOn: $state.preferences.useAgentService)
                Text("Requires the separately installed Python environment described in README. With this off, the Swift client uses OpenAI's Responses API directly. Both use the same structured proposal format.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func configureKey(_ action: () throws -> Void) {
        do { try action(); state.hasKey = true; message = "Credential stored in Keychain."; Task { await state.refreshModels() } }
        catch { message = error.localizedDescription }
    }
    private var dictionary: some View {
        Group {
            Section("Personal dictionary · stored on this Mac") {
                HStack { TextField("Add a name, acronym, or domain term", text: $word); Button("Add") { state.preferences.dictionary.insert(word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()); word = "" }.disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(state.preferences.dictionary.sorted(), id: \.self) { term in HStack { Text(term); Spacer(); Button("Remove") { state.preferences.dictionary.remove(term) }.buttonStyle(.borderless) } }
                Button("Delete dictionary", role: .destructive) { state.preferences.dictionary = [] }
            }
            Section("Preferred terminology") {
                HStack { TextField("Discouraged term", text: $discouraged); Text("→"); TextField("Preferred term", text: $preferred); Button("Add") { state.preferences.preferredTerms[discouraged] = preferred; discouraged = ""; preferred = "" }.disabled(discouraged.isEmpty || preferred.isEmpty) }
                ForEach(state.preferences.preferredTerms.keys.sorted(), id: \.self) { term in HStack { Text("\(term) → \(state.preferences.preferredTerms[term] ?? "")"); Spacer(); Button("Remove") { state.preferences.preferredTerms.removeValue(forKey: term) }.buttonStyle(.borderless) } }
            }
            Section("Personal voice · explicit samples only") {
                Text("Paste writing you want Clearline to learn from. ‘Describe voice’ sends only these samples and your goals to OpenAI. The generated description is editable; enabling it sends that description with later writing requests.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $state.preferences.voiceSamples).frame(height: 100).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary)).accessibilityLabel("Writing samples")
                HStack { Button(describingVoice ? "Describing…" : "Describe voice with OpenAI") { describeVoice() }.disabled(describingVoice || !state.hasKey || state.preferences.voiceSamples.isEmpty); if describingVoice { Button("Cancel") { voiceTask?.cancel(); describingVoice = false } } }
                TextField("Editable voice description", text: $state.preferences.voiceProfile, axis: .vertical).lineLimit(3...8)
                Toggle("Use this voice description", isOn: $state.preferences.voiceEnabled)
                Button("Delete samples and voice description", role: .destructive) { voiceTask?.cancel(); describingVoice = false; state.preferences.voiceSamples = ""; state.preferences.voiceProfile = ""; state.preferences.voiceEnabled = false }
            }
        }
    }
    private func describeVoice() {
        describingVoice = true
        let samples = state.preferences.voiceSamples
        voiceTask = Task {
            do {
                let config = try RequestConfiguration(model: state.preferences.model, effort: state.preferences.effort, maxOutputTokens: state.preferences.maxOutputTokens, timeout: state.preferences.timeoutSeconds)
                let request = WritingRequest(action: .voice, text: samples, instructions: "Describe only the demonstrated writing style; do not infer personal traits.", preferences: state.preferences, configuration: config)
                let result = try await state.makeProvider().perform(request) { _ in }
                try Task.checkCancellation()
                guard samples == state.preferences.voiceSamples else { describingVoice = false; return }
                state.preferences.voiceProfile = result.explanation; describingVoice = false
            } catch is CancellationError { describingVoice = false } catch { message = error.localizedDescription; describingVoice = false }
        }
    }
    private var crossApp: some View {
        Group {
            Section("Selected-text assistance") {
                Toggle("Enable selected-text assistance", isOn: $state.preferences.crossAppEnabled).onChange(of: state.preferences.crossAppEnabled) { _, enabled in state.crossApp?.configure(); if enabled { message = "Grant Accessibility permission below when you are ready. Your document editor works without it." } }
                Text("Clearline reads a selected passage only when you invoke its shortcut or menu-bar action. Secure fields and blocked apps are excluded. Replacement is available only when the host exposes supported Accessibility operations.").font(.callout)
                HStack { Button("Grant Accessibility access") { state.crossApp?.requestPermission() }; Button("Open permission settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } }
                Text(state.crossApp?.trusted == true ? "Accessibility permission is currently granted." : "Accessibility permission is not currently granted.").font(.caption)
                Picker("Shortcut key · Command + Option", selection: $state.preferences.shortcutKey) { Text("Space").tag(UInt32(49)); Text("R").tag(UInt32(15)); Text("J").tag(UInt32(38)); Text("K").tag(UInt32(40)) }.onChange(of: state.preferences.shortcutKey) { _, _ in state.crossApp?.configure() }
                if let message = state.crossAppMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Allowed apps · bundle identifiers") {
                HStack { TextField("For example, com.apple.TextEdit", text: $appID); Button("Allow") { state.preferences.allowedApps.insert(appID); appID = "" }.disabled(appID.isEmpty); Button("Block") { state.preferences.blockedApps.insert(appID); state.crossApp?.invalidate(); appID = "" }.disabled(appID.isEmpty) }
                ForEach(state.preferences.allowedApps.sorted(), id: \.self) { app in HStack { Text(app); Spacer(); Button("Remove") { state.preferences.allowedApps.remove(app); state.crossApp?.invalidate() } } }
                ForEach(state.preferences.blockedApps.sorted(), id: \.self) { app in HStack { Text("Blocked: \(app)"); Spacer(); Button("Unblock") { state.preferences.blockedApps.remove(app) } } }
                Text("A block overrides an allow. Adding an app does not establish compatibility. Consult docs/COMPATIBILITY.md for actual host test results.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Continuous cross-app checks") {
                Text("Not enabled in this build. Focused-field observation and anchored indicators require host-specific validation. Use the selected-text floating panel for explicit checks.").font(.callout)
            }
        }
    }
    private var privacy: some View {
        Group {
            Section("Local data") {
                Text("Documents, the most recent 50 saved revisions per document, preferences, dictionaries, and explicitly supplied voice samples are stored in Application Support/Clearline. Autosave uses atomic writes and a previous-good-file backup. There is no cloud sync or local analytics database.")
                Button("Show local data folder") { Task { let directory = await state.store.directory; NSWorkspace.shared.open(directory) } }
                Text("Deleting a document or its history also updates recovery copies. Time Machine or backups you made yourself must be managed separately. Samples and dictionaries can be deleted in the Dictionary tab.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Cross-app data") { Text("Captured text lives only in memory while the floating panel is active. It is not automatically saved to your library or revision history. Clearline does not read or overwrite the clipboard unless you explicitly choose Copy.") }
            Section("Diagnostics") { Text("Clearline does not log document bodies, prompts, results, or credentials. OpenAI tracing is disabled in the optional Agents SDK runtime. Operating-system crash reports may still contain process memory; review them before sharing.").font(.callout) }
        }
    }
    private var languages: some View {
        Group {
            Section("Capability matrix") {
                Text("English is the primary test language. macOS spelling availability is detected from NSSpellChecker. Apple does not expose a definitive grammar capability list: grammar findings depend on the installed engine. Rewriting and translation require OpenAI and are not certified equally across languages.").font(.callout)
                ForEach(["en_US", "en_GB", "fr", "de", "es", "ja", "ar"], id: \.self) { language in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Locale.current.localizedString(forIdentifier: language) ?? language).fontWeight(.medium)
                        Text("Spelling: \((state.spelling.engineLanguage(language) != nil) ? "available on this Mac" : "not listed by this Mac") · Grammar: engine-dependent\nEnglish style rules: \(language.hasPrefix("en") ? "enabled" : "unavailable") · OpenAI rewrite / tone / translation: provider-dependent, \(language.hasPrefix("en") ? "primary test language" : "not verified")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Detected document language: \(NativeSpelling.detectedLanguage(state.current?.text ?? "") ?? "not enough text")").font(.caption)
                Text("No automatic translation occurs. Choose Translate and specify a target language in the writing panel.").font(.caption)
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "text.alignleft").font(.system(size: 32, weight: .medium)).foregroundStyle(Palette.teal)
            Text(Brand.tagline).font(.system(size: 36, weight: .medium, design: .serif))
            Text("Welcome to \(Brand.name). A calm place to write, with a thoughtful second look when you need one.").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
            row("doc.text", "Start with your words", "Write, paste, or import a document. Spelling and local style checks work without an account or network connection.")
            row("sparkles", "Choose when to use the cloud", "Connect your own OpenAI key for rewrites, drafts, summaries, and tone feedback. Review each proposal before accepting it.")
            row("rectangle.on.rectangle", "Take a second look in other apps", "Optional selected-text assistance uses Accessibility permission. Enable it later in Settings; your editor works without it.")
            HStack { Text("Local by default. Always your decision.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Start writing") { UserDefaults.standard.set(true, forKey: "onboarded"); state.showOnboarding = false }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(40).frame(width: 610).tint(Palette.teal)
    }
    private func row(_ icon: String, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 16) { Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Palette.teal).frame(width: 26); VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 14, weight: .semibold)); Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4) } }
    }
}

struct HistoryView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Revision history").font(.system(size: 24, design: .serif)); Spacer(); Button("Done") { dismiss() } }
            Text("Snapshots are kept before accepted edits and periodically while writing. Restoring creates a new revision and can be undone.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(state.library.revisions.filter { $0.document.id == state.current?.id }.reversed()) { revision in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(revision.date.formatted()).font(.headline); Spacer(); Text("Revision \(revision.document.revision)").font(.caption); Button("Restore") { state.restore(revision); dismiss() } }
                            Text(revision.document.text).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                        }.padding().background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            Button("Delete this document’s history", role: .destructive) { state.deleteHistory() }
        }.padding(26).frame(width: 650, height: 530)
    }
}

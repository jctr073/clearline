import SwiftUI
import ClearlineCore

struct UsageSettingsView: View {
    @ObservedObject var state: AppState
    @State private var period: UsagePeriod = .month

    var body: some View {
        Section("API usage · Clearline on this Mac") {
            Picker("Period", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let totals = state.apiUsage.totals(period, now: context.date)
                let models = state.apiUsage.byModel(period, now: context.date)
                VStack(alignment: .leading, spacing: 12) {
                    if state.usageLoaded {
                        HStack(spacing: 32) {
                            metric("Responses with usage", value: totals.responses)
                            metric("Input tokens", value: totals.input)
                            metric("Output tokens", value: totals.output)
                            metric("Total tokens", value: totals.total)
                        }
                        if totals.responses == 0 {
                            Text("No usage recorded in this period. Stats appear after a writing request reports token usage.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Reported cached input: \(totals.cachedReports == 0 ? "—" : totals.cached.formatted()) · Reported reasoning: \(totals.reasoningReports == 0 ? "—" : totals.reasoning.formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Cached tokens are included in input; reasoning tokens are included in output. Detail counts appear only when reported.")
                                .font(.caption).foregroundStyle(.secondary)
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                                GridRow {
                                    Text("Model"); Text("Responses"); Text("Input"); Text("Output")
                                }.fontWeight(.medium)
                                ForEach(models.keys.sorted(), id: \.self) { model in
                                    if let usage = models[model] {
                                        GridRow {
                                            Text(model).textSelection(.enabled)
                                            Text(usage.responses.formatted())
                                            Text(usage.input.formatted())
                                            Text(usage.output.formatted())
                                        }
                                    }
                                }
                            }.font(.caption).monospacedDigit()
                        }
                        Text("Recorded since \(state.apiUsage.since.formatted(date: .abbreviated, time: .shortened)). Periods use UTC.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if state.usageError == nil {
                        ProgressView("Loading usage…")
                    }
                    if let error = state.usageError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            Text("Counts use usage reported by the native client and Agents SDK across all keys used on this Mac. Earlier usage and requests interrupted before usage arrives may be missing. These are local totals, not account billing or remaining credit.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Link("Open OpenAI usage dashboard", destination: URL(string: "https://platform.openai.com/usage")!)
                Spacer()
                Button("Reset local stats", role: .destructive) { Task { await state.resetUsage() } }
            }
        }
    }
    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension AppState {
    private func applyUsage(_ ledger: UsageLedger) {
        if ledger.revision >= apiUsage.revision { apiUsage = ledger }
        usageLoaded = true
    }
    func refreshUsage() async {
        do { applyUsage(try await usageStore.load()); usageError = nil }
        catch { usageError = "Could not load local usage. Existing data has been preserved. Reset local stats to start over." }
    }
    func recordUsage(model: String, usage: TokenUsage) async {
        do { applyUsage(try await usageStore.record(model: model, usage: usage)); usageError = nil }
        catch {
            if let current = try? await usageStore.load() { applyUsage(current) }
            usageError = "Could not save local usage. Stats may be incomplete after relaunch."
        }
    }
    func resetUsage() async {
        do { applyUsage(try await usageStore.reset()); usageError = nil }
        catch { usageError = "Could not reset local usage. Try again when the data folder is writable." }
    }
}

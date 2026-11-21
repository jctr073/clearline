import SwiftUI
import ClearlineCore

/// One menu for every connected vendor, grouped by vendor. Choosing a model also
/// chooses its vendor, so there is no separate vendor control.
struct WritingModelPicker: View {
    let available: [ModelCapability]
    @Binding var selection: String

    private var models: [ModelCapability] { ModelCapability.writingModels(from: available) }

    var body: some View {
        Picker("Model", selection: $selection) {
            ForEach(AIVendor.allCases) { vendor in
                let group = models.filter { $0.vendor == vendor }
                if !group.isEmpty {
                    Section(vendor.displayName) {
                        ForEach(group) { Text($0.displayName).tag($0.id) }
                    }
                }
            }
            if !models.contains(where: { $0.id == selection }) {
                if !models.isEmpty { Divider() }
                Text("\(ModelCapability.capability(for: selection).displayName) · \(available.contains { $0.id == selection } ? "saved model" : "unavailable")")
                    .tag(selection)
            }
        }
        .pickerStyle(.menu)
    }
}

struct ReasoningEffortPicker: View {
    let model: String
    @Binding var selection: String

    private var capability: ModelCapability { ModelCapability.capability(for: model) }

    var body: some View {
        if !capability.efforts.isEmpty {
            Picker(capability.vendor == .gemini ? "Thinking level" : "Reasoning effort", selection: $selection) {
                ForEach(capability.efforts, id: \.self) {
                    Text(ModelCapability.effortDisplayName($0)).tag($0)
                }
            }
            .pickerStyle(.menu)
        } else {
            Text(capability.reasoningDescription).font(.caption).foregroundStyle(.secondary)
        }
    }
}

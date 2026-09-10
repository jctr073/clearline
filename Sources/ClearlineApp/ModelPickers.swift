import SwiftUI
import ClearlineCore

struct WritingModelPicker: View {
    let available: [ModelCapability]
    @Binding var selection: String

    private var models: [ModelCapability] { ModelCapability.writingModels(from: available) }

    var body: some View {
        Picker("Model", selection: $selection) {
            ForEach(models) { Text($0.displayName).tag($0.id) }
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
            Picker("Reasoning effort", selection: $selection) {
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

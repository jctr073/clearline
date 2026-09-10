import SwiftUI
import ClearlineCore

struct ProposalCountComparison: View {
    let original: String
    let proposal: String

    var body: some View {
        let before = TextMetrics(original)
        let after = TextMetrics(proposal)
        Grid(alignment: .trailing, horizontalSpacing: 28, verticalSpacing: 10) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text("Before")
                Text("After")
                Text("Change")
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            countRow("Words", before: before.words, after: after.words)
            countRow("Characters", before: before.characters, after: after.characters)
        }
        .font(.system(size: 12)).monospacedDigit()
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Before and after text counts")
        .help("Counts compare the original passage with the proposal, including spaces and Markdown characters.")
    }

    private func countRow(_ label: String, before: Int, after: Int) -> some View {
        let change = after - before
        return GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(before.formatted())
            Text(after.formatted()).fontWeight(.medium)
            Text(change > 0 ? "+\(change.formatted())" : change < 0 ? "−\((-change).formatted())" : "0")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): before \(before), after \(after), \(change == 0 ? "no change" : change > 0 ? "increase of \(change)" : "decrease of \(-change)")")
    }
}

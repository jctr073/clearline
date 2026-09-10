import AppKit
import SwiftUI

/// Magnify the view, leaving stored fonts, source text, and undo history intact.
enum WorkspaceZoom {
    static let range = 0.5...2.0

    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : 1
    }

    @MainActor
    static func apply(_ value: Double, to scroll: NSScrollView) {
        scroll.minMagnification = range.lowerBound
        scroll.maxMagnification = range.upperBound
        let factor = clamped(value)
        if abs(scroll.magnification - factor) > 0.001 {
            scroll.setMagnification(factor, centeredAt: scroll.contentView.bounds.origin)
        }
        (scroll as? WorkspaceScrollView)?.fitTextWidth()
    }
}

/// Reflow at the magnified viewport width instead of clipping enlarged lines.
final class WorkspaceScrollView: NSScrollView {
    var minimumDocumentWidth: CGFloat = 0
    override func layout() {
        super.layout()
        fitTextWidth()
    }

    override func tile() {
        super.tile()
        fitTextWidth()
    }

    func fitTextWidth() {
        guard let textView = documentView as? NSTextView else { return }
        let width = max(contentView.bounds.width, minimumDocumentWidth)
        guard width > 0, abs(textView.frame.width - width) > 0.5 else { return }
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }
}

struct WorkspaceZoomControl: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 5) {
            Button { state.setWorkspaceZoom(state.workspaceZoom - 0.1) } label: {
                Image(systemName: "minus.magnifyingglass")
            }.disabled(state.workspaceZoom <= WorkspaceZoom.range.lowerBound)
                .accessibilityLabel("Zoom out").help("Zoom out")
            Slider(value: Binding(get: { state.workspaceZoom }, set: { state.setWorkspaceZoom($0) }), in: WorkspaceZoom.range, step: 0.1)
                .frame(width: 85)
                .accessibilityLabel("Workspace magnification")
                .accessibilityValue("\(Int((state.workspaceZoom * 100).rounded())) percent")
                .help("Magnify the document text")
            Button { state.setWorkspaceZoom(state.workspaceZoom + 0.1) } label: {
                Image(systemName: "plus.magnifyingglass")
            }.disabled(state.workspaceZoom >= WorkspaceZoom.range.upperBound)
                .accessibilityLabel("Zoom in").help("Zoom in")
            Button { state.setWorkspaceZoom(1) } label: {
                Text("\(Int((state.workspaceZoom * 100).rounded()))%")
                    .monospacedDigit().frame(width: 36, alignment: .trailing)
            }.accessibilityLabel("Reset workspace zoom to 100 percent").help("Reset zoom to 100%")
        }.buttonStyle(.plain).controlSize(.mini).fixedSize()
    }
}

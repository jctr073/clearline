import SwiftUI
import AppKit
import ClearlineCore

@main
struct ClearlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        Window(Brand.name, id: "main") {
            WorkspaceView(state: state).onAppear { delegate.state = state }
        }.defaultSize(width: 1230, height: 830).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { state.activeUndoManager?.undo() }.keyboardShortcut("z")
                    .disabled(state.activeUndoManager?.canUndo != true)
                Button("Redo") { state.activeUndoManager?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(state.activeUndoManager?.canRedo != true)
            }
            CommandGroup(replacing: .newItem) {
                Button("New document") { state.newDocument(); showMain() }.keyboardShortcut("n")
                Button("Import…") { state.importDocument() }.keyboardShortcut("o")
                Button("Export…") { state.exportDocument() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { showMain(); state.showSettings = true }.keyboardShortcut(",") }
            CommandGroup(after: .toolbar) {
                Button(state.isMarkdownPreview ? "Edit Markdown" : "Preview Markdown") { state.showMarkdownPreview.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(state.current?.format != .md)
            }
            CommandMenu("Table") {
                Button("Insert or Edit Table…") { state.openTable() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(state.current?.format != .md || state.isMarkdownPreview || state.tableSession != nil)
                Menu("Paste as Table") {
                    Button("Use First Row as Headers…") { state.openTable(paste: true) }
                    Button("Generate Column Headers…") { state.openTable(paste: true, firstRowIsHeader: false) }
                }.disabled(state.current?.format != .md || state.isMarkdownPreview || state.tableSession != nil)
            }
            CommandMenu("Writing") {
                Button("Writing tools…") { state.startAI() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Rewrite current paragraph…") { state.startAI(.clarity, paragraph: true) }
                Button("Rewrite entire document…") { state.startAI(.clarity, wholeDocument: true) }
                Button("Draft from notes…") { state.startAI(.draft) }
                Button("Summarize document…") { state.startAI(.summarize, wholeDocument: true) }
                Divider()
                Button("Next suggestion") { state.nextIssue(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous suggestion") { state.nextIssue(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Accept selected suggestion") { if let issue = state.suggestions.first(where: { $0.id == state.selectedIssue }) { state.accept(issue) } }.keyboardShortcut(.return, modifiers: [.command])
                Button("Dismiss selected suggestion") { if let issue = state.suggestions.first(where: { $0.id == state.selectedIssue }) { state.dismiss(issue) } }.keyboardShortcut(.delete, modifiers: [.command, .option])
                Divider()
                Button(state.paused ? "Resume checking" : "Pause checking") { state.togglePause() }
            }
        }
        MenuBarExtra(Brand.name, systemImage: "text.alignleft") {
            Button("Open \(Brand.name)") { showMain() }
            Button("New document") { state.newDocument(); showMain() }
            Button("Assist selected text") { state.crossApp?.capture() }
            Divider()
            Button(state.paused ? "Resume checking" : "Pause checking") { state.togglePause() }
            Button("Settings…") { showMain(); state.showSettings = true }
            Divider()
            Button("Quit \(Brand.name)") { NSApplication.shared.terminate(nil) }
        }
    }
    private func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == Brand.name }) { window.makeKeyAndOrderFront(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.ready else { return .terminateNow }
        Task {
            do { try await state.flush(); sender.reply(toApplicationShouldTerminate: true) }
            catch { state.error = "Could not save before quitting: \(error.localizedDescription)"; sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { sender.windows.first(where: { $0.title == Brand.name })?.makeKeyAndOrderFront(nil) }; return true }
}

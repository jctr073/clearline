import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import ClearlineCore

struct ExternalSelection {
    let id = UUID()
    let pid: pid_t
    let bundleID: String
    let appName: String
    let element: AXUIElement
    let range: UTF16Range?
    let text: String
    let fullText: String?
    let bounds: CGRect?
    let canReplace: Bool

    init(pid: pid_t, bundleID: String, appName: String, element: AXUIElement, range: UTF16Range?, text: String, fullText: String?, bounds: CGRect?, selectedTextIsSettable: Bool, maxInputCharacters: Int) throws {
        guard !text.isEmpty, text.utf16.count <= maxInputCharacters else { throw CrossAppError.unsupported }
        self.pid = pid; self.bundleID = bundleID; self.appName = appName; self.element = element
        self.range = range; self.text = text; self.bounds = bounds
        // Full-field context is needed only for replacement, never for a read-only capture.
        let verifiedFullText: String?
        if selectedTextIsSettable, let range, range.length > 0, let fullText,
           fullText.utf16.count <= 200000, (try? EditEngine.substring(fullText, range: range)) == text {
            verifiedFullText = fullText
        } else { verifiedFullText = nil }
        self.fullText = verifiedFullText
        self.canReplace = verifiedFullText != nil
    }
}

enum CrossAppError: String, LocalizedError, Error {
    case permission = "Enable Accessibility access for Clearline in System Settings → Privacy & Security → Accessibility. You can still paste text into the editor without this permission."
    case disabled = "Selected-text assistance is off. Enable it in Settings → Cross-app."
    case paused = "Clearline is paused. Resume checking before capturing selected text."
    case blocked = "This app is not allowed for selected-text assistance. Review your app allowlist in Settings."
    case secure = "Clearline does not read or edit secure fields."
    case unsupported = "This control does not expose a supported text selection. Copy it yourself and paste it into a Clearline document. Your clipboard has not been read or changed."
    case changed = "The source app, field, text, or selection changed. Replacement was refused. Copy the proposal or capture the selection again."
    case notWritable = "This control does not support replacing selected text through Accessibility. Use Copy, return to the source, and paste explicitly."
    case replacementFailed = "The host did not confirm the replacement. Check the source before trying again; do not assume formatting or undo was preserved."
    var errorDescription: String? { rawValue }
}

@MainActor
final class CrossAppController {
    weak var state: AppState?
    var panel: NSPanel?
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var observer: NSObjectProtocol?
    private var session: AISession?
    private var axObserver: AXObserver?
    init(state: AppState) {
        self.state = state
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                if let captured = self?.session?.external, captured.canReplace,
                   app.processIdentifier != captured.pid && app.bundleIdentifier != Brand.bundleID { self?.invalidate() }
            }
        }
    }
    var trusted: Bool { AXIsProcessTrusted() }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func configure() {
        if let hotkey { UnregisterEventHotKey(hotkey); self.hotkey = nil }
        guard let state, state.preferences.crossAppEnabled else { invalidate(); return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<CrossAppController>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in controller.capture() }
                return noErr
            }, 1, &spec, pointer, &handler)
        }
        let result = RegisterEventHotKey(state.preferences.shortcutKey, state.preferences.shortcutModifiers, EventHotKeyID(signature: 0x434C524E, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        state.crossAppMessage = result == noErr ? "Shortcut registered. Select text in an allowed app to try it." : "Shortcut could not be registered (\(result)). Choose another key, or use the Clearline menu-bar action."
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func focused(_ app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func secure(_ element: AXUIElement) -> Bool {
        var candidate = element
        for _ in 0..<6 {
            let role = attribute(candidate, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(candidate, kAXSubroleAttribute) as? String ?? ""
            if role.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("password") { return true }
            guard let parent = attribute(candidate, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            candidate = parent as! AXUIElement
        }
        return false
    }
    private func selectedRange(_ element: AXUIElement) -> UTF16Range? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return UTF16Range(range.location, range.length)
    }
    private func parameterizedAttribute(_ element: AXUIElement, _ name: String, range: UTF16Range) -> CFTypeRef? {
        guard range.location >= 0, range.length > 0 else { return nil }
        var selection = CFRange(location: range.location, length: range.length), value: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &selection),
              AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }
    func capture() {
        do {
            show(try readSelection())
        } catch { state?.crossAppMessage = error.localizedDescription; showMessage(error.localizedDescription) }
    }
    func readSelection() throws -> ExternalSelection {
        guard let state, state.preferences.crossAppEnabled else { throw CrossAppError.disabled }
        guard !state.paused else { throw CrossAppError.paused }
        guard trusted else { throw CrossAppError.permission }
        guard let sourceApp = NSWorkspace.shared.frontmostApplication, let bundleID = sourceApp.bundleIdentifier,
              state.preferences.allowedApps.contains(bundleID), !state.preferences.blockedApps.contains(bundleID) else { throw CrossAppError.blocked }
        let app = AXUIElementCreateApplication(sourceApp.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let focusedElement = focused(app) else { throw CrossAppError.unsupported }
        var element = focusedElement
        // Some read-only views expose their selection on a containing text area.
        for _ in 0..<8 {
            AXUIElementSetMessagingTimeout(element, 1)
            guard !secure(element) else { throw CrossAppError.secure }
            let range = selectedRange(element)
            var text = attribute(element, kAXSelectedTextAttribute) as? String
            if text?.isEmpty != false, let range, range.length <= state.preferences.maxInputCharacters {
                text = parameterizedAttribute(element, kAXStringForRangeParameterizedAttribute, range: range) as? String
            }
            if let text, !text.isEmpty {
                guard text.utf16.count <= state.preferences.maxInputCharacters else { throw CrossAppError.unsupported }
                var settable = DarwinBoolean(false)
                let writable = CFEqual(element, focusedElement) && AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
                let full = writable ? attribute(element, kAXValueAttribute) as? String : nil
                var bounds: CGRect?
                if let range, let value = parameterizedAttribute(element, kAXBoundsForRangeParameterizedAttribute, range: range),
                   CFGetTypeID(value) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    if AXValueGetValue(value as! AXValue, .cgRect, &rect) { bounds = rect }
                }
                return try ExternalSelection(pid: sourceApp.processIdentifier, bundleID: bundleID, appName: sourceApp.localizedName ?? "Source app", element: element, range: range, text: text, fullText: full, bounds: bounds, selectedTextIsSettable: writable, maxInputCharacters: state.preferences.maxInputCharacters)
            }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        throw CrossAppError.unsupported
    }
    func replace(_ captured: ExternalSelection, with replacement: String) throws {
        guard captured.canReplace, let range = captured.range, let fullText = captured.fullText else { throw CrossAppError.notWritable }
        guard let state, !state.paused, state.preferences.crossAppEnabled, trusted else { throw CrossAppError.permission }
        guard state.preferences.allowedApps.contains(captured.bundleID), !state.preferences.blockedApps.contains(captured.bundleID) else { throw CrossAppError.blocked }
        guard session?.external?.id == captured.id, !((session?.stale) ?? true),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == captured.pid,
              let current = focused(AXUIElementCreateApplication(captured.pid)), CFEqual(current, captured.element),
              !secure(current), selectedRange(current) == captured.range,
              attribute(current, kAXSelectedTextAttribute) as? String == captured.text,
              attribute(current, kAXValueAttribute) as? String == captured.fullText else { throw CrossAppError.changed }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(current, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else { throw CrossAppError.notWritable }
        guard AXUIElementSetAttributeValue(current, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else { throw CrossAppError.replacementFailed }
        let expected = (fullText as NSString).replacingCharacters(in: range.nsRange, with: replacement)
        guard attribute(current, kAXValueAttribute) as? String == expected else { invalidate(); throw CrossAppError.replacementFailed }
        panel?.orderOut(nil); session?.cancel(); session = nil; stopObserving()
    }
    private func show(_ captured: ExternalSelection) {
        guard let state else { return }
        session?.cancel(); panel?.close(); stopObserving()
        let session = AISession(original: captured.text, documentID: nil, revision: nil, range: captured.range ?? UTF16Range(0, captured.text.utf16.count), action: .clarity, preferences: state.preferences, external: captured)
        self.session = session
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "\(Brand.name) · \(captured.appName)"; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]; panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: AIReviewView(state: state, session: session, close: { [weak self] in self?.invalidate() }))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: min(max(NSEvent.mouseLocation.x + 12, frame.minX), frame.maxX - 700), y: max(frame.minY, min(NSEvent.mouseLocation.y - 350, frame.maxY - 700)), width: min(700, frame.width), height: min(700, frame.height)), display: true)
        }
        self.panel = panel; panel.orderFrontRegardless()
        if captured.canReplace { observe(captured) }
    }
    private func showMessage(_ text: String) {
        let alert = NSAlert(); alert.messageText = "\(Brand.name) selected-text assistance"; alert.informativeText = text
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    private func observe(_ captured: ExternalSelection) {
        var newObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let controller = Unmanaged<CrossAppController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.invalidate() }
        }
        if AXObserverCreate(captured.pid, callback, &newObserver) == .success, let newObserver {
            axObserver = newObserver
            for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(newObserver, captured.element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            let app = AXUIElementCreateApplication(captured.pid)
            AXObserverAddNotification(newObserver, app, kAXFocusedUIElementChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            if let window = attribute(captured.element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
                for notification in [kAXWindowMovedNotification, kAXWindowResizedNotification] { AXObserverAddNotification(newObserver, window as! AXUIElement, notification as CFString, Unmanaged.passUnretained(self).toOpaque()) }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        }
    }
    private func stopObserving() { if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }; axObserver = nil }
    func invalidate() { session?.stale = true; session?.cancel(); panel?.orderOut(nil); session = nil; stopObserving() }
}
final class FloatingPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }

import SwiftUI
import AppKit

// MARK: - SwiftUI Wrapper

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.shortcut = shortcut
        view.onChange = { newShortcut in
            shortcut = newShortcut
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        if nsView.shortcut != shortcut {
            nsView.shortcut = shortcut
            nsView.needsDisplay = true
        }
    }
}

// MARK: - NSView

final class ShortcutRecorderNSView: NSView {
    var shortcut = StoredShortcut(keyEquivalent: "", modifiers: 0) {
        didSet { needsDisplay = true }
    }
    var onChange: ((StoredShortcut) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }
    private var deactivationObserver: Any?
    private var localMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 24)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgColor: NSColor = isRecording ? .controlAccentColor.withAlphaComponent(0.15) : .controlBackgroundColor
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()

        let borderColor: NSColor = isRecording ? .controlAccentColor : .separatorColor
        borderColor.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let textColor: NSColor
        if isRecording {
            text = "Type shortcut\u{2026}"
            textColor = .secondaryLabelColor
        } else if shortcut.isEmpty {
            text = "Click to set"
            textColor = .tertiaryLabelColor
        } else {
            text = shortcut.displayString
            textColor = .labelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: textColor,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let strSize = attrStr.size()
        let drawPoint = NSPoint(
            x: (bounds.width - strSize.width) / 2,
            y: (bounds.height - strSize.height) / 2
        )
        attrStr.draw(at: drawPoint)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            beginRecording()
        }
    }

    // MARK: - Keyboard

    /// Intercepts menu-level key equivalents before they reach the menu bar.
    /// This is called BEFORE keyDown for shortcut key combos.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        return processKeyEvent(event)
    }

    /// Intercepts regular key presses (non-shortcut keys with modifiers).
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        processKeyEvent(event)
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    // MARK: - Recording Lifecycle

    private func beginRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        installDeactivationMonitor()
        installLocalMonitor()
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        removeDeactivationMonitor()
        removeLocalMonitor()
    }

    // MARK: - Key Event Processing

    @discardableResult
    private func processKeyEvent(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }

        let keyCode = event.keyCode
        let heldModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        // Bare Escape -> cancel. With modifiers it is a recordable shortcut
        // (Series uses Ctrl-Shift-Escape), so fall through in that case.
        if keyCode == 53 && heldModifiers.isEmpty {
            endRecording()
            return true
        }

        // Delete/Backspace -> clear
        if (keyCode == 51 || keyCode == 117) && heldModifiers.isEmpty {
            shortcut = StoredShortcut(keyEquivalent: "", modifiers: 0)
            endRecording()
            onChange?(shortcut)
            return true
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }

        let modifiers = heldModifiers

        // Require at least Cmd, Ctrl, or Option
        if !modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.option) {
            NSSound.beep()
            return true
        }

        let newShortcut = StoredShortcut(keyEquivalent: chars.lowercased(), modifiers: modifiers.rawValue, keyCode: event.keyCode)
        endRecording()
        shortcut = newShortcut
        onChange?(newShortcut)
        return true
    }

    // MARK: - Local Event Monitor

    /// Catches key events that bypass the responder chain (e.g. some system key combos
    /// that the window intercepts before performKeyEquivalent reaches our view).
    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if self.processKeyEvent(event) {
                return nil // consume
            }
            return event
        }
    }

    private func removeLocalMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Deactivation Monitor (detects another app capturing the shortcut)

    private func installDeactivationMonitor() {
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isRecording else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Ignore if ScreenSnipe re-activated itself
            guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            let appName = app?.localizedName
            let bundleID = app?.bundleIdentifier
            self.endRecording()
            DispatchQueue.main.async {
                self.showDeactivationWarning(appName: appName, bundleID: bundleID)
            }
        }
    }

    private func removeDeactivationMonitor() {
        if let observer = deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            deactivationObserver = nil
        }
    }

    /// Known macOS system bundle IDs that handle global shortcuts.
    private static let systemBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.controlcenter",
    ]

    private func showDeactivationWarning(appName: String?, bundleID: String?) {
        let isSystem = bundleID.map { Self.systemBundleIDs.contains($0) } ?? true
        let displayName = appName ?? "another application"

        let alert = NSAlert()
        alert.messageText = "Shortcut In Use"

        if isSystem {
            alert.informativeText = "This shortcut is used by macOS (\(displayName)). It was activated instead of being captured.\n\nTo free this shortcut, disable it in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts."
            alert.addButton(withTitle: "Open Keyboard Settings")
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            }
        } else {
            alert.informativeText = "This shortcut is used by \"\(displayName)\". It was activated instead of being captured.\n\nTo use this shortcut in ScreenSnipe, change or remove it in \(displayName)\u{2019}s settings first."
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }
}

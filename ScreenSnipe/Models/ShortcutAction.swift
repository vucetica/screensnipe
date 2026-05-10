import AppKit

enum ShortcutAction: String, CaseIterable, Codable {
    case captureRegion
    case captureFullScreen
    case captureWindow
    case recordFullScreen
    case recordRegion
    case recordWindow
    case stopRecording
    case pauseResumeRecording
    case openLibrary

    var displayName: String {
        switch self {
        case .captureRegion: "Capture Region"
        case .captureFullScreen: "Capture Full Screen"
        case .captureWindow: "Capture Window"
        case .recordFullScreen: "Record Full Screen"
        case .recordRegion: "Record Region"
        case .recordWindow: "Record Window"
        case .stopRecording: "Stop Recording"
        case .pauseResumeRecording: "Pause/Resume Recording"
        case .openLibrary: "Open Library"
        }
    }

    var defaultShortcut: StoredShortcut {
        switch self {
        case .captureRegion:
            StoredShortcut(keyEquivalent: "c", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyCode: 8)
        case .captureFullScreen:
            StoredShortcut(keyEquivalent: "f", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyCode: 3)
        case .captureWindow:
            StoredShortcut(keyEquivalent: "w", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyCode: 13)
        case .recordFullScreen:
            StoredShortcut(keyEquivalent: "c", modifiers: NSEvent.ModifierFlags([.control, .shift, .option]).rawValue, keyCode: 8)
        case .recordRegion:
            StoredShortcut(keyEquivalent: "r", modifiers: NSEvent.ModifierFlags([.control, .shift, .option]).rawValue, keyCode: 15)
        case .recordWindow:
            StoredShortcut(keyEquivalent: "w", modifiers: NSEvent.ModifierFlags([.control, .shift, .option]).rawValue, keyCode: 13)
        case .stopRecording:
            StoredShortcut(keyEquivalent: "s", modifiers: NSEvent.ModifierFlags([.control, .shift, .option]).rawValue, keyCode: 1)
        case .pauseResumeRecording:
            StoredShortcut(keyEquivalent: "p", modifiers: NSEvent.ModifierFlags([.control, .shift, .option]).rawValue, keyCode: 35)
        case .openLibrary:
            StoredShortcut(keyEquivalent: "l", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyCode: 37)
        }
    }

    static var captureActions: [ShortcutAction] {
        [.captureRegion, .captureFullScreen, .captureWindow]
    }

    static var recordingActions: [ShortcutAction] {
        [.recordFullScreen, .recordRegion, .recordWindow, .stopRecording, .pauseResumeRecording]
    }

    static var appActions: [ShortcutAction] {
        [.openLibrary]
    }
}

struct StoredShortcut: Codable, Equatable {
    var keyEquivalent: String
    var modifiers: UInt
    /// Virtual key code from NSEvent.keyCode. Used for Carbon global hotkey registration.
    var keyCode: UInt16?

    var isEmpty: Bool {
        keyEquivalent.isEmpty
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var displayString: String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyEquivalent.uppercased())
        return parts.joined()
    }
}

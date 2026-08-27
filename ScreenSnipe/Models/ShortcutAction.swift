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
    case seriesRegion
    case seriesFullScreen
    case seriesWindow
    case snapSeriesFrame
    case finishSeries
    case cancelSeries
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
        case .seriesRegion: "Series of Region"
        case .seriesFullScreen: "Series of Full Screen"
        case .seriesWindow: "Series of Window"
        case .snapSeriesFrame: "Snap Series Frame"
        case .finishSeries: "Finish Series"
        case .cancelSeries: "Cancel Series"
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
        case .seriesRegion:
            StoredShortcut(keyEquivalent: "r", modifiers: NSEvent.ModifierFlags([.command, .control, .shift]).rawValue, keyCode: 15)
        case .seriesFullScreen:
            StoredShortcut(keyEquivalent: "f", modifiers: NSEvent.ModifierFlags([.command, .control, .shift]).rawValue, keyCode: 3)
        case .seriesWindow:
            StoredShortcut(keyEquivalent: "w", modifiers: NSEvent.ModifierFlags([.command, .control, .shift]).rawValue, keyCode: 13)
        case .snapSeriesFrame:
            StoredShortcut(keyEquivalent: " ", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyCode: 49)
        case .finishSeries:
            StoredShortcut(keyEquivalent: "\r", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyCode: 36)
        case .cancelSeries:
            StoredShortcut(keyEquivalent: "\u{1b}", modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue, keyCode: 53)
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

    static var seriesActions: [ShortcutAction] {
        [.seriesRegion, .seriesFullScreen, .seriesWindow, .snapSeriesFrame, .finishSeries, .cancelSeries]
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

    /// Glyphs for keys whose character has no visible uppercase form.
    /// Without these, Space renders as a blank and Return as a stray control character.
    private static let keyGlyphs: [String: String] = [
        " ": "␣",
        "\r": "↩",
        "\u{3}": "⌤",
        "\u{1b}": "⎋",
        "\t": "⇥",
        "\u{8}": "⌫",
        "\u{7f}": "⌫",
        "\u{f728}": "⌦",
        "\u{f700}": "↑",
        "\u{f701}": "↓",
        "\u{f702}": "←",
        "\u{f703}": "→",
    ]

    /// Human-readable name used in conflict messages, where a glyph alone reads poorly.
    var keyDisplayName: String {
        switch keyEquivalent {
        case " ": "Space"
        case "\r": "Return"
        case "\u{1b}": "Escape"
        case "\t": "Tab"
        default: keyEquivalent.uppercased()
        }
    }

    var displayString: String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyGlyphs[keyEquivalent] ?? keyEquivalent.uppercased())
        return parts.joined()
    }
}

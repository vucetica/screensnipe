import AppKit
import Combine

struct ShortcutConflictInfo {
    let shortcut: StoredShortcut
    let owner: String       // "Screen Snipe" or "macOS"
    let description: String // e.g. "Capture Region" or "Screenshot and Recording Options"
    let isSystem: Bool
}

@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    @Published private(set) var shortcuts: [ShortcutAction: StoredShortcut]

    private static let userDefaultsKey = "shortcuts"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode([ShortcutAction: StoredShortcut].self, from: data) {
            shortcuts = decoded
        } else {
            shortcuts = Self.defaultShortcuts()
        }
    }

    func shortcut(for action: ShortcutAction) -> StoredShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    /// Checks for conflicts against both internal shortcuts and known system shortcuts.
    func checkConflict(for shortcut: StoredShortcut, excluding action: ShortcutAction) -> ShortcutConflictInfo? {
        guard !shortcut.isEmpty else { return nil }

        // Check internal (other ScreenSnipe actions)
        for (existingAction, existingShortcut) in shortcuts where existingAction != action {
            if existingShortcut == shortcut {
                return ShortcutConflictInfo(
                    shortcut: shortcut,
                    owner: "Screen Snipe",
                    description: existingAction.displayName,
                    isSystem: false
                )
            }
        }

        // Check known macOS system shortcuts
        if let systemDesc = Self.systemShortcutDescription(for: shortcut) {
            return ShortcutConflictInfo(
                shortcut: shortcut,
                owner: "macOS",
                description: systemDesc,
                isSystem: true
            )
        }

        return nil
    }

    /// Force-sets a shortcut, clearing it from any conflicting ScreenSnipe action first.
    func forceSetShortcut(_ shortcut: StoredShortcut, for action: ShortcutAction) {
        if !shortcut.isEmpty {
            for (existingAction, existingShortcut) in shortcuts where existingAction != action {
                if existingShortcut == shortcut {
                    shortcuts[existingAction] = StoredShortcut(keyEquivalent: "", modifiers: 0)
                }
            }
        }
        shortcuts[action] = shortcut
        save()
    }

    func resetToDefaults() {
        shortcuts = Self.defaultShortcuts()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    private static func defaultShortcuts() -> [ShortcutAction: StoredShortcut] {
        var defaults: [ShortcutAction: StoredShortcut] = [:]
        for action in ShortcutAction.allCases {
            defaults[action] = action.defaultShortcut
        }
        return defaults
    }

    // MARK: - Known macOS System Shortcuts

    private static func systemShortcutDescription(for shortcut: StoredShortcut) -> String? {
        let mods = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
            .intersection([.command, .control, .option, .shift])
        let key = shortcut.keyEquivalent

        for entry in knownSystemShortcuts {
            if key == entry.key && mods == entry.modifiers {
                return entry.description
            }
        }
        return nil
    }

    private static let knownSystemShortcuts: [(key: String, modifiers: NSEvent.ModifierFlags, description: String)] = [
        // Screenshots
        ("3", [.command, .shift], "Screenshot (Save to File)"),
        ("4", [.command, .shift], "Screenshot (Selection to File)"),
        ("5", [.command, .shift], "Screenshot and Recording Options"),
        ("6", [.command, .shift], "Screenshot Touch Bar"),
        ("3", [.command, .shift, .control], "Screenshot (Copy to Clipboard)"),
        ("4", [.command, .shift, .control], "Screenshot Selection (Copy to Clipboard)"),

        // Spotlight & Search
        (" ", [.command], "Spotlight"),
        (" ", [.command, .option], "Finder Search Window"),

        // App Management
        ("q", [.command], "Quit Application"),
        ("w", [.command], "Close Window"),
        ("h", [.command], "Hide Application"),
        ("m", [.command], "Minimize Window"),
        ("`", [.command], "Move Focus to Next Window"),
        ("h", [.command, .option], "Hide Other Applications"),

        // Full Screen & Mission Control
        ("f", [.command, .control], "Toggle Full Screen"),

        // Input Sources
        (" ", [.control], "Select Next Input Source"),
        (" ", [.control, .option], "Select Previous Input Source"),

        // Dock
        ("d", [.command, .option], "Show/Hide Dock"),

        // Force Quit
        ("q", [.command, .option], "Force Quit Applications"),

        // Undo/Redo (common)
        ("z", [.command], "Undo"),
        ("z", [.command, .shift], "Redo"),

        // Select All / Copy / Paste / Cut
        ("a", [.command], "Select All"),
        ("c", [.command], "Copy"),
        ("v", [.command], "Paste"),
        ("x", [.command], "Cut"),

        // Siri
        (" ", [.command, .shift], "Siri (if enabled)"),
    ]
}

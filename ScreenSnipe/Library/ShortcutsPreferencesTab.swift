import SwiftUI

struct ShortcutsPreferencesTab: View {
    @ObservedObject private var shortcutManager = ShortcutManager.shared
    @State private var pendingConflict: PendingConflict?

    var body: some View {
        Form {
            Section("Capture") {
                ForEach(ShortcutAction.captureActions, id: \.self) { action in
                    shortcutRow(for: action)
                }
            }
            Section("Recording") {
                ForEach(ShortcutAction.recordingActions, id: \.self) { action in
                    shortcutRow(for: action)
                }
            }
            Section("App") {
                ForEach(ShortcutAction.appActions, id: \.self) { action in
                    shortcutRow(for: action)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset All to Defaults") {
                        shortcutManager.resetToDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(alertTitle, isPresented: alertIsPresented) {
            if let conflict = pendingConflict {
                if conflict.info.isSystem {
                    Button("Set Anyway") {
                        shortcutManager.forceSetShortcut(conflict.shortcut, for: conflict.action)
                        pendingConflict = nil
                    }
                } else {
                    Button("Replace") {
                        shortcutManager.forceSetShortcut(conflict.shortcut, for: conflict.action)
                        pendingConflict = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingConflict = nil
                }
            }
        } message: {
            if let conflict = pendingConflict {
                Text(alertMessage(for: conflict))
            }
        }
    }

    private var alertTitle: String {
        guard let conflict = pendingConflict else { return "Shortcut Conflict" }
        if conflict.info.isSystem {
            return "System Shortcut"
        }
        return "Shortcut Conflict"
    }

    private func alertMessage(for conflict: PendingConflict) -> String {
        let shortcutStr = conflict.shortcut.displayString
        if conflict.info.isSystem {
            return "\(shortcutStr) is used by \(conflict.info.owner) for \"\(conflict.info.description)\".\n\nThis shortcut may not work unless you disable the system shortcut in System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts."
        } else {
            return "\(shortcutStr) is already used by \(conflict.info.owner) for \"\(conflict.info.description)\". Replace it?"
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { pendingConflict != nil },
            set: { if !$0 { pendingConflict = nil } }
        )
    }

    @ViewBuilder
    private func shortcutRow(for action: ShortcutAction) -> some View {
        HStack {
            Text(action.displayName)
            Spacer()
            ShortcutRecorderView(
                shortcut: bindingForAction(action)
            )
            .frame(width: 160, height: 24)
        }
    }

    private func bindingForAction(_ action: ShortcutAction) -> Binding<StoredShortcut> {
        Binding(
            get: { shortcutManager.shortcut(for: action) },
            set: { newShortcut in
                guard !newShortcut.isEmpty else {
                    shortcutManager.forceSetShortcut(newShortcut, for: action)
                    return
                }
                if let conflict = shortcutManager.checkConflict(for: newShortcut, excluding: action) {
                    pendingConflict = PendingConflict(
                        action: action,
                        shortcut: newShortcut,
                        info: conflict
                    )
                } else {
                    shortcutManager.forceSetShortcut(newShortcut, for: action)
                }
            }
        )
    }
}

private struct PendingConflict {
    let action: ShortcutAction
    let shortcut: StoredShortcut
    let info: ShortcutConflictInfo
}

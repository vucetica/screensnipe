import AppKit
import Carbon.HIToolbox
import Combine

@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var actionHandler: ((ShortcutAction) -> Void)?
    private var isPaused = false
    private var registeredHotKeys: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var shortcutsObserver: AnyCancellable?

    /// Maps EventHotKeyID.id → ShortcutAction for dispatch in the Carbon callback.
    /// Must be nonisolated (accessed from Carbon callback thread) — safe because
    /// we only mutate it on MainActor before/after registration.
    nonisolated(unsafe) static var idToAction: [UInt32: ShortcutAction] = [:]

    private init() {}

    // MARK: - Public API

    func start(handler: @escaping (ShortcutAction) -> Void) {
        actionHandler = handler
        installCarbonEventHandler()
        registerAllHotKeys()
        observeShortcutChanges()
    }

    func pause() {
        isPaused = true
        unregisterAllHotKeys()
    }

    func resume() {
        isPaused = false
        registerAllHotKeys()
    }

    // MARK: - Carbon Event Handler

    private func installCarbonEventHandler() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            if let action = GlobalHotkeyManager.idToAction[hotKeyID.id] {
                DispatchQueue.main.async {
                    GlobalHotkeyManager.shared.actionHandler?(action)
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    // MARK: - Registration

    private func registerAllHotKeys() {
        unregisterAllHotKeys()

        let manager = ShortcutManager.shared
        for (index, action) in ShortcutAction.allCases.enumerated() {
            let shortcut = manager.shortcut(for: action)
            guard !shortcut.isEmpty, let keyCode = shortcut.keyCode else { continue }

            let carbonMods = Self.carbonModifiers(from: shortcut.modifierFlags)
            let id = UInt32(index + 1)

            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = fourCharCode("SNIP")
            hotKeyID.id = id

            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                carbonMods,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr, let ref {
                registeredHotKeys[action] = ref
                Self.idToAction[id] = action
                NSLog("[HotKey] Registered: %@ (keyCode=%d, mods=0x%x)", action.rawValue, keyCode, carbonMods)
            } else {
                NSLog("[HotKey] Failed to register: %@ (status=%d)", action.rawValue, status)
            }
        }
    }

    private func unregisterAllHotKeys() {
        for (action, ref) in registeredHotKeys {
            UnregisterEventHotKey(ref)
            NSLog("[HotKey] Unregistered: %@", action.rawValue)
        }
        registeredHotKeys.removeAll()
        Self.idToAction.removeAll()
    }

    // MARK: - Observe Shortcut Changes

    private func observeShortcutChanges() {
        shortcutsObserver = ShortcutManager.shared.$shortcuts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isPaused else { return }
                self.registerAllHotKeys()
            }
    }

    // MARK: - Helpers

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) | OSType(char)
    }
    return result
}

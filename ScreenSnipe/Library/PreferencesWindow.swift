import AppKit
import SwiftUI

@MainActor
enum PreferencesWindow {
    private static var window: NSWindow?

    static var isVisible: Bool {
        window != nil
    }

    static func show() {
        if let existing = window {
            NSApp.activate()
            existing.orderFrontRegardless()
            existing.makeKey()
            return
        }

        let prefsView = PreferencesView()
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.title = "Settings"
        newWindow.contentView = NSHostingView(rootView: prefsView)
        newWindow.center()

        let windowDelegate = PreferencesWindowDelegate()
        newWindow.delegate = windowDelegate
        objc_setAssociatedObject(newWindow, &PreferencesWindowDelegate.key, windowDelegate, .OBJC_ASSOCIATION_RETAIN)

        window = newWindow
        GlobalHotkeyManager.shared.pause()

        // If we're coming from accessory mode (no LibraryWindow), switch to regular
        if !LibraryWindow.isVisible {
            NSApp.setActivationPolicy(.regular)
        }

        DispatchQueue.main.async {
            NSApp.activate()
            newWindow.orderFrontRegardless()
            newWindow.makeKey()
        }
    }

    fileprivate static func windowDidClose() {
        window = nil
        GlobalHotkeyManager.shared.resume()

        // Only revert to accessory if LibraryWindow is also closed
        if !LibraryWindow.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Window Delegate

private final class PreferencesWindowDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            PreferencesWindow.windowDidClose()
        }
    }
}

import AppKit
import SwiftUI

@MainActor
enum LibraryWindow {
    private static var window: NSWindow?

    static var isVisible: Bool {
        window != nil
    }

    /// The library window, if open — for parenting toasts and alert sheets.
    static var current: NSWindow? {
        window
    }

    static func show(selecting entry: LibraryEntry? = nil) {
        if let existing = window {
            if let entry {
                LibraryViewModel.shared.selectedEntryIDs = [entry.id]
            }
            NSApp.activate()
            existing.orderFrontRegardless()
            existing.makeKey()
            return
        }

        let viewModel = LibraryViewModel.shared
        if let entry {
            viewModel.selectedEntryIDs = [entry.id]
        }

        let libraryView = LibraryView(viewModel: viewModel)
        let newWindow = ToolbarProtectedWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.title = "Screen Snipe Library"
        newWindow.titlebarAppearsTransparent = false
        newWindow.titleVisibility = .hidden

        // NSToolbar for liquid glass appearance — set BEFORE contentView so it's in place
        // before SwiftUI's NavigationSplitView tries to manage the toolbar
        let toolbarDelegate = LibraryToolbarDelegate()
        let toolbar = NSToolbar(identifier: "LibraryToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        newWindow.toolbar = toolbar
        newWindow.lockToolbar()
        objc_setAssociatedObject(newWindow, &AssociatedKeys.toolbarDelegate, toolbarDelegate, .OBJC_ASSOCIATION_RETAIN)

        newWindow.contentView = NSHostingView(rootView: libraryView)
        newWindow.center()
        newWindow.setFrameAutosaveName("LibraryWindow")
        newWindow.minSize = NSSize(width: 600, height: 400)

        let windowDelegate = LibraryWindowDelegate()
        newWindow.delegate = windowDelegate
        objc_setAssociatedObject(newWindow, &LibraryWindowDelegate.key, windowDelegate, .OBJC_ASSOCIATION_RETAIN)

        window = newWindow
        NSApp.setActivationPolicy(.regular)
        // Defer activation to next run loop tick — macOS needs time to finish
        // the .accessory → .regular transition before activate() will succeed.
        DispatchQueue.main.async {
            NSApp.activate()
            newWindow.orderFrontRegardless()
            newWindow.makeKey()
            Self.configureSplitViewAutosave(in: newWindow)
            Self.installProtectedMenu()
        }
    }

    static func hideAll() {
        window?.orderOut(nil)
    }

    static func showAll() {
        window?.orderFront(nil)
    }

    fileprivate static func windowDidClose() {
        window = nil
        (NSApp.delegate as? AppDelegate)?.mainMenuMicSubmenu = nil
        // Restore SwiftUI's original menu so it doesn't fight with our protected one
        if let protectedMenu = NSApp.mainMenu as? ProtectedMenu {
            NSApp.mainMenu = protectedMenu.originalMenu
        }
        if !PreferencesWindow.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Protected Menu

    /// Replaces NSApp.mainMenu with a ProtectedMenu that prevents SwiftUI from
    /// removing our injected items. Mirrors the ToolbarProtectedWindow pattern.
    private static func installProtectedMenu() {
        guard let swiftUIMenu = NSApp.mainMenu else { return }

        let protectedMenu = ProtectedMenu(title: swiftUIMenu.title)
        protectedMenu.originalMenu = swiftUIMenu
        protectedMenu.autoenablesItems = swiftUIMenu.autoenablesItems

        // Copy SwiftUI's existing items
        for item in swiftUIMenu.items {
            swiftUIMenu.removeItem(item)
            protectedMenu.addItem(item)
        }

        // Remove menus we don't want (Edit, File, View, Help)
        protectedMenu.items.removeAll { ["Edit", "File", "View", "Help"].contains($0.submenu?.title) }

        // Enrich the app menu (About, Settings, Help)
        enrichAppMenu(protectedMenu)

        // Inject Actions menu before Window, tagged as protected
        let actionsItem = buildActionsMenu()
        actionsItem.tag = ProtectedMenu.protectedTag
        let actionsIndex = protectedMenu.items.firstIndex { $0.submenu?.title == "Window" }
            ?? protectedMenu.items.count
        protectedMenu.insertItem(actionsItem, at: actionsIndex)

        // Lock and install — SwiftUI can no longer strip our items
        protectedMenu.lock()
        NSApp.mainMenu = protectedMenu
    }

    private static func enrichAppMenu(_ mainMenu: NSMenu) {
        guard let appMenu = mainMenu.items.first?.submenu else { return }
        // Add About if missing
        if appMenu.items.first(where: { $0.title.contains("About") }) == nil {
            appMenu.insertItem(withTitle: "About Screen Snipe",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: "", at: 0)
            appMenu.insertItem(.separator(), at: 1)
        }
        // Add Settings if missing
        if appMenu.items.first(where: { $0.title.contains("Settings") || $0.title.contains("Preferences") }) == nil {
            let settingsIndex = min(2, appMenu.items.count)
            appMenu.insertItem(withTitle: "Settings…",
                               action: #selector(AppDelegate.preferencesAction),
                               keyEquivalent: ",", at: settingsIndex)
            appMenu.insertItem(.separator(), at: settingsIndex + 1)
        }
        // Add Screen Snipe Help before Quit (matching status bar menu layout)
        if appMenu.items.first(where: { $0.title.contains("Help") }) == nil {
            let quitIndex = appMenu.items.firstIndex(where: { $0.title.contains("Quit") }) ?? appMenu.items.count
            let helpItem = NSMenuItem(title: "Screen Snipe Help", action: #selector(AppDelegate.openSupportPage), keyEquivalent: "")
            helpItem.target = NSApp.delegate as? AppDelegate
            appMenu.insertItem(.separator(), at: quitIndex)
            appMenu.insertItem(helpItem, at: quitIndex + 1)
        }
    }

    private static func buildActionsMenu() -> NSMenuItem {
        let actionsMenuItem = NSMenuItem()
        let actionsMenu = NSMenu(title: "Actions")
        actionsMenu.autoenablesItems = false
        let appDelegate = NSApp.delegate as? AppDelegate

        // Capture submenu
        let captureItem = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        captureItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Capture")
        let captureSubmenu = NSMenu()
        captureSubmenu.autoenablesItems = false
        let capRegion = NSMenuItem(title: "Region", action: #selector(AppDelegate.captureRegion), keyEquivalent: "")
        capRegion.target = appDelegate
        capRegion.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Region")
        captureSubmenu.addItem(capRegion)
        let capFullScreen = NSMenuItem(title: "Full Screen", action: #selector(AppDelegate.captureFullScreen), keyEquivalent: "")
        capFullScreen.target = appDelegate
        capFullScreen.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Full Screen")
        captureSubmenu.addItem(capFullScreen)
        let capWindow = NSMenuItem(title: "Window", action: #selector(AppDelegate.captureWindowAction), keyEquivalent: "")
        capWindow.target = appDelegate
        capWindow.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window")
        captureSubmenu.addItem(capWindow)
        captureItem.submenu = captureSubmenu
        actionsMenu.addItem(captureItem)

        // Record submenu
        let recordItem = NSMenuItem(title: "Record", action: nil, keyEquivalent: "")
        recordItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        let recordSubmenu = NSMenu()
        recordSubmenu.autoenablesItems = false
        let recRegion = NSMenuItem(title: "Region", action: #selector(AppDelegate.recordRegionAction), keyEquivalent: "")
        recRegion.target = appDelegate
        recRegion.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Region")
        recordSubmenu.addItem(recRegion)
        let recFullScreen = NSMenuItem(title: "Full Screen", action: #selector(AppDelegate.recordFullScreen), keyEquivalent: "")
        recFullScreen.target = appDelegate
        recFullScreen.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Full Screen")
        recordSubmenu.addItem(recFullScreen)
        let recWindow = NSMenuItem(title: "Window", action: #selector(AppDelegate.recordWindowAction), keyEquivalent: "")
        recWindow.target = appDelegate
        recWindow.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window")
        recordSubmenu.addItem(recWindow)
        recordSubmenu.addItem(.separator())
        let sysAudioItem = NSMenuItem(title: "System Audio", action: #selector(AppDelegate.toggleSystemAudio), keyEquivalent: "")
        sysAudioItem.target = appDelegate
        recordSubmenu.addItem(sysAudioItem)
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSub = NSMenu()
        if let appDelegate {
            micSub.delegate = appDelegate
            appDelegate.mainMenuMicSubmenu = micSub
        }
        micItem.submenu = micSub
        recordSubmenu.addItem(micItem)
        recordItem.submenu = recordSubmenu
        actionsMenu.addItem(recordItem)

        // Apply current shortcuts to Actions items
        let shortcuts = ShortcutManager.shared
        let shortcutMap: [(ShortcutAction, NSMenuItem)] = [
            (.captureRegion, capRegion), (.captureFullScreen, capFullScreen), (.captureWindow, capWindow),
            (.recordRegion, recRegion), (.recordFullScreen, recFullScreen), (.recordWindow, recWindow),
        ]
        for (action, item) in shortcutMap {
            let s = shortcuts.shortcut(for: action)
            item.keyEquivalent = s.keyEquivalent
            item.keyEquivalentModifierMask = s.modifierFlags
        }

        actionsMenuItem.submenu = actionsMenu
        return actionsMenuItem
    }

    private static func configureSplitViewAutosave(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let splitViews = findAllSplitViews(in: contentView)

        // First split view = NavigationSplitView (sidebar | detail)
        if splitViews.count >= 1 {
            splitViews[0].autosaveName = "LibrarySplitView"
        }

        // Second split view = Inspector (content | inspector panel)
        if splitViews.count >= 2 {
            splitViews[1].autosaveName = "LibraryInspectorSplitView"
        }
    }

    private static func findAllSplitViews(in view: NSView) -> [NSSplitView] {
        var result: [NSSplitView] = []
        if let splitView = view as? NSSplitView {
            result.append(splitView)
        }
        for subview in view.subviews {
            result.append(contentsOf: findAllSplitViews(in: subview))
        }
        return result
    }
}

// MARK: - Protected Menu

/// NSMenu subclass that prevents SwiftUI from removing tagged items.
/// Same pattern as ToolbarProtectedWindow — intercept mutations to protect our items.
final class ProtectedMenu: NSMenu {
    static let protectedTag = 9999
    static let blockedTitles: Set<String> = ["Edit", "File", "View", "Help"]
    var originalMenu: NSMenu?
    private var isLocked = false

    func lock() { isLocked = true }

    private func isBlocked(_ item: NSMenuItem) -> Bool {
        guard let title = item.submenu?.title else { return false }
        return Self.blockedTitles.contains(title)
    }

    override func addItem(_ newItem: NSMenuItem) {
        if isLocked && isBlocked(newItem) { return }
        super.addItem(newItem)
    }

    override func insertItem(_ newItem: NSMenuItem, at index: Int) {
        if isLocked && isBlocked(newItem) { return }
        super.insertItem(newItem, at: index)
    }

    override func removeItem(_ item: NSMenuItem) {
        if isLocked && item.tag == Self.protectedTag { return }
        super.removeItem(item)
    }

    override func removeItem(at index: Int) {
        if isLocked && index < items.count && items[index].tag == Self.protectedTag { return }
        super.removeItem(at: index)
    }
}

// MARK: - Toolbar-Protected Window

/// NSWindow subclass that prevents SwiftUI's NavigationSplitView from replacing
/// the toolbar when detail content changes.  Also serves as the responder-chain
/// fallback for Edit menu actions (undo/redo/copy/delete on annotations).
final class ToolbarProtectedWindow: NSWindow {
    private var isToolbarLocked = false

    func lockToolbar() {
        isToolbarLocked = true
    }

    override var toolbar: NSToolbar? {
        get { super.toolbar }
        set {
            guard !isToolbarLocked else { return }
            super.toolbar = newValue
        }
    }

    // MARK: - Edit Menu Actions (responder-chain fallback)

    @objc func menuUndo(_ sender: Any?) {
        LibraryViewModel.shared.annotationStore.undo()
    }

    @objc func menuRedo(_ sender: Any?) {
        LibraryViewModel.shared.annotationStore.redo()
    }

    @objc func menuCopy(_ sender: Any?) {
        guard let image = LibraryViewModel.shared.selectedImage else { return }
        let store = LibraryViewModel.shared.annotationStore
        ImageExportService.copyToClipboard(image: image, annotations: store.annotations, cropRect: store.cropRect)
        CopiedToast.show(in: self)
    }

    @objc func menuDelete(_ sender: Any?) {
        LibraryViewModel.shared.annotationStore.removeSelected()
    }

    @objc func toggleInspector(_ sender: Any?) {
        LibraryViewModel.shared.showInspector.toggle()
    }
}

// MARK: - Associated Keys

private enum AssociatedKeys {
    nonisolated(unsafe) static var toolbarDelegate: UInt8 = 0
}

// MARK: - Window Delegate

private final class LibraryWindowDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            LibraryWindow.windowDidClose()
        }
    }
}

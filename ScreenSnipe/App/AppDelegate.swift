import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    let coordinator = CaptureCoordinator()

    // Menu item references for shortcut updates
    private var captureRegionItem: NSMenuItem?
    private var captureFullScreenItem: NSMenuItem?
    private var captureWindowItem: NSMenuItem?
    private var recordFullScreenItem: NSMenuItem?
    private var recordRegionItem: NSMenuItem?
    private var recordWindowItem: NSMenuItem?
    private var stopRecordingItem: NSMenuItem?
    private var pauseResumeItem: NSMenuItem?
    private var libraryItem: NSMenuItem?

    // Audio menu items
    private var systemAudioItem: NSMenuItem?
    private var micSubmenu: NSMenu?
    var mainMenuMicSubmenu: NSMenu?

    private var recordingObserver: AnyCancellable?
    private var pauseObserver: AnyCancellable?
    private var countdownObserver: AnyCancellable?
    private var shortcutsObserver: AnyCancellable?
    private var blinkTimer: Timer?
    private var welcomePopover: NSPopover?
    private var audioInfoPopover: NSPopover?

    private static let hasLaunchedBeforeKey = "hasLaunchedBefore"

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Backstop for launches that bypass Launch Services (open -n, direct
        // binary execution); Finder/Dock launches are already blocked by
        // LSMultipleInstancesProhibited in Info.plist.
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let isAlreadyRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if isAlreadyRunning {
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSWindow.allowsAutomaticWindowTabbing = false
        setupMenuBarIcon()
        observeRecordingState()
        observeShortcuts()
        startGlobalHotkeys()
        showWelcomePopoverIfFirstLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            LibraryWindow.show()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screen Snipe")
        }

        let menu = NSMenu()

        // Capture submenu
        let captureItem = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
        captureItem.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Capture")
        let captureSubmenu = NSMenu()

        let regionItem = NSMenuItem(title: "Region", action: #selector(captureRegion), keyEquivalent: "")
        regionItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Region")
        captureSubmenu.addItem(regionItem)
        captureRegionItem = regionItem

        let fullScreenItem = NSMenuItem(title: "Full Screen", action: #selector(captureFullScreen), keyEquivalent: "")
        fullScreenItem.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Full Screen")
        captureSubmenu.addItem(fullScreenItem)
        captureFullScreenItem = fullScreenItem

        let windowItem = NSMenuItem(title: "Window", action: #selector(captureWindowAction), keyEquivalent: "")
        windowItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window")
        captureSubmenu.addItem(windowItem)
        captureWindowItem = windowItem

        captureItem.submenu = captureSubmenu
        menu.addItem(captureItem)

        // Record submenu
        let recordItem = NSMenuItem(title: "Record", action: nil, keyEquivalent: "")
        recordItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        let recordSubmenu = NSMenu()

        let recordRG = NSMenuItem(title: "Region", action: #selector(recordRegionAction), keyEquivalent: "")
        recordRG.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Region")
        recordSubmenu.addItem(recordRG)
        recordRegionItem = recordRG
        
        let recordFS = NSMenuItem(title: "Full Screen", action: #selector(recordFullScreen), keyEquivalent: "")
        recordFS.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Full Screen")
        recordSubmenu.addItem(recordFS)
        recordFullScreenItem = recordFS

        let recordWD = NSMenuItem(title: "Window", action: #selector(recordWindowAction), keyEquivalent: "")
        recordWD.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window")
        recordSubmenu.addItem(recordWD)
        recordWindowItem = recordWD

        recordSubmenu.addItem(NSMenuItem.separator())

        // System Audio toggle
        let sysAudioItem = NSMenuItem(title: "System Audio", action: #selector(toggleSystemAudio), keyEquivalent: "")
        sysAudioItem.state = AudioSettings.shared.systemAudioEnabled ? .on : .off
        recordSubmenu.addItem(sysAudioItem)
        systemAudioItem = sysAudioItem

        // Microphone submenu
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micSub = NSMenu()
        micSub.delegate = self
        micItem.submenu = micSub
        recordSubmenu.addItem(micItem)
        micSubmenu = micSub

        recordItem.submenu = recordSubmenu
        menu.addItem(recordItem)

        // Pause/Resume Recording (top-level, hidden when not recording)
        let pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePauseRecording), keyEquivalent: "")
        pauseItem.isHidden = true
        menu.addItem(pauseItem)
        pauseResumeItem = pauseItem

        // Stop Recording (top-level, hidden when not recording)
        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.isHidden = true
        menu.addItem(stopItem)
        stopRecordingItem = stopItem

        menu.addItem(NSMenuItem.separator())

        let libItem = NSMenuItem(title: "Library", action: #selector(showLibrary), keyEquivalent: "")
        libItem.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Library")
        menu.addItem(libItem)
        libraryItem = libItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(preferencesAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Screen Snipe Help", action: #selector(openSupportPage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About Screen Snipe", action: #selector(aboutAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Screen Snipe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))

        statusItem?.menu = menu

        applyShortcuts()
    }

    // MARK: - Shortcuts

    private func observeShortcuts() {
        shortcutsObserver = ShortcutManager.shared.$shortcuts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyShortcuts()
            }
    }

    private func applyShortcuts() {
        let manager = ShortcutManager.shared
        let actionToMenuItem: [ShortcutAction: NSMenuItem?] = [
            .captureRegion: captureRegionItem,
            .captureFullScreen: captureFullScreenItem,
            .captureWindow: captureWindowItem,
            .recordFullScreen: recordFullScreenItem,
            .recordRegion: recordRegionItem,
            .recordWindow: recordWindowItem,
            .stopRecording: stopRecordingItem,
            .pauseResumeRecording: pauseResumeItem,
            .openLibrary: libraryItem,
        ]
        for (action, menuItem) in actionToMenuItem {
            guard let menuItem else { continue }
            let shortcut = manager.shortcut(for: action)
            menuItem.keyEquivalent = shortcut.keyEquivalent
            menuItem.keyEquivalentModifierMask = shortcut.modifierFlags
        }

        // Also update main menu bar Actions items (when Library window is open)
        guard let mainMenu = NSApp.mainMenu else { return }
        let actionToSelector: [ShortcutAction: Selector] = [
            .captureRegion: #selector(captureRegion),
            .captureFullScreen: #selector(captureFullScreen),
            .captureWindow: #selector(captureWindowAction),
            .recordFullScreen: #selector(recordFullScreen),
            .recordRegion: #selector(recordRegionAction),
            .recordWindow: #selector(recordWindowAction),
            .stopRecording: #selector(stopRecording),
            .pauseResumeRecording: #selector(togglePauseRecording),
            .openLibrary: #selector(showLibrary),
        ]
        for (action, selector) in actionToSelector {
            if let item = Self.findMenuItem(in: mainMenu, withAction: selector) {
                let shortcut = manager.shortcut(for: action)
                item.keyEquivalent = shortcut.keyEquivalent
                item.keyEquivalentModifierMask = shortcut.modifierFlags
            }
        }
    }

    private static func findMenuItem(in menu: NSMenu, withAction action: Selector) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu,
               let found = findMenuItem(in: submenu, withAction: action) {
                return found
            }
        }
        return nil
    }

    private func startGlobalHotkeys() {
        GlobalHotkeyManager.shared.start { [weak self] action in
            guard let self else { return }
            switch action {
            case .captureRegion:
                self.coordinator.startCapture(mode: .region)
            case .captureFullScreen:
                self.coordinator.startCapture(mode: .fullScreen)
            case .captureWindow:
                self.coordinator.startCapture(mode: .window)
            case .recordFullScreen:
                self.coordinator.startFullScreenRecording()
            case .recordRegion:
                self.coordinator.startRegionRecording()
            case .recordWindow:
                self.coordinator.startWindowRecording()
            case .stopRecording:
                self.coordinator.stopRecording()
            case .pauseResumeRecording:
                if self.coordinator.videoService.isPaused {
                    self.coordinator.resumeRecording()
                } else {
                    self.coordinator.pauseRecording()
                }
            case .openLibrary:
                LibraryWindow.show()
            }
        }
    }

    private func observeRecordingState() {
        recordingObserver = coordinator.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                self?.updateRecordingUI(isRecording: isRecording)
            }

        pauseObserver = coordinator.videoService.$isPaused
            .receive(on: RunLoop.main)
            .sink { [weak self] isPaused in
                self?.updatePauseUI(isPaused: isPaused)
            }

        countdownObserver = coordinator.$isCountingDown
            .receive(on: RunLoop.main)
            .sink { [weak self] isCountingDown in
                if isCountingDown {
                    self?.showAudioInfoPopover()
                } else {
                    self?.audioInfoPopover?.close()
                    self?.audioInfoPopover = nil
                }
            }
    }

    private func updateRecordingUI(isRecording: Bool) {
        if isRecording {
            recordFullScreenItem?.isEnabled = false
            recordRegionItem?.isEnabled = false
            recordWindowItem?.isEnabled = false
            stopRecordingItem?.isHidden = false
            pauseResumeItem?.isHidden = false
            startIconBlink()
        } else {
            recordFullScreenItem?.isEnabled = true
            recordRegionItem?.isEnabled = true
            recordWindowItem?.isEnabled = true
            stopRecordingItem?.isHidden = true
            pauseResumeItem?.isHidden = true
            stopIconBlink()
        }
    }

    private func updatePauseUI(isPaused: Bool) {
        pauseResumeItem?.title = isPaused ? "Resume Recording" : "Pause Recording"
        guard coordinator.isRecording else { return }
        if isPaused {
            showPausedIcon()
        } else {
            startIconBlink()
        }
    }

    // MARK: - Icon Blink

    private func startIconBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil

        guard let button = statusItem?.button else { return }

        // Set red recording icon
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config)

        // Fade in/out animation loop
        var fadingOut = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak button] _ in
            guard let button else { return }
            if fadingOut {
                button.alphaValue -= 0.025
                if button.alphaValue <= 0.3 {
                    fadingOut = false
                }
            } else {
                button.alphaValue += 0.025
                if button.alphaValue >= 1.0 {
                    fadingOut = true
                }
            }
        }
    }

    private func showPausedIcon() {
        blinkTimer?.invalidate()
        blinkTimer = nil

        guard let button = statusItem?.button else { return }
        button.alphaValue = 1.0
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        button.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")?
            .withSymbolConfiguration(config)
    }

    private func stopIconBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil

        guard let button = statusItem?.button else { return }
        button.alphaValue = 1.0
        button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screen Snipe")
    }

    // MARK: - Welcome Popover

    private func showWelcomePopoverIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)

        // Short delay so the status item is fully laid out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let button = self?.statusItem?.button else { return }

            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: WelcomePopoverView())
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self?.welcomePopover = popover
        }
    }

    // MARK: - Audio Info Popover

    private func showAudioInfoPopover() {
        audioInfoPopover?.close()
        audioInfoPopover = nil

        guard let button = statusItem?.button else { return }

        let settings = AudioSettings.shared
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(
            rootView: AudioInfoPopoverView(
                systemAudioEnabled: settings.systemAudioEnabled,
                micDeviceName: settings.selectedMicDevice?.localizedName
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        audioInfoPopover = popover
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        // NSMenuDelegate is always called on the main thread.
        // Use nonisolated(unsafe) to pass NSMenu across isolation boundary safely.
        nonisolated(unsafe) let unsafeMenu = menu
        MainActor.assumeIsolated {
            let identity = Int(bitPattern: ObjectIdentifier(unsafeMenu))
            let isMic: Bool = [self.micSubmenu, self.mainMenuMicSubmenu].contains {
                guard let sub = $0 else { return false }
                return Int(bitPattern: ObjectIdentifier(sub)) == identity
            }
            guard isMic else { return }
            self.rebuildMicMenu(unsafeMenu)
        }
    }

    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        nonisolated(unsafe) let unsafeItem = menuItem
        MainActor.assumeIsolated {
            if unsafeItem.action == #selector(self.toggleSystemAudio) {
                unsafeItem.state = AudioSettings.shared.systemAudioEnabled ? .on : .off
            }
        }
        return true
    }

    private func rebuildMicMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let selectedUID = AudioSettings.shared.selectedMicDeviceUID

        // "None" option
        let noneItem = NSMenuItem(title: "None", action: #selector(selectMicNone), keyEquivalent: "")
        noneItem.state = selectedUID == nil ? .on : .off
        menu.addItem(noneItem)

        // Available microphones
        let mics = AudioSettings.availableMicrophones()
        for mic in mics {
            let item = NSMenuItem(title: mic.localizedName, action: #selector(selectMicDevice(_:)), keyEquivalent: "")
            item.representedObject = mic
            item.state = mic.uniqueID == selectedUID ? .on : .off
            menu.addItem(item)
        }

        // Show disconnected device if previously selected but no longer available
        if let uid = selectedUID, !mics.contains(where: { $0.uniqueID == uid }) {
            let item = NSMenuItem(title: "Unknown Device", action: nil, keyEquivalent: "")
            item.state = .on
            item.isEnabled = false
            menu.addItem(item)
        }
    }

    // MARK: - Audio Actions

    @objc func toggleSystemAudio() {
        AudioSettings.shared.systemAudioEnabled.toggle()
        systemAudioItem?.state = AudioSettings.shared.systemAudioEnabled ? .on : .off
        // Apply immediately if recording
        if coordinator.isRecording {
            coordinator.videoService.setSystemAudioEnabled(AudioSettings.shared.systemAudioEnabled)
        }
    }

    @objc func selectMicNone() {
        AudioSettings.shared.selectedMicDeviceUID = nil
        if coordinator.isRecording {
            Task { await coordinator.videoService.switchMicrophone(to: nil) }
        }
    }

    @objc func selectMicDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AVCaptureDevice else { return }
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { return }
            AudioSettings.shared.selectedMicDeviceUID = device.uniqueID
            if coordinator.isRecording {
                await coordinator.videoService.switchMicrophone(to: device)
            }
        }
    }

    // MARK: - Actions

    @objc func captureRegion() {
        coordinator.startCapture(mode: .region)
    }

    @objc func captureFullScreen() {
        coordinator.startCapture(mode: .fullScreen)
    }

    @objc func captureWindowAction() {
        coordinator.startCapture(mode: .window)
    }

    @objc func recordFullScreen() {
        coordinator.startFullScreenRecording()
    }

    @objc func recordRegionAction() {
        coordinator.startRegionRecording()
    }

    @objc func recordWindowAction() {
        coordinator.startWindowRecording()
    }

    @objc func togglePauseRecording() {
        if coordinator.videoService.isPaused {
            coordinator.resumeRecording()
        } else {
            coordinator.pauseRecording()
        }
    }

    @objc func stopRecording() {
        coordinator.stopRecording()
    }

    @objc func showLibrary() {
        LibraryWindow.show()
    }

    @objc func openSupportPage() {
        NSWorkspace.shared.open(URL(string: "https://support.screensnipe.app")!)
    }

    @objc private func aboutAction() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc func preferencesAction() {
        PreferencesWindow.show()
    }
}

// MARK: - Audio Info Popover View

private struct AudioInfoPopoverView: View {
    let systemAudioEnabled: Bool
    let micDeviceName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(systemAudioEnabled ? "System audio" : "System audio off")
                    .foregroundStyle(systemAudioEnabled ? .primary : .secondary)
            } icon: {
                Image(systemName: systemAudioEnabled ? "speaker.wave.2" : "speaker.slash")
                    .foregroundStyle(systemAudioEnabled ? .primary : .secondary)
            }
            Label {
                Text(micDeviceName ?? "No microphone")
                    .foregroundStyle(micDeviceName != nil ? .primary : .secondary)
            } icon: {
                Image(systemName: micDeviceName != nil ? "mic" : "mic.slash")
                    .foregroundStyle(micDeviceName != nil ? .primary : .secondary)
            }
        }
        .fixedSize()
        .padding()
    }
}

// MARK: - Welcome Popover View

private struct WelcomePopoverView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) { 
                Text("Screen Snipe is ready!")
                    .font(.headline)
                Text("Click this icon to capture screenshots\nand record your screen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding()
    }
}

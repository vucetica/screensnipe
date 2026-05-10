import AppKit
import Combine
import SwiftUI
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator: ObservableObject {

    enum State {
        case idle
        case selectingRegion
        case selectingWindow
        case capturing
        case editing(NSImage)
        case recording
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var isCountingDown = false

    private let captureService = ScreenCaptureService()
    let videoService = VideoRecordingService()
    private var regionSelectionWindow: RegionSelectionWindow?
    private var windowPickerWindow: NSWindow?
    private var countdownOverlay: CountdownOverlay?
    private var recordingBorderWindow: RecordingBorderWindow?
    private var frozenScreenshot: CGImage?
    private var writerErrorObserver: AnyCancellable?

    init() {
        writerErrorObserver = videoService.$writerError
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] error in
                guard let self, self.isRecording else { return }
                self.recordingBorderWindow?.hide()
                self.recordingBorderWindow = nil
                self.state = .idle
                self.isRecording = false
                self.showError(error)
            }
    }

    // MARK: - Public API

    func startCapture(mode: CaptureMode) {
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            switch mode {
            case .fullScreen:
                captureFullScreen()
            case .region:
                beginRegionSelection()
            case .window:
                await showWindowPicker()
            }
        }
    }

    /// Returns true if screen capture access is granted.
    /// On first call, triggers the system permission prompt and registers the app
    /// in System Settings > Screen Recording.
    private func ensureScreenCaptureAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        // CGRequestScreenCaptureAccess triggers the system prompt and registers
        // the app in Screen Recording settings (works for non-sandboxed debug builds).
        // For sandboxed Release builds, SCShareableContent also triggers the prompt.
        CGRequestScreenCaptureAccess()
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            return true
        } catch {
            // Permission not yet granted — show guidance
        }
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Screen Snipe needs screen recording permission to capture screenshots.\n\nPlease enable it in System Settings → Privacy & Security → Screen Recording, then try again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    func cancel() {
        regionSelectionWindow?.orderOut(nil)
        regionSelectionWindow = nil
        state = .idle
        LibraryWindow.showAll()
    }

    // MARK: - Full Screen

    private func captureFullScreen() {
        state = .capturing
        LibraryWindow.hideAll()
        do {
            let image = try captureService.captureFullScreen()
            openEditor(with: image)
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
        }
    }

    // MARK: - Region

    private func beginRegionSelection() {
        state = .selectingRegion

        // Capture the frozen screenshot BEFORE hiding anything —
        // this avoids a visible "bounce" from the library window disappearing.
        // The full-screen overlay will cover the library window anyway.
        do {
            let screenshot = try captureService.captureFullScreenCGImage()
            LibraryWindow.hideAll()
            frozenScreenshot = screenshot
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let displayImage = NSImage(cgImage: screenshot, size: screen.frame.size)

            let window = RegionSelectionWindow(frozenImage: displayImage) { [weak self] region in
                guard let self else { return }
                self.captureRegionFromFrozen(region)
                self.regionSelectionWindow?.close()
                self.regionSelectionWindow = nil
            } onCancel: { [weak self] in
                self?.frozenScreenshot = nil
                self?.cancel()
            }
            regionSelectionWindow = window
            // Show fully transparent, wait one frame for the frozen image to render,
            // then reveal — eliminates the visual pop.
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                window.alphaValue = 1
            }
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
        }
    }

    private func captureRegionFromFrozen(_ region: CGRect) {
        state = .capturing
        guard let screenshot = frozenScreenshot else {
            state = .idle
            LibraryWindow.showAll()
            return
        }
        frozenScreenshot = nil
        let screen = NSScreen.main ?? NSScreen.screens[0]
        do {
            let image = try captureService.cropRegion(from: screenshot, region: region, screenSize: screen.frame.size)
            openEditor(with: image)
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
        }
    }

    private func captureRegion(_ region: CGRect) {
        state = .capturing
        do {
            let image = try captureService.captureRegion(region)
            openEditor(with: image)
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
        }
    }

    // MARK: - Window

    func showWindowPicker() async {
        state = .selectingWindow
        LibraryWindow.hideAll()
        do {
            let windows = try await captureService.availableWindows()
            let pickerView = WindowPickerView(windows: windows) { [weak self] window in
                guard let self else { return }
                self.windowPickerWindow?.close()
                self.windowPickerWindow = nil
                self.captureWindow(window)
            } onCancel: { [weak self] in
                self?.windowPickerWindow?.close()
                self?.windowPickerWindow = nil
                self?.state = .idle
                LibraryWindow.showAll()
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Select Window"
            window.contentView = NSHostingView(rootView: pickerView)
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            windowPickerWindow = window
        } catch {
            state = .idle
            showError(error)
        }
    }

    private func captureWindow(_ window: SCWindow) {
        state = .capturing
        do {
            let image = try captureService.captureWindow(window)
            openEditor(with: image)
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
        }
    }

    // MARK: - Video Recording

    func startFullScreenRecording() {
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            beginRecordingWithCountdown(target: .fullScreen)
        }
    }

    func startRegionRecording() {
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            state = .selectingRegion
            LibraryWindow.hideAll()
            let window = RegionSelectionWindow { [weak self] region in
                guard let self else { return }
                self.regionSelectionWindow?.orderOut(nil)
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    self.regionSelectionWindow?.close()
                    self.regionSelectionWindow = nil
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first else {
                        self.state = .idle
                        LibraryWindow.showAll()
                        self.showError(VideoRecordingService.RecordingError.noDisplayFound)
                        return
                    }
                    self.beginRecordingWithCountdown(target: .region(display: display, cropRect: region))
                }
            } onCancel: { [weak self] in
                self?.cancel()
            }
            regionSelectionWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    func startWindowRecording() {
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            state = .selectingWindow
            LibraryWindow.hideAll()
            do {
                let windows = try await captureService.availableWindows()
                let pickerView = WindowPickerView(windows: windows) { [weak self] scWindow in
                    guard let self else { return }
                    self.windowPickerWindow?.close()
                    self.windowPickerWindow = nil
                    self.beginRecordingWithCountdown(target: .window(scWindow))
                } onCancel: { [weak self] in
                    self?.windowPickerWindow?.close()
                    self?.windowPickerWindow = nil
                    self?.state = .idle
                    LibraryWindow.showAll()
                }

                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                    styleMask: [.titled, .closable],
                    backing: .buffered,
                    defer: false
                )
                window.isReleasedWhenClosed = false
                window.title = "Select Window to Record"
                window.contentView = NSHostingView(rootView: pickerView)
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                windowPickerWindow = window
            } catch {
                state = .idle
                LibraryWindow.showAll()
                showError(error)
            }
        }
    }

    private func beginRecordingWithCountdown(target: VideoRecordingService.RecordingTarget) {
        isCountingDown = true
        let overlay = CountdownOverlay()
        countdownOverlay = overlay
        overlay.show { [weak self] in
            guard let self else { return }
            self.countdownOverlay = nil
            self.isCountingDown = false
            Task {
                do {
                    let settings = AudioSettings.shared
                    let audioConfig = VideoRecordingService.AudioConfig(
                        captureSystemAudio: settings.systemAudioEnabled,
                        micDevice: settings.selectedMicDevice
                    )
                    try await self.videoService.startRecording(target: target, audio: audioConfig)
                    self.state = .recording
                    self.isRecording = true
                    self.showRecordingBorder(for: target)
                } catch {
                    self.state = .idle
                    LibraryWindow.showAll()
                    self.showError(error)
                }
            }
        }
    }

    func pauseRecording() {
        videoService.pauseRecording()
    }

    func resumeRecording() {
        videoService.resumeRecording()
    }

    func stopRecording() {
        recordingBorderWindow?.hide()
        recordingBorderWindow = nil
        Task {
            do {
                let fileURL = try await videoService.stopRecording()
                state = .idle
                isRecording = false
                guard await LibraryManager.shared.ensureLibraryLocation() else {
                    showError(NSError(domain: "CaptureCoordinator", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Recording not saved — no library folder selected."]))
                    return
                }
                let entry = try LibraryManager.shared.saveVideo(from: fileURL)
                LibraryWindow.show(selecting: entry)
            } catch {
                state = .idle
                isRecording = false
                showError(error)
            }
        }
    }

    // MARK: - Recording Border

    private func showRecordingBorder(for target: VideoRecordingService.RecordingTarget) {
        let trackingTarget: RecordingBorderWindow.TrackingTarget
        switch target {
        case .fullScreen:
            return
        case .region(_, let cropRect):
            trackingTarget = .staticRegion(cropRect)
        case .window(let scWindow):
            trackingTarget = .trackedWindow(CGWindowID(scWindow.windowID))
        }
        let border = RecordingBorderWindow()
        border.show(for: trackingTarget)
        recordingBorderWindow = border
    }

    // MARK: - Editor

    private func openEditor(with image: NSImage) {
        let behavior = CaptureSettings.shared.postCaptureBehavior

        let shouldCopy = behavior == .copyToClipboard || behavior == .both
        let shouldOpen = behavior == .openInEditor || behavior == .both

        if shouldCopy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }

        if shouldOpen {
            state = .editing(image)
            Task {
                guard await LibraryManager.shared.ensureLibraryLocation() else {
                    // Clipboard copy already done above if configured; just go idle.
                    state = .idle
                    LibraryWindow.showAll()
                    return
                }
                do {
                    let entry = try LibraryManager.shared.saveImage(image)
                    LibraryWindow.show(selecting: entry)
                } catch {
                    showError(error)
                }
            }
        } else {
            state = .idle
            LibraryWindow.showAll()
        }
    }

    // MARK: - Alerts

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Capture Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}

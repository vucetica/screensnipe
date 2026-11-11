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
        case seriesActive
        case scrollingActive
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isRecording = false
    @Published private(set) var isCountingDown = false
    @Published private(set) var isSeriesActive = false
    @Published private(set) var seriesFrameCount = 0
    @Published private(set) var isScrollingActive = false

    /// True while a capture or recording flow is actively in progress and a new one
    /// must not be started. `.editing` is intentionally excluded: it's the post-capture
    /// state (the editor/library is open) and starting a fresh capture from there is fine.
    var isBusy: Bool {
        if isCountingDown { return true }
        switch state {
        case .selectingRegion, .selectingWindow, .capturing, .recording, .seriesActive, .scrollingActive:
            return true
        case .idle, .editing:
            return false
        }
    }

    /// Use in place of `guard !isBusy` at the start of every capture flow.
    /// When the flow that is blocking is a window picker, the picker is
    /// brought to the front, so an ignored click shows the user what the app
    /// is waiting for instead of doing nothing at all.
    private func rejectIfBusy() -> Bool {
        guard isBusy else { return false }
        if let picker = windowPickerWindow {
            picker.orderFrontRegardless()
            picker.makeKey()
        }
        return true
    }

    private let captureService = ScreenCaptureService()
    let videoService = VideoRecordingService()
    private var regionSelectionWindow: RegionSelectionWindow?
    private var windowPickerWindow: NSWindow?
    private var windowPickerCloseObserver: NSObjectProtocol?
    private var countdownOverlay: CountdownOverlay?
    private var recordingBorderWindow: RecordingBorderWindow?
    private var frozenScreenshot: CGImage?
    /// Point size of the display `frozenScreenshot` was taken from, so the crop
    /// uses the same display the overlay was drawn on even if the key window
    /// (and with it `NSScreen.main`) has moved since.
    private var frozenScreenshotPointSize: CGSize?
    private var writerErrorObserver: AnyCancellable?

    private var seriesSession: SeriesSession?
    private var seriesHUD: SeriesHUDWindow?
    private var seriesBorder: RecordingBorderWindow?
    private var seriesTargetAvailable = true
    /// Guards against re-entrancy from hotkey autorepeat. Deliberately separate
    /// from `state`, which must stay `.seriesActive` for the whole session.
    private var isSnapping = false

    private var scrollingSession: ScrollingSession?
    private var scrollingHUD: ScrollingCaptureHUDWindow?
    private var scrollingBorder: RecordingBorderWindow?

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
        guard !rejectIfBusy() else { return }
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
            let image = try captureService.captureFullScreen(
                displayID: Self.displayID(for: NSScreen.main)
            )
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
            // Pin the display before capturing: the overlay, the frozen image
            // and the crop all have to describe the same one.
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let displayBounds = CGDisplayBounds(Self.displayID(for: screen))
            let screenshot = try captureService.captureFullScreenCGImage(
                displayID: Self.displayID(for: screen)
            )
            LibraryWindow.hideAll()
            frozenScreenshot = screenshot
            frozenScreenshotPointSize = displayBounds.size
            let displayImage = NSImage(cgImage: screenshot, size: displayBounds.size)

            let window = RegionSelectionWindow(screen: screen, frozenImage: displayImage) { [weak self] region in
                guard let self else { return }
                self.captureRegionFromFrozen(region)
                self.regionSelectionWindow?.close()
                self.regionSelectionWindow = nil
            } onCancel: { [weak self] in
                self?.frozenScreenshot = nil
                self?.frozenScreenshotPointSize = nil
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
        guard let screenshot = frozenScreenshot,
              let pointSize = frozenScreenshotPointSize else {
            state = .idle
            LibraryWindow.showAll()
            return
        }
        frozenScreenshot = nil
        frozenScreenshotPointSize = nil
        do {
            let image = try captureService.cropRegion(from: screenshot, region: region, screenSize: pointSize)
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
        await showSessionWindowPicker(title: "Select Window") { [weak self] window in
            self?.captureWindow(window)
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
        guard !rejectIfBusy() else { return }
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            beginRecordingWithCountdown(target: .fullScreen)
        }
    }

    func startRegionRecording() {
        guard !rejectIfBusy() else { return }
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
        guard !rejectIfBusy() else { return }
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            await showSessionWindowPicker(title: "Select Window to Record") { [weak self] scWindow in
                self?.beginRecordingWithCountdown(target: .window(scWindow))
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
                if let micWarning = videoService.micWarning {
                    showWarning(title: "No Microphone Audio", message: micWarning)
                }
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

    private func showWarning(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Series Capture

extension CaptureCoordinator {

    /// Live state of a series capture session.
    ///
    /// The window case holds a `CGWindowID` rather than an `SCWindow` so bounds
    /// are re-read on every snap: an `SCWindow` carries the frame from pick
    /// time, and a window resized mid-series would then produce frames whose
    /// point size disagrees with their pixel size.
    struct SeriesSession {
        enum Target {
            case fullScreen(displayID: CGDirectDisplayID)
            /// Flipped, display-relative, exactly as RegionSelectionView emits.
            /// The display is pinned at session start: NSScreen.main follows the
            /// key window, so it can move between snaps.
            case region(CGRect, displayID: CGDirectDisplayID)
            case window(id: CGWindowID, appName: String?, title: String?)
        }

        let target: Target
        let entryID: String
        let folderURL: URL
        let createdAt: Date
        let displayScale: CGFloat
        var frames: [SeriesManifest.Frame] = []
        var nextFrameIndex = 1
        var pendingWrites: [Task<Void, Never>] = []

        var manifestTarget: SeriesManifest.Target {
            switch target {
            case .fullScreen(let displayID):
                .fullScreen(displayID: UInt32(displayID))
            case .region(let rect, _):
                .region(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
            case .window(let id, let appName, let title):
                .window(windowID: UInt32(id), appName: appName, title: title)
            }
        }

        func makeManifest(complete: Bool) -> SeriesManifest {
            SeriesManifest(
                createdAt: createdAt,
                target: manifestTarget,
                displayScale: displayScale,
                frames: frames,
                complete: complete
            )
        }
    }

    // MARK: Start

    func startSeries(mode: CaptureMode) {
        guard !rejectIfBusy() else { return }
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            switch mode {
            case .fullScreen:
                beginSeries(target: .fullScreen(displayID: CGMainDisplayID()))
            case .region:
                beginSessionRegionSelection { [weak self] region, displayID in
                    self?.beginSeries(target: .region(region, displayID: displayID))
                }
            case .window:
                await showSessionWindowPicker(title: "Select Window for Series") { [weak self] scWindow in
                    self?.beginSeries(target: .window(
                        id: CGWindowID(scWindow.windowID),
                        appName: scWindow.owningApplication?.applicationName,
                        title: scWindow.title
                    ))
                }
            }
        }
    }

    /// Region picker shared by series and scrolling capture. `onSelected`
    /// receives the rect relative to the display it was drawn on (flipped,
    /// in points, exactly as RegionSelectionView emits) and that display's ID.
    private func beginSessionRegionSelection(
        onSelected: @escaping (CGRect, CGDirectDisplayID) -> Void
    ) {
        state = .selectingRegion
        do {
            // Pin the display the overlay is drawn on: the region rect is
            // relative to it, and NSScreen.main can move later in the session.
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let regionDisplayID = Self.displayID(for: screen)
            let screenshot = try captureService.captureFullScreenCGImage(displayID: regionDisplayID)
            LibraryWindow.hideAll()
            let displayImage = NSImage(cgImage: screenshot, size: CGDisplayBounds(regionDisplayID).size)

            let window = RegionSelectionWindow(screen: screen, frozenImage: displayImage) { [weak self] region in
                guard let self else { return }
                self.regionSelectionWindow?.close()
                self.regionSelectionWindow = nil
                onSelected(region, regionDisplayID)
            } onCancel: { [weak self] in
                self?.cancel()
            }
            regionSelectionWindow = window
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { window.alphaValue = 1 }
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
        }
    }

    /// Window picker shared by every window-based flow: screenshot, recording,
    /// series, and scrolling capture.
    ///
    /// While the picker is open the coordinator is busy and ignores every
    /// other capture request, so the picker must never end up somewhere the
    /// user cannot see or dismiss it.
    func showSessionWindowPicker(
        title: String,
        onPicked: @escaping (SCWindow) -> Void
    ) async {
        state = .selectingWindow
        LibraryWindow.hideAll()
        do {
            let windows = try await captureService.availableWindows()
            let pickerView = WindowPickerView(windows: windows) { [weak self] scWindow in
                self?.dismissWindowPicker()
                onPicked(scWindow)
            } onCancel: { [weak self] in
                self?.cancelWindowPicker()
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = title
            window.contentView = NSHostingView(rootView: pickerView)
            // A menu bar app is not active when one of its menu items is
            // chosen, and since macOS 14 NSApp.activate() is only a request
            // the system may turn down. At normal level the picker then opened
            // behind the frontmost app, and every capture waited on a window
            // nobody could see. Floating keeps it above other apps' windows.
            window.level = .floating
            window.center()
            windowPickerWindow = window
            // The title bar close button must behave like Cancel. Without this
            // the window closed but the coordinator stayed in .selectingWindow.
            windowPickerCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowPickerClosedByUser() }
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
        }
    }

    /// Closes the picker after a choice was made. The close observer is
    /// removed first so this close is not mistaken for a cancel.
    private func dismissWindowPicker() {
        if let observer = windowPickerCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        windowPickerCloseObserver = nil
        windowPickerWindow?.close()
        windowPickerWindow = nil
    }

    private func cancelWindowPicker() {
        dismissWindowPicker()
        state = .idle
        LibraryWindow.showAll()
    }

    /// The user closed the picker with the title bar button.
    private func windowPickerClosedByUser() {
        guard windowPickerWindow != nil else { return }
        if let observer = windowPickerCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        windowPickerCloseObserver = nil
        windowPickerWindow = nil
        state = .idle
        LibraryWindow.showAll()
    }

    private func beginSeries(target: SeriesSession.Target) {
        LibraryWindow.hideAll()
        let folder: (id: String, folderURL: URL)
        do {
            folder = try LibraryManager.shared.beginSeries()
        } catch {
            state = .idle
            LibraryWindow.showAll()
            showError(error)
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        seriesSession = SeriesSession(
            target: target,
            entryID: folder.id,
            folderURL: folder.folderURL,
            createdAt: Date(),
            displayScale: screen.backingScaleFactor
        )
        state = .seriesActive
        isSeriesActive = true
        seriesFrameCount = 0
        seriesTargetAvailable = true

        showSeriesBorder(for: target)
        presentSeriesHUD()
    }

    private func presentSeriesHUD() {
        let hud = SeriesHUDWindow()
        hud.onSnipe = { [weak self] in self?.snapSeriesFrame() }
        hud.onFinish = { [weak self] in self?.finishSeries() }
        hud.onCancel = { [weak self] in self?.cancelSeries() }
        seriesHUD = hud
        refreshSeriesHUD()
        hud.present()
    }

    private func refreshSeriesHUD() {
        seriesHUD?.update(
            frameCount: seriesFrameCount,
            targetAvailable: seriesTargetAvailable,
            shortcut: ShortcutManager.shared.shortcut(for: .snapSeriesFrame).displayString
        )
    }

    private func showSeriesBorder(for target: SeriesSession.Target) {
        let border = RecordingBorderWindow()
        border.borderColor = .controlAccentColor
        switch target {
        case .fullScreen:
            // Matches recording: a border around the whole screen adds nothing.
            return
        case .region(let region, _):
            border.show(for: .staticRegion(region))
        case .window(let id, _, _):
            border.onAvailabilityChanged = { [weak self] available in
                self?.seriesTargetAvailable = available
                if !available {
                    self?.seriesHUD?.showWarning("Window is not visible.", persistent: true)
                } else {
                    self?.seriesHUD?.clearWarning()
                }
                self?.refreshSeriesHUD()
            }
            border.onTargetLost = { [weak self] in
                guard let self else { return }
                self.seriesTargetAvailable = false
                self.seriesBorder = nil
                self.seriesHUD?.showWarning("Window closed. Press Done to keep the frames.", persistent: true)
                self.refreshSeriesHUD()
            }
            border.show(for: .trackedWindow(id))
        }
        seriesBorder = border
    }

    /// The display a window is on, as a CG display ID.
    static func displayID(for screen: NSScreen?) -> CGDirectDisplayID {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return CGMainDisplayID()
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// The NSScreen backing a CG display ID, so a session keeps capturing the
    /// display it started on.
    static func screen(for target: CGDirectDisplayID) -> NSScreen {
        NSScreen.screens.first { displayID(for: $0) == target }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: Snap

    func snapSeriesFrame() {
        guard case .seriesActive = state, var session = seriesSession, !isSnapping else { return }
        isSnapping = true
        defer { isSnapping = false }

        let image: NSImage
        do {
            image = try captureSeriesTarget(session.target)
        } catch {
            // Never an NSAlert during a session: a modal run loop activates the
            // app, changes the target window's appearance, and can land in the
            // next frame.
            seriesHUD?.showWarning(error.localizedDescription)
            return
        }

        guard let rep = image.representations.first as? NSBitmapImageRep else {
            seriesHUD?.showWarning("Could not read the captured frame.")
            return
        }

        let index = session.nextFrameIndex
        session.nextFrameIndex += 1
        let filePath = SeriesManifest.frameFileName(index: index)
        let annotationsPath = SeriesManifest.annotationsFileName(index: index)
        let fileURL = session.folderURL.appendingPathComponent(filePath)

        // Write the empty annotation sidecar first, so a failure here leaves no
        // orphan PNG behind and loadFrame never meets a missing sidecar.
        do {
            try Data("[]".utf8).write(
                to: session.folderURL.appendingPathComponent(annotationsPath),
                options: .atomic
            )
        } catch {
            seriesHUD?.showWarning("Could not write the frame to the library.")
            return
        }

        // Encoding is hundreds of milliseconds of libpng; keep it off the main
        // actor. Ownership of the rep is handed over and never touched again here.
        let job = PNGEncodeJob(rep: rep, url: fileURL)
        session.pendingWrites.append(Task.detached(priority: .userInitiated) {
            guard let data = job.rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: job.url, options: .atomic)
        })

        session.frames.append(SeriesManifest.Frame(
            index: index,
            file: filePath,
            annotations: annotationsPath,
            capturedAt: Date(),
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh,
            pointWidth: image.size.width,
            pointHeight: image.size.height
        ))

        if session.frames.count == 1 {
            try? LibraryManager.shared.writeSeriesThumbnail(from: image, to: session.folderURL)
        }
        // Rewritten after every frame so a crash still leaves a usable entry.
        try? session.makeManifest(complete: false)
            .write(to: session.folderURL.appendingPathComponent("series.json"))

        seriesSession = session
        seriesFrameCount = session.frames.count
        seriesHUD?.flashCaptureConfirmation()
        refreshSeriesHUD()
    }

    private func captureSeriesTarget(_ target: SeriesSession.Target) throws -> NSImage {
        switch target {
        case .fullScreen(let displayID):
            let bounds = CGDisplayBounds(displayID)
            let cgImage = try captureService.captureExcludingOwnWindows(bounds: bounds)
            return captureService.makeStableImage(from: cgImage, size: bounds.size)
        case .region(let region, let displayID):
            // Reuse the frozen-crop math the screenshot path uses, so region
            // coordinates stay handled in exactly one place.
            let bounds = CGDisplayBounds(displayID)
            let full = try captureService.captureExcludingOwnWindows(bounds: bounds)
            return try captureService.cropRegion(from: full, region: region, screenSize: bounds.size)
        case .window(let id, _, _):
            // .optionIncludingWindow composites that window alone, so our own
            // windows are structurally absent and need no exclusion.
            return try captureService.captureWindow(id: id)
        }
    }

    // MARK: Finish / Cancel

    func finishSeries() {
        guard case .seriesActive = state, let session = seriesSession else { return }
        guard !session.frames.isEmpty else {
            cancelSeries()
            return
        }
        tearDownSeriesUI()
        state = .capturing

        Task {
            // Wait for in-flight PNG encodes so Done cannot outrun the last write.
            for write in session.pendingWrites { await write.value }

            state = .idle
            isSeriesActive = false
            seriesFrameCount = 0
            seriesSession = nil
            do {
                let entry = try LibraryManager.shared.finalizeSeries(
                    id: session.entryID,
                    folderURL: session.folderURL,
                    manifest: session.makeManifest(complete: true)
                )
                LibraryWindow.show(selecting: entry)
            } catch {
                LibraryWindow.showAll()
                showError(error)
            }
        }
    }

    func cancelSeries() {
        guard case .seriesActive = state, let session = seriesSession else { return }
        tearDownSeriesUI()
        state = .idle
        isSeriesActive = false
        seriesFrameCount = 0
        seriesSession = nil

        Task {
            for write in session.pendingWrites { await write.value }
            LibraryManager.shared.discardSeries(id: session.entryID, folderURL: session.folderURL)
            LibraryWindow.showAll()
        }
    }

    private func tearDownSeriesUI() {
        seriesHUD?.dismiss()
        seriesHUD = nil
        seriesBorder?.hide()
        seriesBorder = nil
    }
}

// MARK: - Scrolling Capture

extension CaptureCoordinator {

    /// Live state of a scrolling capture.
    ///
    /// The user scrolls the target by hand while frames are grabbed in a loop
    /// and fed to `ScrollStitchEngine`. Nothing is sent to the target app, so
    /// no Accessibility permission is needed: only Screen Recording, which
    /// every capture already requires.
    struct ScrollingSession {
        enum Target {
            /// Global CG rect in points (Y-down from the primary display's
            /// top-left corner), so it works on any display.
            case region(CGRect)
            case window(CGWindowID)
        }

        let target: Target
        /// The shortcut that started the session. Pressing it again finishes.
        let startAction: ShortcutAction
        let engine = ScrollStitchEngine()
        /// Pixels per point of the captured frames, read from the first frame.
        var pixelsPerPoint: CGFloat = 0
        /// Frames in a row that could not be lined up with the image.
        var unmatchedFrames = 0
        var loop: Task<Void, Never>?
    }

    /// Pause between frames. Each pass also waits for the previous frame to
    /// be stitched, so the real rate adapts to how fast this Mac is.
    private static let scrollingFrameInterval: Duration = .milliseconds(70)

    // MARK: Start

    /// Starts a scrolling capture, or finishes the running one. The start
    /// shortcut doubles as the finish shortcut, so the user can keep one hand
    /// on the trackpad and the other on the keyboard.
    func startScrollingCapture(mode: CaptureMode) {
        if case .scrollingActive = state {
            finishScrollingCapture()
            return
        }
        guard !rejectIfBusy() else { return }
        let startAction: ShortcutAction = mode == .window ? .scrollingWindow : .scrollingRegion
        Task {
            guard await LibraryManager.shared.ensureLibraryLocation() else { return }
            guard await ensureScreenCaptureAccess() else { return }
            switch mode {
            case .region:
                beginSessionRegionSelection { [weak self] region, displayID in
                    let display = CGDisplayBounds(displayID)
                    let global = region.offsetBy(dx: display.origin.x, dy: display.origin.y)
                    self?.beginScrollingCapture(target: .region(global), startAction: startAction)
                }
            case .fullScreen:
                // Not offered in the menus, but handled: the menu bar and Dock
                // are treated like a sticky header and footer.
                let display = CGDisplayBounds(Self.displayID(for: NSScreen.main))
                beginScrollingCapture(target: .region(display), startAction: startAction)
            case .window:
                await showSessionWindowPicker(title: "Select Window to Scroll") { [weak self] scWindow in
                    self?.beginScrollingCapture(
                        target: .window(CGWindowID(scWindow.windowID)),
                        startAction: startAction
                    )
                }
            }
        }
    }

    private func beginScrollingCapture(target: ScrollingSession.Target, startAction: ShortcutAction) {
        LibraryWindow.hideAll()
        scrollingSession = ScrollingSession(target: target, startAction: startAction)
        state = .scrollingActive
        isScrollingActive = true

        showScrollingBorder(for: target)
        presentScrollingHUD()
        scrollingSession?.loop = Task { [weak self] in
            await self?.runScrollingCaptureLoop()
        }
    }

    private func presentScrollingHUD() {
        let hud = ScrollingCaptureHUDWindow()
        hud.onFinish = { [weak self] in self?.finishScrollingCapture() }
        hud.onCancel = { [weak self] in self?.cancelScrollingCapture() }
        scrollingHUD = hud
        refreshScrollingHUD(pixelHeight: 0)
        hud.present()
    }

    private func refreshScrollingHUD(pixelHeight: Int) {
        guard let session = scrollingSession else { return }
        let scale = session.pixelsPerPoint > 0 ? session.pixelsPerPoint : 1
        scrollingHUD?.update(
            pointHeight: Int((CGFloat(pixelHeight) / scale).rounded()),
            shortcut: ShortcutManager.shared.shortcut(for: session.startAction).displayString
        )
    }

    private func showScrollingBorder(for target: ScrollingSession.Target) {
        let border = RecordingBorderWindow()
        border.borderColor = .controlAccentColor
        switch target {
        case .region(let rect):
            border.show(for: .staticRegion(rect))
        case .window(let id):
            border.onAvailabilityChanged = { [weak self] available in
                if available {
                    self?.scrollingHUD?.clearWarning()
                } else {
                    self?.scrollingHUD?.showWarning("Window is not visible.", persistent: true)
                }
            }
            border.onTargetLost = { [weak self] in
                guard let self else { return }
                self.scrollingBorder = nil
                self.scrollingHUD?.showWarning("Window closed. Press Done to keep what was captured.", persistent: true)
            }
            border.show(for: .trackedWindow(id))
        }
        scrollingBorder = border
    }

    // MARK: Capture loop

    private func runScrollingCaptureLoop() async {
        while !Task.isCancelled {
            guard let session = scrollingSession else { return }
            do {
                let (frame, pointWidth) = try captureScrollingFrame(session.target)
                if session.pixelsPerPoint == 0, pointWidth > 0 {
                    scrollingSession?.pixelsPerPoint = CGFloat(frame.width) / pointWidth
                }
                let outcome = await session.engine.add(SendableCGImage(image: frame))
                // Done or Cancel may have been pressed while the frame was
                // being stitched. The frame is in the image either way.
                guard !Task.isCancelled, scrollingSession != nil else { return }
                handleScrollingOutcome(outcome, firstFrameHeight: frame.height)
            } catch {
                scrollingHUD?.showWarning(error.localizedDescription)
            }
            try? await Task.sleep(for: Self.scrollingFrameInterval)
        }
    }

    /// One frame of the target and its width in points.
    private func captureScrollingFrame(_ target: ScrollingSession.Target) throws -> (CGImage, CGFloat) {
        switch target {
        case .region(let rect):
            // Leaves out this app's windows, so the panel and the border can
            // sit over the region without showing up in the image.
            return (try captureService.captureExcludingOwnWindows(bounds: rect), rect.width)
        case .window(let id):
            let (image, bounds) = try captureService.captureWindowCGImage(id: id)
            return (image, bounds.width)
        }
    }

    private func handleScrollingOutcome(_ outcome: ScrollStitcher.Outcome, firstFrameHeight: Int) {
        switch outcome {
        case .started:
            refreshScrollingHUD(pixelHeight: firstFrameHeight)
        case .appended(let height):
            if (scrollingSession?.unmatchedFrames ?? 0) > 0 {
                scrollingSession?.unmatchedFrames = 0
                scrollingHUD?.clearWarning()
            }
            refreshScrollingHUD(pixelHeight: height)
        case .unchanged:
            // The view stopped moving on a frame that does not line up with
            // the image. Tell the user now instead of waiting for more frames.
            if (scrollingSession?.unmatchedFrames ?? 0) > 0 {
                showLostTrackWarning()
            }
        case .noMatch:
            scrollingSession?.unmatchedFrames += 1
            // A single miss is often an animation on the page. Two in a row
            // means the user scrolled up or scrolled too fast.
            if (scrollingSession?.unmatchedFrames ?? 0) >= 2 {
                showLostTrackWarning()
            }
        case .sizeChanged:
            scrollingHUD?.showWarning(
                "The window changed size. Press Done to keep what was captured.",
                persistent: true
            )
        case .limitReached:
            scrollingHUD?.showWarning(
                "The image reached its maximum height. Press Done to save it.",
                persistent: true
            )
        }
    }

    private func showLostTrackWarning() {
        scrollingHUD?.showWarning(
            "Lost track of the page. Scroll back up a little, then scroll down more slowly.",
            persistent: true
        )
    }

    // MARK: Finish / Cancel

    func finishScrollingCapture() {
        guard case .scrollingActive = state, let session = scrollingSession else { return }
        tearDownScrollingUI()
        scrollingSession = nil
        state = .capturing
        session.loop?.cancel()

        Task {
            // Let the frame being stitched right now land in the image.
            await session.loop?.value
            isScrollingActive = false
            // The scale comes from the copy taken above. The loop writes it
            // before handing the first frame to the engine, so a session with
            // any frame in the image always has it. Done pressed before the
            // first frame leaves both empty, and nothing is saved.
            guard session.pixelsPerPoint > 0,
                  let result = await session.engine.makeImage() else {
                state = .idle
                LibraryWindow.showAll()
                return
            }
            let scale = session.pixelsPerPoint
            let image = captureService.makeStableImage(
                from: result.image,
                size: NSSize(
                    width: CGFloat(result.image.width) / scale,
                    height: CGFloat(result.image.height) / scale
                )
            )
            openEditor(with: image)
        }
    }

    func cancelScrollingCapture() {
        guard case .scrollingActive = state, let session = scrollingSession else { return }
        tearDownScrollingUI()
        scrollingSession = nil
        session.loop?.cancel()
        state = .idle
        isScrollingActive = false
        LibraryWindow.showAll()
    }

    private func tearDownScrollingUI() {
        scrollingHUD?.dismiss()
        scrollingHUD = nil
        scrollingBorder?.hide()
        scrollingBorder = nil
    }
}

/// Transfers exclusive ownership of a bitmap rep to a background encode.
private struct PNGEncodeJob: @unchecked Sendable {
    let rep: NSBitmapImageRep
    let url: URL
}

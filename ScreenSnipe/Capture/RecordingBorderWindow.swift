import AppKit

@MainActor
final class RecordingBorderWindow {

    enum TrackingTarget {
        case staticRegion(CGRect)
        case trackedWindow(CGWindowID)
    }

    private var panel: NSPanel?
    private var trackingTimer: Timer?
    fileprivate static let borderWidth: CGFloat = 3

    /// Stroke color of the border. Recording uses red; a series session uses the
    /// accent color so the two modes are not confusable on screen.
    var borderColor: NSColor = .systemRed

    /// Called when a tracked window disappears for good. Without it the caller
    /// keeps a reference to a border that has silently hidden itself.
    var onTargetLost: (() -> Void)?

    /// Called when a tracked window's visibility changes, so a caller can
    /// disable capture before the user tries it.
    var onAvailabilityChanged: ((Bool) -> Void)?

    private var lastReportedAvailability: Bool?

    func show(for target: TrackingTarget) {
        let color = borderColor
        let lost = onTargetLost
        let availability = onAvailabilityChanged
        hide()
        borderColor = color
        onTargetLost = lost
        onAvailabilityChanged = availability

        let frame: NSRect
        switch target {
        case .staticRegion(let cgRect):
            frame = panelFrame(for: cgRect)
        case .trackedWindow(let windowID):
            guard let windowRect = Self.windowBounds(for: windowID) else { return }
            frame = panelFrame(for: windowRect)
        }

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let borderView = RecordingBorderView(frame: NSRect(origin: .zero, size: frame.size))
        borderView.strokeColor = borderColor
        panel.contentView = borderView

        self.panel = panel

        switch target {
        case .staticRegion:
            panel.level = .floating
            panel.orderFrontRegardless()
        case .trackedWindow(let windowID):
            panel.level = .normal
            panel.orderFrontRegardless()
            panel.order(.above, relativeTo: Int(windowID))
            startTracking(windowID: windowID)
        }
    }

    func hide() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        panel?.orderOut(nil)
        panel = nil
        lastReportedAvailability = nil
        onTargetLost = nil
        onAvailabilityChanged = nil
    }

    // MARK: - Window Tracking

    private func startTracking(windowID: CGWindowID) {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTrackedWindow(windowID: windowID)
            }
        }
    }

    private func updateTrackedWindow(windowID: CGWindowID) {
        guard let bounds = Self.windowBounds(for: windowID) else {
            // Window closed for good.
            let lost = onTargetLost
            reportAvailability(false)
            hide()
            lost?()
            return
        }

        // Check if window is on screen
        if !Self.isWindowOnScreen(windowID: windowID) {
            panel?.setIsVisible(false)
            reportAvailability(false)
            return
        }

        panel?.setIsVisible(true)
        reportAvailability(true)
        let frame = panelFrame(for: bounds)
        panel?.setFrame(frame, display: true)
        panel?.order(.above, relativeTo: Int(windowID))
    }

    private func reportAvailability(_ available: Bool) {
        guard lastReportedAvailability != available else { return }
        lastReportedAvailability = available
        onAvailabilityChanged?(available)
    }

    // MARK: - Coordinate Conversion

    /// Converts a CG rect (origin top-left, Y-down) to an NS rect (origin bottom-left, Y-up)
    /// and expands it outward by the border width so the border falls outside the recorded area.
    private func panelFrame(for cgRect: CGRect) -> NSRect {
        guard let primaryScreen = NSScreen.screens.first else {
            return .zero
        }
        let primaryHeight = primaryScreen.frame.height

        let nsY = primaryHeight - cgRect.origin.y - cgRect.height
        let bw = Self.borderWidth

        return NSRect(
            x: cgRect.origin.x - bw,
            y: nsY - bw,
            width: cgRect.width + bw * 2,
            height: cgRect.height + bw * 2
        )
    }

    // MARK: - CGWindowList Helpers

    private static func windowBounds(for windowID: CGWindowID) -> CGRect? {
        WindowInfo.bounds(for: windowID)
    }

    private static func isWindowOnScreen(windowID: CGWindowID) -> Bool {
        WindowInfo.isOnScreen(windowID)
    }
}

// MARK: - Border View

private final class RecordingBorderView: NSView {
    var strokeColor: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bw = RecordingBorderWindow.borderWidth
        let strokeRect = bounds.insetBy(dx: bw / 2, dy: bw / 2)
        let path = NSBezierPath(rect: strokeRect)
        path.lineWidth = bw
        strokeColor.setStroke()
        path.stroke()
    }
}

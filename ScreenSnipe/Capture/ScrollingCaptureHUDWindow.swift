import AppKit

/// Floating controls shown while a scrolling capture is running.
///
/// Built like `SeriesHUDWindow` and for the same reasons: it is non-activating,
/// so pressing Done never pulls focus away from the app being scrolled, and it
/// is non-opaque, so the windows behind it keep their backing store and still
/// composite into the captured frames. The panel itself never shows up in a
/// frame because the capture leaves out every window this app owns.
@MainActor
final class ScrollingCaptureHUDWindow: NSPanel {

    private static let framePositionKey = "scrollingCaptureHUDOrigin"

    private let titleLabel = NSTextField(labelWithString: "Scroll down slowly")
    private let heightLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")

    private var warningDismissTask: Task<Void, Never>?

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 86),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        buildContentView()
        restorePosition()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Layout

    private func buildContentView() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "scroll",
            accessibilityDescription: "Scrolling capture"
        ) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        heightLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        heightLabel.textColor = .secondaryLabelColor

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 2
        warningLabel.preferredMaxLayoutWidth = 300
        warningLabel.isHidden = true

        let doneButton = NSButton()
        doneButton.title = "Done"
        doneButton.bezelStyle = .push
        doneButton.controlSize = .large
        doneButton.keyEquivalent = ""
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        let cancelButton = NSButton()
        cancelButton.title = "✕"
        cancelButton.bezelStyle = .push
        cancelButton.toolTip = "Cancel scrolling capture"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let labels = NSStackView(views: [titleLabel, heightLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [icon, labels, doneButton, cancelButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10

        let root = NSStackView(views: [topRow, warningLabel])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    // MARK: - Position

    private func restorePosition() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.framePositionKey) {
            let point = NSPointFromString(stored)
            if NSScreen.screens.contains(where: { $0.frame.contains(point) }) {
                setFrameOrigin(point)
                return
            }
        }
        guard let screen = NSScreen.main else { return }
        setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.minY + 80
        ))
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.framePositionKey)
    }

    // MARK: - State

    /// Shows the current image height in points, the unit the editor and
    /// the export size fields use.
    func update(pointHeight: Int, shortcut: String) {
        let height = pointHeight.formatted(.number)
        let hint = shortcut.isEmpty ? "" : " · \(shortcut) to finish"
        heightLabel.stringValue = "\(height) pt tall\(hint)"
    }

    /// Shows a problem inline. Like the series panel, a session never uses
    /// NSAlert: a modal run loop activates the app and changes the look of
    /// the window being captured.
    func showWarning(_ message: String, persistent: Bool = false) {
        warningDismissTask?.cancel()
        warningLabel.stringValue = message
        warningLabel.isHidden = false
        guard !persistent else { return }
        warningDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.clearWarning()
        }
    }

    func clearWarning() {
        warningDismissTask?.cancel()
        warningDismissTask = nil
        warningLabel.stringValue = ""
        warningLabel.isHidden = true
    }

    func present() {
        orderFrontRegardless()
    }

    func dismiss() {
        warningDismissTask?.cancel()
        warningDismissTask = nil
        savePosition()
        orderOut(nil)
    }

    // MARK: - Actions

    @objc private func doneTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }

    override func keyDown(with event: NSEvent) {
        // Only reachable when the panel itself has been clicked into.
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

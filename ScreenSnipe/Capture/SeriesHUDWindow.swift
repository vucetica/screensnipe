import AppKit

/// Floating controls shown while a series capture session is running.
///
/// The panel is non-activating so clicking Snipe never brings Screen Snipe
/// forward: activating would change the target app's active/inactive appearance
/// in the middle of a series. It is also non-opaque, because an opaque panel can
/// mark the windows behind it fully occluded, letting the system discard their
/// backing store; those windows would then composite as blank once the panel is
/// excluded from the grab.
@MainActor
final class SeriesHUDWindow: NSPanel {

    private static let framePositionKey = "seriesHUDOrigin"

    private let snipeButton = NSButton()
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton()

    private var warningDismissTask: Task<Void, Never>?

    var onSnipe: (() -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 86),
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

        snipeButton.title = "Snipe"
        snipeButton.bezelStyle = .push
        snipeButton.controlSize = .large
        snipeButton.keyEquivalent = ""
        snipeButton.target = self
        snipeButton.action = #selector(snipeTapped)
        snipeButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = .secondaryLabelColor

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byTruncatingTail
        warningLabel.isHidden = true

        doneButton.title = "Done"
        doneButton.bezelStyle = .push
        doneButton.target = self
        doneButton.action = #selector(doneTapped)

        let cancelButton = NSButton()
        cancelButton.title = "✕"
        cancelButton.bezelStyle = .push
        cancelButton.toolTip = "Cancel series and discard captured frames"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let labels = NSStackView(views: [countLabel, shortcutLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let topRow = NSStackView(views: [snipeButton, labels, doneButton, cancelButton])
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

    func update(frameCount: Int, targetAvailable: Bool, shortcut: String) {
        countLabel.stringValue = frameCount == 1 ? "1 frame captured" : "\(frameCount) frames captured"
        shortcutLabel.stringValue = shortcut.isEmpty ? "No snap shortcut set" : "\(shortcut) to snap"
        snipeButton.isEnabled = targetAvailable
        // Done stays enabled even when the target is gone: the frames already
        // captured are the user's data and must remain saveable.
        doneButton.isEnabled = true
    }

    /// Brief visual acknowledgement that a frame was captured.
    func flashCaptureConfirmation() {
        guard let contentView else { return }
        let flash = NSView(frame: contentView.bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        flash.layer?.cornerRadius = 12
        flash.autoresizingMask = [.width, .height]
        contentView.addSubview(flash)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            flash.animator().alphaValue = 0
        } completionHandler: {
            flash.removeFromSuperview()
        }
    }

    /// Shows a transient problem inline.
    ///
    /// Errors during a session must never use NSAlert: a modal run loop
    /// activates the app, changes the target window's appearance, and can itself
    /// land in the next captured frame.
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

    @objc private func snipeTapped() { onSnipe?() }
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

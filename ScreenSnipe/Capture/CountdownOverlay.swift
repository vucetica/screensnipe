import AppKit
import QuartzCore

@MainActor
final class CountdownOverlay {
    private var window: NSPanel?

    /// Shows a 3-2-1 countdown on screen, then calls completion.
    func show(completion: @escaping @MainActor () -> Void) {
        guard let screen = NSScreen.main else {
            completion()
            return
        }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let countdownView = CountdownView(frame: screen.frame)
        panel.contentView = countdownView
        panel.orderFrontRegardless()

        self.window = panel

        countdownView.startCountdown { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            completion()
        }
    }
}

// MARK: - Countdown View

@MainActor
private final class CountdownView: NSView {
    private var label: NSTextField!
    private var completion: (@MainActor () -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 200, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false
        label.wantsLayer = true
        label.layer?.shadowColor = NSColor.black.cgColor
        label.layer?.shadowOffset = .zero
        label.layer?.shadowRadius = 40
        label.layer?.shadowOpacity = 0.7

        // Fixed size centered in the view — never changes
        let labelSize = CGSize(width: 300, height: 280)
        label.frame = CGRect(
            x: (frame.width - labelSize.width) / 2,
            y: (frame.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func startCountdown(completion: @escaping @MainActor () -> Void) {
        self.completion = completion
        showNumber(3)
    }

    private func showNumber(_ number: Int) {
        // Remove previous animations
        label.layer?.removeAllAnimations()

        label.stringValue = "\(number)"

        // Reset: fully visible, normal scale
        label.alphaValue = 1.0
        label.layer?.opacity = 1.0
        label.layer?.transform = CATransform3DIdentity

        // Scale up animation via Core Animation
        if let layer = label.layer {
            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 1.0
            scaleAnim.toValue = 1.5
            scaleAnim.duration = 0.8
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            scaleAnim.fillMode = .forwards
            scaleAnim.isRemovedOnCompletion = false
            layer.add(scaleAnim, forKey: "scale")

            let fadeAnim = CABasicAnimation(keyPath: "opacity")
            fadeAnim.fromValue = 1.0
            fadeAnim.toValue = 0.0
            fadeAnim.duration = 0.8
            fadeAnim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fadeAnim.fillMode = .forwards
            fadeAnim.isRemovedOnCompletion = false
            layer.add(fadeAnim, forKey: "fade")
        }

        // Advance to next number after 1 second
        let next = number - 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if next > 0 {
                self.showNumber(next)
            } else {
                self.completion?()
            }
        }
    }
}

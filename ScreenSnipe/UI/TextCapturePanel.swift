import AppKit

@MainActor
final class TextCapturePanel {
    private static var panel: NSPanel?
    private static var textView: NSTextView?
    private static var spinner: NSProgressIndicator?
    private static var formatButton: NSButton?
    private static var containerView: NSView?

    static func showLoading(relativeTo parentWindow: NSWindow?) {
        ensurePanel(relativeTo: parentWindow)
        guard let textView, let spinner, let formatButton else { return }

        textView.string = ""
        textView.isEditable = false
        textView.isSelectable = false
        formatButton.isHidden = true
        spinner.startAnimation(nil)
        spinner.isHidden = false
    }

    static func show(text: String, relativeTo parentWindow: NSWindow?) {
        ensurePanel(relativeTo: parentWindow)
        guard let textView, let spinner, let formatButton else { return }

        spinner.stopAnimation(nil)
        spinner.isHidden = true
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.selectAll(nil)
        formatButton.isHidden = false
        formatButton.isEnabled = true
        applyButtonTitle(to: formatButton, title: "AI Cleanup", symbolName: "sparkles")
    }

    private static func ensurePanel(relativeTo parentWindow: NSWindow?) {
        if let existing = panel {
            existing.orderFrontRegardless()
            existing.makeKey()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Captured Text"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 200)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = PanelDelegate.shared

        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]

        // Bottom bar with Auto Format button
        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: container.bounds.width, height: 36))
        bottomBar.autoresizingMask = [.width, .maxYMargin]

        let button = NSButton(frame: .zero)
        button.target = FormatButtonTarget.shared
        button.action = #selector(FormatButtonTarget.formatAction)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        button.contentTintColor = .controlAccentColor
        Self.applyButtonTitle(to: button, title: "AI Cleanup", symbolName: "sparkles")
        button.frame = NSRect(x: 8, y: 4, width: button.fittingSize.width + 16, height: 28)
        button.autoresizingMask = [.maxXMargin]
        button.toolTip = "Use Apple Intelligence to interpret and clean up the text"
        button.isHidden = true
        bottomBar.addSubview(button)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(
            x: (container.bounds.width - 32) / 2,
            y: (container.bounds.height - 32) / 2,
            width: 32,
            height: 32
        )
        spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        spinner.isHidden = true

        // Scroll view fills above the bottom bar
        let scrollFrame = NSRect(x: 0, y: 36, width: container.bounds.width, height: container.bounds.height - 36)
        let scrollView = NSScrollView(frame: scrollFrame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        container.addSubview(scrollView)
        container.addSubview(bottomBar)
        container.addSubview(spinner)
        panel.contentView = container

        // Position relative to parent window
        if let parentFrame = parentWindow?.frame {
            let x = parentFrame.maxX + 12
            let y = parentFrame.midY - 180
            panel.setFrameOrigin(NSPoint(x: x, y: y))

            if let screen = parentWindow?.screen ?? NSScreen.main {
                if panel.frame.maxX > screen.visibleFrame.maxX {
                    panel.setFrameOrigin(NSPoint(x: parentFrame.minX - panel.frame.width - 12, y: y))
                }
            }
        } else {
            panel.center()
        }

        self.panel = panel
        self.textView = textView
        self.spinner = spinner
        self.formatButton = button
        self.containerView = container

        panel.orderFrontRegardless()
        panel.makeKey()
    }

    fileprivate static func runAutoFormat() {
        guard let textView, let formatButton else { return }
        let currentText = textView.string
        guard !currentText.isEmpty else { return }

        formatButton.isEnabled = false
        applyButtonTitle(to: formatButton, title: "Processing...", symbolName: "sparkles")

        Task {
            let formatted = await TextRecognitionService.formatText(currentText)
            textView.string = formatted
            textView.selectAll(nil)
            applyButtonTitle(to: formatButton, title: "AI Cleanup", symbolName: "sparkles")
            formatButton.isEnabled = true
        }
    }

    private static func applyButtonTitle(to button: NSButton, title: String, symbolName: String) {
        let attachment = NSTextAttachment()
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        attachment.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        let attrString = NSMutableAttributedString(attachment: attachment)
        attrString.append(NSAttributedString(string: " \(title)"))
        attrString.addAttributes([
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor,
        ], range: NSRange(location: 0, length: attrString.length))
        button.attributedTitle = attrString
    }

    fileprivate static func panelDidClose() {
        panel = nil
        textView = nil
        spinner = nil
        formatButton = nil
        containerView = nil
    }
}

// MARK: - Format Button Target

private final class FormatButtonTarget: NSObject {
    nonisolated(unsafe) static let shared = FormatButtonTarget()

    @objc func formatAction() {
        Task { @MainActor in
            TextCapturePanel.runAutoFormat()
        }
    }
}

// MARK: - Panel Delegate

private final class PanelDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static let shared = PanelDelegate()

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            TextCapturePanel.panelDidClose()
        }
    }
}

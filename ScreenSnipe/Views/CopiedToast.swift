import AppKit

@MainActor
enum CopiedToast {
    private static var activePanel: NSPanel?

    /// Show a brief "Copied!" overlay centered near the top of the given window.
    static func show(in window: NSWindow?) {
        guard let window else { return }

        // Remove any existing toast
        activePanel?.orderOut(nil)
        activePanel = nil

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        icon.contentTintColor = .white
        icon.frame = NSRect(x: 12, y: 0, width: 16, height: 16)

        let label = NSTextField(labelWithString: "Copied!")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.sizeToFit()

        let panelSize = NSSize(width: icon.frame.width + label.frame.width + 32, height: 32)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let background = NSView(frame: NSRect(origin: .zero, size: panelSize))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.9).cgColor
        background.layer?.cornerRadius = 8

        icon.frame.origin.y = (panelSize.height - icon.frame.height) / 2
        label.frame.origin = NSPoint(x: icon.frame.maxX + 4, y: (panelSize.height - label.frame.height) / 2)
        background.addSubview(icon)
        background.addSubview(label)
        panel.contentView = background

        // Position centered near the top of the parent window
        let windowFrame = window.frame
        let x = windowFrame.midX - panelSize.width / 2
        let y = windowFrame.maxY - panelSize.height - 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        activePanel = panel

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    panel.animator().alphaValue = 0
                }) {
                    Task { @MainActor in
                        panel.parent?.removeChildWindow(panel)
                        panel.orderOut(nil)
                        if activePanel === panel {
                            activePanel = nil
                        }
                    }
                }
            }
        }
    }
}

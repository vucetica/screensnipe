import AppKit

@MainActor
final class RegionSelectionView: NSView {
    private let onRegionSelected: (CGRect) -> Void
    private let onCancel: () -> Void
    private let frozenImage: NSImage?

    private var dragStart: CGPoint?
    private var currentRect: CGRect?
    private var mouseLocation: CGPoint?

    override var isFlipped: Bool { true }

    init(frame: NSRect, frozenImage: NSImage? = nil, onRegionSelected: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.frozenImage = frozenImage
        self.onRegionSelected = onRegionSelected
        self.onCancel = onCancel
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let frozenImage {
            // Draw the frozen screenshot as background.
            // The view is flipped (isFlipped=true), so temporarily flip the
            // graphics context so NSImage draws right-side up.
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            frozenImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            ctx.restoreGState()

            // Dark overlay with selection cutout
            NSColor.black.withAlphaComponent(0.3).setFill()
            if let rect = currentRect {
                let overlay = NSBezierPath(rect: bounds)
                overlay.appendRect(rect)
                overlay.windingRule = .evenOdd
                overlay.fill()
            } else {
                bounds.fill()
            }
        } else {
            // Transparent mode (used for recording region selection)
            NSColor.black.withAlphaComponent(0.3).setFill()
            bounds.fill()

            if let rect = currentRect {
                NSColor.clear.setFill()
                rect.fill(using: .copy)
            }
        }

        if let rect = currentRect {
            // Draw selection border
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.stroke()

            // Draw dimensions label
            drawDimensions(for: rect)
        }

        // Draw crosshair if no selection yet
        if currentRect == nil, let mouse = mouseLocation {
            drawCrosshair(at: mouse)
        }
    }

    private func drawCrosshair(at point: CGPoint) {
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5

        // Horizontal line
        path.move(to: CGPoint(x: bounds.minX, y: point.y))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y))

        // Vertical line
        path.move(to: CGPoint(x: point.x, y: bounds.minY))
        path.line(to: CGPoint(x: point.x, y: bounds.maxY))

        path.stroke()
    }

    private func drawDimensions(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let labelOrigin = CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.maxY + 6
        )
        (text as NSString).draw(at: labelOrigin, withAttributes: attrs)
    }

    // MARK: - Mouse Events

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        currentRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect, rect.width > 5, rect.height > 5 else {
            dragStart = nil
            currentRect = nil
            needsDisplay = true
            return
        }

        // ScreenCaptureKit's sourceRect uses display-relative coordinates
        // with top-left origin (y increases downward), which matches our
        // flipped view coordinates directly. No conversion needed.
        onRegionSelected(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel()
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

import AppKit

@MainActor
final class CropTool: ToolHandler {
    private let store: AnnotationStore

    /// Live preview rect shown during drag (before committing to store).
    private(set) var previewRect: CGRect?

    private enum Mode {
        case drawing(start: CGPoint)
        case moving(origin: CGPoint, originalRect: CGRect)
        case resizing(handle: HandleKind, origin: CGPoint, originalRect: CGRect)
    }

    private var mode: Mode?

    private static let handleThreshold: CGFloat = 8

    init(store: AnnotationStore) {
        self.store = store
    }

    // MARK: - ToolHandler

    func mouseDown(at point: CGPoint, in canvas: CanvasView) {
        if let existing = store.cropRect {
            // Check handle hit first
            if let handle = hitHandle(at: point, in: existing, canvas: canvas) {
                mode = .resizing(handle: handle, origin: point, originalRect: existing)
                previewRect = existing
                return
            }
            // Allow body-drag (moving) only when crop is smaller than the full image.
            // When crop covers the full image, clicking inside starts a new crop instead.
            let imageBounds = CGRect(origin: .zero, size: canvas.image.size)
            if existing.contains(point) && !existing.contains(imageBounds) {
                mode = .moving(origin: point, originalRect: existing)
                previewRect = existing
                return
            }
        }

        // No existing crop hit, or crop covers full image — start drawing a new one
        mode = .drawing(start: point)
        previewRect = nil
    }

    func mouseDragged(to point: CGPoint, in canvas: CanvasView) {
        guard let mode else { return }

        switch mode {
        case .drawing(let start):
            previewRect = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )

        case .moving(let origin, let originalRect):
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            previewRect = originalRect.offsetBy(dx: dx, dy: dy)

        case .resizing(let handle, let origin, let originalRect):
            previewRect = resizedRect(originalRect, handle: handle, from: origin, to: point)
        }

        canvas.cropPreviewRect = previewRect
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, in canvas: CanvasView) {
        defer {
            mode = nil
            previewRect = nil
            canvas.cropPreviewRect = nil
            canvas.needsDisplay = true
        }

        guard let rect = previewRect else { return }

        // Normalize (ensure positive width/height) and clamp to image bounds
        let normalized = rect.standardized
        guard normalized.width > 5, normalized.height > 5 else { return }

        let imageBounds = CGRect(origin: .zero, size: canvas.image.size)
        let clamped = normalized.intersection(imageBounds)
        guard clamped.width > 1, clamped.height > 1 else { return }

        store.setCrop(clamped)
    }

    func keyDown(with event: NSEvent, in canvas: CanvasView) -> Bool {
        // ESC clears the crop
        if event.keyCode == 53 {
            if mode != nil {
                // Cancel in-progress drag
                mode = nil
                previewRect = nil
                canvas.cropPreviewRect = nil
                canvas.needsDisplay = true
            } else {
                store.clearCrop()
                canvas.needsDisplay = true
            }
            return true
        }
        return false
    }

    func cursor() -> NSCursor {
        .crosshair
    }

    // MARK: - Cursor for position (called by CanvasView for hover)

    func cursorForPosition(_ point: CGPoint, in canvas: CanvasView) -> NSCursor {
        guard let existing = store.cropRect else { return .crosshair }

        if let handle = hitHandle(at: point, in: existing, canvas: canvas) {
            return Self.resizeCursor(for: handle)
        }
        if existing.contains(point) {
            return .openHand
        }
        return .crosshair
    }

    // MARK: - Handle Hit Testing

    private func hitHandle(at point: CGPoint, in rect: CGRect, canvas: CanvasView) -> HandleKind? {
        let zoom = canvas.enclosingScrollView?.magnification ?? 1.0
        let threshold = Self.handleThreshold / zoom
        let handles: [(CGPoint, HandleKind)] = [
            (CGPoint(x: rect.minX, y: rect.minY), .topLeft),
            (CGPoint(x: rect.midX, y: rect.minY), .top),
            (CGPoint(x: rect.maxX, y: rect.minY), .topRight),
            (CGPoint(x: rect.maxX, y: rect.midY), .right),
            (CGPoint(x: rect.maxX, y: rect.maxY), .bottomRight),
            (CGPoint(x: rect.midX, y: rect.maxY), .bottom),
            (CGPoint(x: rect.minX, y: rect.maxY), .bottomLeft),
            (CGPoint(x: rect.minX, y: rect.midY), .left),
        ]
        for (corner, kind) in handles {
            if hypot(point.x - corner.x, point.y - corner.y) <= threshold {
                return kind
            }
        }
        return nil
    }

    // MARK: - Resize Logic

    private func resizedRect(_ rect: CGRect, handle: HandleKind, from origin: CGPoint, to point: CGPoint) -> CGRect {
        let dx = point.x - origin.x
        let dy = point.y - origin.y

        switch handle {
        case .topLeft:
            return CGRect(x: rect.minX + dx, y: rect.minY + dy, width: rect.width - dx, height: rect.height - dy)
        case .top:
            return CGRect(x: rect.minX, y: rect.minY + dy, width: rect.width, height: rect.height - dy)
        case .topRight:
            return CGRect(x: rect.minX, y: rect.minY + dy, width: rect.width + dx, height: rect.height - dy)
        case .right:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width + dx, height: rect.height)
        case .bottomRight:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width + dx, height: rect.height + dy)
        case .bottom:
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + dy)
        case .bottomLeft:
            return CGRect(x: rect.minX + dx, y: rect.minY, width: rect.width - dx, height: rect.height + dy)
        case .left:
            return CGRect(x: rect.minX + dx, y: rect.minY, width: rect.width - dx, height: rect.height)
        }
    }

    // MARK: - Cursor Helpers

    private static func resizeCursor(for handle: HandleKind) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        switch handle {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .resizeUpDown
        }
    }
}

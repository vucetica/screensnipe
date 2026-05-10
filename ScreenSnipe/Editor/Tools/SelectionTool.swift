import AppKit

enum EndpointKind {
    case start, end
}

enum HandleKind {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

@MainActor
final class SelectionTool: ToolHandler {
    private let store: AnnotationStore
    private var dragOrigin: CGPoint?
    private var originalAnnotation: AnyAnnotation?
    private var isDragging = false
    private var endpointDrag: EndpointKind?
    private var handleDrag: HandleKind?

    init(store: AnnotationStore) {
        self.store = store
    }

    func mouseDown(at point: CGPoint, in canvas: CanvasView) {
        endpointDrag = nil
        handleDrag = nil

        // Check if clicking near an endpoint or handle of the currently selected annotation
        if let selectedID = store.selectedID,
           let selected = store.annotations.first(where: { $0.id == selectedID }) {
            if let ep = Self.endpointHit(for: selected, at: point) {
                endpointDrag = ep
                dragOrigin = point
                originalAnnotation = selected
                isDragging = false
                return
            }
            if let handle = Self.handleHit(for: selected, at: point, in: canvas) {
                handleDrag = handle
                dragOrigin = point
                originalAnnotation = selected
                isDragging = false
                return
            }
        }

        let hit = store.select(at: point)
        dragOrigin = point
        originalAnnotation = hit
        isDragging = false
        canvas.needsDisplay = true
    }

    func mouseDragged(to point: CGPoint, in canvas: CanvasView) {
        guard let origin = dragOrigin, let annotation = originalAnnotation else { return }

        isDragging = true

        if let ep = endpointDrag {
            let updated = Self.moveEndpoint(ep, of: annotation, from: origin, to: point)
            store.updateWithoutUndo(updated)
            Self.endpointResizeCursor(for: annotation, endpoint: ep).set()
            canvas.needsDisplay = true
            return
        }

        if let handle = handleDrag {
            let updated = Self.resizeWithHandle(handle, of: annotation, from: origin, to: point)
            store.updateWithoutUndo(updated)
            canvas.needsDisplay = true
            return
        }

        let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        let moved = annotation.moved(by: delta)
        store.updateWithoutUndo(moved)
        NSCursor.closedHand.set()
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, in canvas: CanvasView) {
        if isDragging, let origin = dragOrigin, let original = originalAnnotation {
            // Restore original and do a proper undo-tracked update
            store.updateWithoutUndo(original)

            if let ep = endpointDrag {
                let updated = Self.moveEndpoint(ep, of: original, from: origin, to: point)
                store.update(updated)
            } else if let handle = handleDrag {
                let updated = Self.resizeWithHandle(handle, of: original, from: origin, to: point)
                store.update(updated)
            } else {
                let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
                store.update(original.moved(by: delta))
            }
        }
        dragOrigin = nil
        originalAnnotation = nil
        isDragging = false
        endpointDrag = nil
        handleDrag = nil
        canvas.updateCursorForPosition(point)
        canvas.needsDisplay = true
    }

    // MARK: - Endpoint Helpers

    private static let endpointThreshold: CGFloat = 12

    static func endpointHit(for annotation: AnyAnnotation, at point: CGPoint) -> EndpointKind? {
        if let arrow = annotation.unwrap(as: ArrowAnnotation.self) {
            if hypot(point.x - arrow.start.x, point.y - arrow.start.y) <= endpointThreshold { return .start }
            if hypot(point.x - arrow.end.x, point.y - arrow.end.y) <= endpointThreshold { return .end }
        } else if let line = annotation.unwrap(as: LineAnnotation.self) {
            if hypot(point.x - line.start.x, point.y - line.start.y) <= endpointThreshold { return .start }
            if hypot(point.x - line.end.x, point.y - line.end.y) <= endpointThreshold { return .end }
        } else if let highlighter = annotation.unwrap(as: HighlighterAnnotation.self), highlighter.points.count >= 2 {
            let first = highlighter.points[0]
            let last = highlighter.points[highlighter.points.count - 1]
            if hypot(point.x - first.x, point.y - first.y) <= endpointThreshold { return .start }
            if hypot(point.x - last.x, point.y - last.y) <= endpointThreshold { return .end }
        }
        return nil
    }

    static func moveEndpoint(_ ep: EndpointKind, of annotation: AnyAnnotation, from origin: CGPoint, to point: CGPoint) -> AnyAnnotation {
        let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
        if var arrow = annotation.unwrap(as: ArrowAnnotation.self) {
            switch ep {
            case .start: arrow.start = CGPoint(x: arrow.start.x + delta.width, y: arrow.start.y + delta.height)
            case .end: arrow.end = CGPoint(x: arrow.end.x + delta.width, y: arrow.end.y + delta.height)
            }
            return AnyAnnotation(arrow)
        } else if var line = annotation.unwrap(as: LineAnnotation.self) {
            switch ep {
            case .start: line.start = CGPoint(x: line.start.x + delta.width, y: line.start.y + delta.height)
            case .end: line.end = CGPoint(x: line.end.x + delta.width, y: line.end.y + delta.height)
            }
            return AnyAnnotation(line)
        } else if var highlighter = annotation.unwrap(as: HighlighterAnnotation.self), highlighter.points.count >= 2 {
            let index = ep == .start ? 0 : highlighter.points.count - 1
            highlighter.points[index] = CGPoint(
                x: highlighter.points[index].x + delta.width,
                y: highlighter.points[index].y + delta.height
            )
            return AnyAnnotation(highlighter)
        }
        return annotation
    }

    // MARK: - Handle Helpers (Shape resize)

    private static let handleThreshold: CGFloat = 12

    static func handleHit(for annotation: AnyAnnotation, at point: CGPoint, in canvas: CanvasView) -> HandleKind? {
        guard annotation.unwrap(as: ShapeAnnotation.self) != nil
              || annotation.unwrap(as: BlurAnnotation.self) != nil else { return nil }
        let zoom = canvas.enclosingScrollView?.magnification ?? 1.0
        let threshold = handleThreshold / zoom
        let rect = annotation.boundingRect
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

    static func resizeWithHandle(_ handle: HandleKind, of annotation: AnyAnnotation, from origin: CGPoint, to point: CGPoint) -> AnyAnnotation {
        let dx = point.x - origin.x
        let dy = point.y - origin.y

        func applyHandle(to rect: CGRect) -> CGRect {
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

        if var shape = annotation.unwrap(as: ShapeAnnotation.self) {
            shape.rect = applyHandle(to: shape.rect)
            return AnyAnnotation(shape)
        } else if var blur = annotation.unwrap(as: BlurAnnotation.self) {
            blur.rect = applyHandle(to: blur.rect)
            return AnyAnnotation(blur)
        }
        return annotation
    }

    // MARK: - Cursor

    static func cursorForPosition(_ point: CGPoint, selected: AnyAnnotation, in canvas: CanvasView) -> NSCursor? {
        // Check endpoint hit (arrow/line) with directional cursor
        if let ep = endpointHit(for: selected, at: point) {
            return endpointResizeCursor(for: selected, endpoint: ep)
        }

        // Check handle hit (shape)
        if let handle = handleHit(for: selected, at: point, in: canvas) {
            return resizeCursor(for: handle)
        }

        // Check body hit — applies to all annotation types
        if selected.hitTest(point: point) {
            return .openHand
        }

        return nil
    }

    static func endpointResizeCursor(for annotation: AnyAnnotation, endpoint: EndpointKind) -> NSCursor {
        var start = CGPoint.zero, end = CGPoint.zero
        if let arrow = annotation.unwrap(as: ArrowAnnotation.self) {
            start = arrow.start; end = arrow.end
        } else if let line = annotation.unwrap(as: LineAnnotation.self) {
            start = line.start; end = line.end
        } else if let highlighter = annotation.unwrap(as: HighlighterAnnotation.self), highlighter.points.count >= 2 {
            start = highlighter.points[0]; end = highlighter.points[highlighter.points.count - 1]
        } else {
            return .crosshair
        }

        // Direction from fixed endpoint toward the hovered endpoint (flipped coords: y-down)
        let (from, to) = endpoint == .start ? (end, start) : (start, end)
        let angle = atan2(to.y - from.y, to.x - from.x)

        if #available(macOS 15, *) {
            // Map angle to the closest of 8 frame resize positions
            let normalized = (angle + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let sector = Int((normalized + .pi / 8) / (.pi / 4)) % 8
            let position: NSCursor.FrameResizePosition = switch sector {
            case 0: .right
            case 1: .bottomRight
            case 2: .bottom
            case 3: .bottomLeft
            case 4: .left
            case 5: .topLeft
            case 6: .top
            case 7: .topRight
            default: .right
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }

        let absAngle = abs(angle)
        if absAngle < .pi / 4 || absAngle > 3 * .pi / 4 {
            return .resizeLeftRight
        }
        return .resizeUpDown
    }

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

    func keyDown(with event: NSEvent, in canvas: CanvasView) -> Bool {
        // Delete key
        if event.keyCode == 51 || event.keyCode == 117 {
            store.removeSelected()
            canvas.needsDisplay = true
            return true
        }

        // Arrow keys for nudging
        guard let selectedID = store.selectedID,
              let selected = store.annotations.first(where: { $0.id == selectedID }) else {
            return false
        }

        let nudge: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var delta = CGSize.zero

        switch event.keyCode {
        case 123: delta.width = -nudge // Left
        case 124: delta.width = nudge  // Right
        case 125: delta.height = nudge // Down
        case 126: delta.height = -nudge // Up
        default: return false
        }

        store.update(selected.moved(by: delta))
        canvas.needsDisplay = true
        return true
    }

    func cursor() -> NSCursor {
        .arrow
    }
}

import AppKit

@MainActor
final class ShapeTool: ToolHandler {
    private let store: AnnotationStore
    private var startPoint: CGPoint?
    private var currentAnnotation: ShapeAnnotation?

    var kind: ShapeKind = .rectangle
    var strokeColor: CGColor = NSColor.systemRed.cgColor
    var fillColor: CGColor? = nil
    var lineWidth: CGFloat = 3

    init(store: AnnotationStore) {
        self.store = store
    }

    func mouseDown(at point: CGPoint, in canvas: CanvasView) {
        startPoint = point
        store.deselect()
    }

    func mouseDragged(to point: CGPoint, in canvas: CanvasView) {
        guard let start = startPoint else { return }
        let rect = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )

        if let existing = currentAnnotation {
            var updated = existing
            updated.rect = rect
            store.updateWithoutUndo(AnyAnnotation(updated))
            currentAnnotation = updated
        } else {
            let shape = ShapeAnnotation(rect: rect, kind: kind, strokeColor: strokeColor, fillColor: fillColor, lineWidth: lineWidth)
            currentAnnotation = shape
            store.add(AnyAnnotation(shape))
        }
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, in canvas: CanvasView) {
        if let annotation = currentAnnotation {
            guard let start = startPoint else { return }
            let rect = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            )
            var final = annotation
            final.rect = rect
            store.updateWithoutUndo(AnyAnnotation(final))
        }
        startPoint = nil
        currentAnnotation = nil
        canvas.needsDisplay = true
    }

    func keyDown(with event: NSEvent, in canvas: CanvasView) -> Bool {
        if event.keyCode == 53 {
            if currentAnnotation != nil {
                store.revertLast()
                currentAnnotation = nil
                startPoint = nil
                canvas.needsDisplay = true
                return true
            }
        }
        return false
    }

    func cursor() -> NSCursor {
        .crosshair
    }

    func applyPreset(_ preset: ToolPreset) {
        if case .string(let k) = preset.properties["kind"], let parsed = ShapeKind(rawValue: k) { kind = parsed }
        if case .color(let c) = preset.properties["strokeColor"] { strokeColor = c.cgColor }
        if case .number(let v) = preset.properties["lineWidth"] { lineWidth = v }
    }

    static func extractPreset(from shape: ShapeAnnotation, name: String) -> ToolPreset {
        ToolPreset(name: name, toolType: EditorTool.shape.rawValue, properties: [
            "kind": .string(shape.kind.rawValue),
            "strokeColor": .color(CodableColor(shape.strokeColor)),
            "lineWidth": .number(shape.lineWidth),
        ])
    }
}

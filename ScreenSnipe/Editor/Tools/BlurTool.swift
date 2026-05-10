import AppKit

@MainActor
final class BlurTool: ToolHandler {
    private let store: AnnotationStore
    private var startPoint: CGPoint?
    private var currentAnnotation: BlurAnnotation?

    var style: BlurStyle = .gaussian
    var intensity: CGFloat = 10

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
            let blur = BlurAnnotation(rect: rect, style: style, intensity: intensity)
            currentAnnotation = blur
            store.add(AnyAnnotation(blur))
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
        if case .string(let s) = preset.properties["style"], let parsed = BlurStyle(rawValue: s) { style = parsed }
        if case .number(let v) = preset.properties["intensity"] { intensity = v }
    }

    static func extractPreset(from blur: BlurAnnotation, name: String) -> ToolPreset {
        ToolPreset(name: name, toolType: EditorTool.blur.rawValue, properties: [
            "style": .string(blur.style.rawValue),
            "intensity": .number(blur.intensity),
        ])
    }
}

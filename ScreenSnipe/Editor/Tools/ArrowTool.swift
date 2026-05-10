import AppKit

@MainActor
final class ArrowTool: ToolHandler {
    private let store: AnnotationStore
    private var startPoint: CGPoint?
    private var currentAnnotation: ArrowAnnotation?

    var color: CGColor = NSColor.systemRed.cgColor
    var lineWidth: CGFloat = 3
    var headLength: CGFloat = 16

    init(store: AnnotationStore) {
        self.store = store
    }

    func mouseDown(at point: CGPoint, in canvas: CanvasView) {
        startPoint = point
        store.deselect()
    }

    func mouseDragged(to point: CGPoint, in canvas: CanvasView) {
        guard let start = startPoint else { return }

        if let existing = currentAnnotation {
            // Update in-progress annotation
            var updated = existing
            updated.end = point
            store.updateWithoutUndo(AnyAnnotation(updated))
            currentAnnotation = updated
        } else {
            // Create new annotation
            let arrow = ArrowAnnotation(start: start, end: point, color: color, lineWidth: lineWidth, headLength: headLength)
            currentAnnotation = arrow
            store.add(AnyAnnotation(arrow))
        }
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, in canvas: CanvasView) {
        if let annotation = currentAnnotation {
            var final = annotation
            final.end = point
            store.updateWithoutUndo(AnyAnnotation(final))
        }
        startPoint = nil
        currentAnnotation = nil
        canvas.needsDisplay = true
    }

    func keyDown(with event: NSEvent, in canvas: CanvasView) -> Bool {
        if event.keyCode == 53 { // Escape
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
        if case .color(let c) = preset.properties["color"] { color = c.cgColor }
        if case .number(let v) = preset.properties["lineWidth"] { lineWidth = v }
        if case .number(let v) = preset.properties["headLength"] { headLength = v }
    }

    static func extractPreset(from arrow: ArrowAnnotation, name: String) -> ToolPreset {
        ToolPreset(name: name, toolType: EditorTool.arrow.rawValue, properties: [
            "color": .color(CodableColor(arrow.color)),
            "lineWidth": .number(arrow.lineWidth),
            "headLength": .number(arrow.headLength),
        ])
    }
}

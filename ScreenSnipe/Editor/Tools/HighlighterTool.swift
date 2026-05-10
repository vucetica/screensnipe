import AppKit

@MainActor
final class HighlighterTool: ToolHandler {
    private let store: AnnotationStore
    private var currentAnnotation: HighlighterAnnotation?

    var color: CGColor = NSColor.systemYellow.withAlphaComponent(0.4).cgColor
    var lineWidth: CGFloat = 20

    init(store: AnnotationStore) {
        self.store = store
    }

    func mouseDown(at point: CGPoint, in canvas: CanvasView) {
        store.deselect()
        let annotation = HighlighterAnnotation(points: [point], color: color, lineWidth: lineWidth)
        currentAnnotation = annotation
        store.add(AnyAnnotation(annotation))
        canvas.needsDisplay = true
    }

    func mouseDragged(to point: CGPoint, in canvas: CanvasView) {
        guard var annotation = currentAnnotation else { return }
        annotation.points.append(point)
        currentAnnotation = annotation
        store.updateWithoutUndo(AnyAnnotation(annotation))
        canvas.needsDisplay = true
    }

    func mouseUp(at point: CGPoint, in canvas: CanvasView) {
        guard var annotation = currentAnnotation else { return }
        annotation.points.append(point)
        store.updateWithoutUndo(AnyAnnotation(annotation))
        currentAnnotation = nil
        canvas.needsDisplay = true
    }

    func keyDown(with event: NSEvent, in canvas: CanvasView) -> Bool {
        if event.keyCode == 53 {
            if currentAnnotation != nil {
                store.revertLast()
                currentAnnotation = nil
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
    }

    static func extractPreset(from highlighter: HighlighterAnnotation, name: String) -> ToolPreset {
        ToolPreset(name: name, toolType: EditorTool.highlighter.rawValue, properties: [
            "color": .color(CodableColor(highlighter.color)),
            "lineWidth": .number(highlighter.lineWidth),
        ])
    }
}

import AppKit

@MainActor
final class LineTool: ToolHandler {
    private let store: AnnotationStore
    private var startPoint: CGPoint?
    private var currentAnnotation: LineAnnotation?

    var color: CGColor = NSColor.systemRed.cgColor
    var lineWidth: CGFloat = 3
    var style: LineStyle = .solid

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
            var updated = existing
            updated.end = point
            store.updateWithoutUndo(AnyAnnotation(updated))
            currentAnnotation = updated
        } else {
            let line = LineAnnotation(start: start, end: point, color: color, lineWidth: lineWidth, style: style)
            currentAnnotation = line
            store.add(AnyAnnotation(line))
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
        if case .color(let c) = preset.properties["color"] { color = c.cgColor }
        if case .number(let v) = preset.properties["lineWidth"] { lineWidth = v }
        if case .string(let s) = preset.properties["style"], let parsed = LineStyle(rawValue: s) { style = parsed }
    }

    static func extractPreset(from line: LineAnnotation, name: String) -> ToolPreset {
        ToolPreset(name: name, toolType: EditorTool.line.rawValue, properties: [
            "color": .color(CodableColor(line.color)),
            "lineWidth": .number(line.lineWidth),
            "style": .string(line.style.rawValue),
        ])
    }
}

import AppKit
import Combine

@MainActor
final class TextTool: NSObject, ToolHandler, NSTextFieldDelegate {
    private let store: AnnotationStore
    private var activeTextField: NSTextField?
    private var activeAnnotation: TextAnnotation?
    private weak var activeCanvas: CanvasView?
    private var addedToStore = false
    private var storeSub: AnyCancellable?

    /// The ID of the annotation currently being edited inline, if any.
    var activeAnnotationID: UUID? { activeAnnotation?.id }

    var fontName: String = "Helvetica-Bold"
    var fontSize: CGFloat = 18
    var color: CGColor = NSColor.systemRed.cgColor

    init(store: AnnotationStore) {
        self.store = store
        super.init()
    }

    func mouseDown(at point: CGPoint, in canvas: CanvasView) {
        commitActiveText()

        // Create new text annotation and add to store immediately
        let annotation = TextAnnotation(origin: point, fontName: fontName, fontSize: fontSize, color: color)
        activeAnnotation = annotation
        addedToStore = false

        placeTextField(for: annotation, in: canvas)
    }

    /// Re-enter edit mode for an existing text annotation (e.g. on double-click).
    func editExisting(_ annotation: TextAnnotation, in canvas: CanvasView) {
        commitActiveText()
        activeAnnotation = annotation
        addedToStore = true
        store.selectedID = annotation.id

        placeTextField(for: annotation, in: canvas)
        activeTextField?.stringValue = annotation.text
        sizeTextFieldToFit()
        // Defer selectAll to next run loop — calling it immediately can trigger controlTextDidEndEditing
        DispatchQueue.main.async { [weak self] in
            self?.activeTextField?.currentEditor()?.selectAll(nil)
        }
    }

    /// Update the active text field's font size in real time (e.g. from property panel).
    func updateFontSize(_ newSize: CGFloat) {
        guard var annotation = activeAnnotation, let textField = activeTextField else { return }
        fontSize = newSize
        annotation.fontSize = newSize
        activeAnnotation = annotation

        let font = NSFont(name: annotation.fontName, size: newSize) ?? NSFont.systemFont(ofSize: newSize)
        textField.font = font

        // Resize text field height to match
        var frame = textField.frame
        frame.size.height = newSize + 8
        textField.frame = frame

        sizeTextFieldToFit()
        syncAnnotationToStore()
    }

    private static let minFieldWidth: CGFloat = 60

    private func placeTextField(for annotation: TextAnnotation, in canvas: CanvasView) {
        let viewPoint = canvas.viewPoint(from: annotation.origin)
        let size = annotation.fontSize
        let textField = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: Self.minFieldWidth, height: size + 8))
        textField.font = NSFont(name: annotation.fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        textField.textColor = NSColor(cgColor: annotation.color) ?? NSColor.red
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.focusRingType = .none
        textField.delegate = self
        textField.target = self
        textField.action = #selector(textFieldAction(_:))

        canvas.addSubview(textField)
        textField.becomeFirstResponder()

        activeTextField = textField
        activeCanvas = canvas
        startObservingStore()
    }

    private func sizeTextFieldToFit() {
        guard let textField = activeTextField else { return }
        let text = textField.stringValue
        guard let font = textField.font else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = (text as NSString).size(withAttributes: attrs).width
        var frame = textField.frame
        frame.size.width = max(textWidth + 20, Self.minFieldWidth)
        frame.size.height = font.pointSize + 8
        textField.frame = frame
    }

    /// Watch for external changes to the active annotation (e.g. property panel font size slider).
    private func startObservingStore() {
        storeSub = store.$annotations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] annotations in
                guard let self,
                      let active = self.activeAnnotation,
                      let textField = self.activeTextField,
                      let storeVersion = annotations.first(where: { $0.id == active.id }),
                      let storeText = storeVersion.unwrap(as: TextAnnotation.self) else { return }
                // Only react to external changes (font size differs from our local copy)
                if storeText.fontSize != active.fontSize {
                    self.updateFontSize(storeText.fontSize)
                }
            }
    }

    func mouseDragged(to point: CGPoint, in canvas: CanvasView) {}

    func mouseUp(at point: CGPoint, in canvas: CanvasView) {}

    func keyDown(with event: NSEvent, in canvas: CanvasView) -> Bool {
        if event.keyCode == 53 { // Escape
            commitActiveText()
            return true
        }
        return false
    }

    func cursor() -> NSCursor {
        .iBeam
    }

    @objc private func textFieldAction(_ sender: NSTextField) {
        commitActiveText()
    }

    nonisolated func controlTextDidEndEditing(_ obj: Notification) {
        Task { @MainActor in
            commitActiveText()
        }
    }

    /// Called on every keystroke — keeps the store annotation in sync
    /// so export always includes the current text.
    nonisolated func controlTextDidChange(_ obj: Notification) {
        Task { @MainActor in
            syncAnnotationToStore()
        }
    }

    private func syncAnnotationToStore() {
        guard let textField = activeTextField, var annotation = activeAnnotation else { return }
        let text = textField.stringValue
        annotation.text = text
        activeAnnotation = annotation
        sizeTextFieldToFit()

        if !text.isEmpty {
            if addedToStore {
                store.updateWithoutUndo(AnyAnnotation(annotation))
            } else {
                store.add(AnyAnnotation(annotation))
                addedToStore = true
            }
            activeCanvas?.needsDisplay = true
        } else if addedToStore {
            // Text was cleared — remove from store
            store.remove(id: annotation.id)
            addedToStore = false
            activeCanvas?.needsDisplay = true
        }
    }

    func commitActiveText() {
        guard let textField = activeTextField, var annotation = activeAnnotation else { return }
        storeSub = nil
        let text = textField.stringValue
        textField.removeFromSuperview()
        activeTextField = nil

        if text.isEmpty {
            // Remove if it was added with text that was later deleted
            if addedToStore {
                store.remove(id: annotation.id)
            }
        } else {
            annotation.text = text
            if addedToStore {
                // Final update with undo tracking
                store.update(AnyAnnotation(annotation))
            } else {
                store.add(AnyAnnotation(annotation))
            }
            activeCanvas?.needsDisplay = true
        }
        activeAnnotation = nil
        addedToStore = false
    }

    func applyPreset(_ preset: ToolPreset) {
        if case .color(let c) = preset.properties["color"] { color = c.cgColor }
        if case .number(let v) = preset.properties["fontSize"] { fontSize = v }
    }

    static func extractPreset(from text: TextAnnotation, name: String) -> ToolPreset {
        ToolPreset(name: name, toolType: EditorTool.text.rawValue, properties: [
            "color": .color(CodableColor(text.color)),
            "fontSize": .number(text.fontSize),
        ])
    }
}

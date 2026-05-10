import Foundation
import Combine

@MainActor
final class AnnotationStore: ObservableObject {
    @Published private(set) var annotations: [AnyAnnotation] = []
    @Published private(set) var cropRect: CGRect?
    @Published var magnification: CGFloat?
    @Published var selectedID: UUID?

    private struct Snapshot {
        let annotations: [AnyAnnotation]
        let cropRect: CGRect?
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var selectedAnnotation: AnyAnnotation? {
        guard let id = selectedID else { return nil }
        return annotations.first { $0.id == id }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Mutations

    func add(_ annotation: AnyAnnotation) {
        pushUndo()
        annotations.append(annotation)
        selectedID = annotation.id
    }

    func remove(id: UUID) {
        pushUndo()
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        remove(id: id)
    }

    func update(_ annotation: AnyAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        guard annotations[index] != annotation else { return }
        pushUndo()
        annotations[index] = annotation
    }

    func updateWithoutUndo(_ annotation: AnyAnnotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    func move(id: UUID, by delta: CGSize) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations[index] = annotations[index].moved(by: delta)
    }

    func resize(id: UUID, to rect: CGRect) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        annotations[index] = annotations[index].resized(to: rect)
    }

    func replaceAll(_ newAnnotations: [AnyAnnotation]) {
        pushUndo()
        annotations = newAnnotations
    }

    func replaceAllWithoutUndo(_ newAnnotations: [AnyAnnotation], cropRect: CGRect? = nil, magnification: CGFloat? = nil) {
        undoStack.removeAll()
        redoStack.removeAll()
        selectedID = nil
        annotations = newAnnotations
        self.cropRect = cropRect
        self.magnification = magnification
    }

    /// Reverts the last undoable action without leaving any undo/redo trace.
    /// Used when cancelling an in-progress drawing (e.g. Escape key).
    func revertLast() {
        guard let previous = undoStack.popLast() else { return }
        annotations = previous.annotations
        cropRect = previous.cropRect
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    // MARK: - Crop

    func setCrop(_ rect: CGRect?) {
        pushUndo()
        cropRect = rect
    }

    func clearCrop() {
        guard cropRect != nil else { return }
        pushUndo()
        cropRect = nil
    }

    // MARK: - Selection

    func select(at point: CGPoint) -> AnyAnnotation? {
        // Search in reverse order (top-most first)
        let hit = annotations.last { $0.hitTest(point: point) }
        selectedID = hit?.id
        return hit
    }

    func deselect() {
        selectedID = nil
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, cropRect: cropRect))
        annotations = previous.annotations
        cropRect = previous.cropRect
        // Clear selection if the selected annotation no longer exists
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, cropRect: cropRect))
        annotations = next.annotations
        cropRect = next.cropRect
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) {
            selectedID = nil
        }
    }

    private func pushUndo() {
        undoStack.append(Snapshot(annotations: annotations, cropRect: cropRect))
        redoStack.removeAll()
        // Limit undo history
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
    }
}

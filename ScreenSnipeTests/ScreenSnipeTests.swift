import Testing
import AppKit
@testable import ScreenSnipe

// MARK: - Annotation Tests

@Suite("Annotation Tests")
struct AnnotationTests {

    @Test func arrowAnnotationHitTest() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 100))
        // Point on the line test
        #expect(arrow.hitTest(point: CGPoint(x: 55, y: 55)))
        // Point far from line
        #expect(!arrow.hitTest(point: CGPoint(x: 200, y: 200)))
    }

    @Test func arrowAnnotationMove() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 100))
        let moved = arrow.moved(by: CGSize(width: 5, height: 5))
        #expect(moved.start.x == 15)
        #expect(moved.start.y == 15)
        #expect(moved.end.x == 105)
        #expect(moved.end.y == 105)
        #expect(moved.id == arrow.id)
    }

    @Test func shapeAnnotationBoundingRect() {
        let shape = ShapeAnnotation(rect: CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(shape.boundingRect == CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    @Test func shapeAnnotationMove() {
        let shape = ShapeAnnotation(rect: CGRect(x: 10, y: 20, width: 100, height: 50))
        let moved = shape.moved(by: CGSize(width: 10, height: -5))
        #expect(moved.rect.origin.x == 20)
        #expect(moved.rect.origin.y == 15)
        #expect(moved.rect.size.width == 100)
    }

    @Test func lineAnnotationHitTest() {
        let line = LineAnnotation(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        #expect(line.hitTest(point: CGPoint(x: 50, y: 2)))
        #expect(!line.hitTest(point: CGPoint(x: 50, y: 20)))
    }

    @Test func highlighterAnnotationMove() {
        let points = [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 30)]
        let hl = HighlighterAnnotation(points: points)
        let moved = hl.moved(by: CGSize(width: 5, height: 5))
        #expect(moved.points[0].x == 15)
        #expect(moved.points[2].y == 35)
    }

    @Test func blurAnnotationMove() {
        let blur = BlurAnnotation(rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let moved = blur.moved(by: CGSize(width: -10, height: 10))
        #expect(moved.rect.origin.x == 40)
        #expect(moved.rect.origin.y == 60)
    }

    @Test func textAnnotationMove() {
        let text = TextAnnotation(origin: CGPoint(x: 20, y: 30), text: "Hello")
        let moved = text.moved(by: CGSize(width: 10, height: 10))
        #expect(moved.origin.x == 30)
        #expect(moved.origin.y == 40)
        #expect(moved.text == "Hello")
    }

    @Test func anyAnnotationTypeErasure() {
        let arrow = ArrowAnnotation(start: .zero, end: CGPoint(x: 100, y: 100))
        let any = AnyAnnotation(arrow)
        #expect(any.id == arrow.id)
        #expect(any.unwrap(as: ArrowAnnotation.self) != nil)
        #expect(any.unwrap(as: ShapeAnnotation.self) == nil)
    }

    @Test func anyAnnotationEquality() {
        let arrow = ArrowAnnotation(start: .zero, end: CGPoint(x: 100, y: 100))
        let any1 = AnyAnnotation(arrow)
        let any2 = AnyAnnotation(arrow)
        #expect(any1 == any2)

        var different = arrow
        different.lineWidth = 10
        let any3 = AnyAnnotation(different)
        #expect(any1 != any3)
    }
}

// MARK: - AnnotationStore Tests

@Suite("AnnotationStore Tests")
struct AnnotationStoreTests {

    @MainActor
    @Test func addAndRemove() {
        let store = AnnotationStore()
        let arrow = AnyAnnotation(ArrowAnnotation(start: .zero, end: CGPoint(x: 100, y: 100)))
        store.add(arrow)
        #expect(store.annotations.count == 1)
        #expect(store.selectedID == arrow.id)

        store.remove(id: arrow.id)
        #expect(store.annotations.isEmpty)
        #expect(store.selectedID == nil)
    }

    @MainActor
    @Test func undoRedo() {
        let store = AnnotationStore()
        let arrow = AnyAnnotation(ArrowAnnotation(start: .zero, end: CGPoint(x: 100, y: 100)))
        store.add(arrow)
        #expect(store.annotations.count == 1)
        #expect(store.canUndo)
        #expect(!store.canRedo)

        store.undo()
        #expect(store.annotations.isEmpty)
        #expect(!store.canUndo)
        #expect(store.canRedo)

        store.redo()
        #expect(store.annotations.count == 1)
    }

    @MainActor
    @Test func undoRedoMultiple() {
        let store = AnnotationStore()
        let a1 = AnyAnnotation(ArrowAnnotation(start: .zero, end: CGPoint(x: 50, y: 50)))
        let a2 = AnyAnnotation(ShapeAnnotation(rect: CGRect(x: 10, y: 10, width: 80, height: 80)))
        store.add(a1)
        store.add(a2)
        #expect(store.annotations.count == 2)

        store.undo()
        #expect(store.annotations.count == 1)

        store.undo()
        #expect(store.annotations.isEmpty)

        store.redo()
        #expect(store.annotations.count == 1)

        store.redo()
        #expect(store.annotations.count == 2)
    }

    @MainActor
    @Test func selectAtPoint() {
        let store = AnnotationStore()
        let shape = AnyAnnotation(ShapeAnnotation(rect: CGRect(x: 50, y: 50, width: 100, height: 100)))
        store.add(shape)
        store.deselect()

        let hit = store.select(at: CGPoint(x: 75, y: 75))
        #expect(hit != nil)
        #expect(store.selectedID == shape.id)

        let miss = store.select(at: CGPoint(x: 0, y: 0))
        #expect(miss == nil)
        #expect(store.selectedID == nil)
    }

    @MainActor
    @Test func removeSelected() {
        let store = AnnotationStore()
        let arrow = AnyAnnotation(ArrowAnnotation(start: .zero, end: CGPoint(x: 100, y: 100)))
        store.add(arrow)
        store.removeSelected()
        #expect(store.annotations.isEmpty)
        #expect(store.selectedID == nil)
    }

    @MainActor
    @Test func undoClearsRedoOnNewAction() {
        let store = AnnotationStore()
        let a1 = AnyAnnotation(ArrowAnnotation(start: .zero, end: CGPoint(x: 50, y: 50)))
        let a2 = AnyAnnotation(ShapeAnnotation(rect: CGRect(x: 10, y: 10, width: 40, height: 40)))
        store.add(a1)
        store.add(a2)
        store.undo()
        #expect(store.canRedo)

        // Adding a new annotation should clear redo
        let a3 = AnyAnnotation(LineAnnotation(start: .zero, end: CGPoint(x: 30, y: 30)))
        store.add(a3)
        #expect(!store.canRedo)
    }
}

// MARK: - ImageExportService Tests

@Suite("ImageExportService Tests")
struct ImageExportServiceTests {

    @MainActor
    @Test func flattenProducesCorrectSizeImage() {
        let size = NSSize(width: 200, height: 150)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let flattened = ImageExportService.flatten(image: image, annotations: [])
        #expect(flattened.size.width == 200)
        #expect(flattened.size.height == 150)
    }

    @MainActor
    @Test func flattenWithAnnotations() {
        let size = NSSize(width: 100, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let arrow = AnyAnnotation(ArrowAnnotation(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 90, y: 90)))
        let flattened = ImageExportService.flatten(image: image, annotations: [arrow])
        // Flattened image expands to fit annotation bounding rect (arrow head extends beyond endpoint)
        #expect(flattened.size.width >= 100)
        #expect(flattened.size.height >= 100)
    }
}

// MARK: - EditorTool Tests

@Suite("EditorTool Tests")
struct EditorToolTests {

    @Test func allToolsHaveDisplayNamesAndIcons() {
        for tool in EditorTool.allCases {
            #expect(!tool.displayName.isEmpty)
            #expect(!tool.iconName.isEmpty)
        }
    }

    @Test func toolCount() {
        #expect(EditorTool.allCases.count == 8)
    }
}

// MARK: - CaptureMode Tests

@Suite("CaptureMode Tests")
struct CaptureModeTests {

    @Test func allModes() {
        #expect(CaptureMode.allCases.count == 3)
        #expect(CaptureMode.allCases.contains(.region))
        #expect(CaptureMode.allCases.contains(.fullScreen))
        #expect(CaptureMode.allCases.contains(.window))
    }
}

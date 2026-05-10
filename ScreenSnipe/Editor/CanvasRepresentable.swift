import SwiftUI

struct CanvasRepresentable: NSViewRepresentable {
    let image: NSImage
    @ObservedObject var store: AnnotationStore
    @Binding var activeTool: EditorTool

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = CanvasView(image: image, store: store)

        let scrollView = NSScrollView()

        // Replace the default clip view with a centering one
        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = canvas

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.drawsBackground = true

        context.coordinator.canvas = canvas
        context.coordinator.currentImageID = ObjectIdentifier(image)
        context.coordinator.store = store
        context.coordinator.updateToolHandler(for: activeTool, store: store)
        context.coordinator.observeMagnification(of: scrollView)

        // Restore saved magnification or default to 1:1
        context.coordinator.restoreMagnification(store.magnification ?? 1.0, on: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let canvas = scrollView.documentView as? CanvasView {
            let imageID = ObjectIdentifier(image)
            let isNewImage = imageID != context.coordinator.currentImageID
            if canvas.image !== image {
                canvas.image = image
                canvas.setFrameSize(image.size)
                canvas.invalidateBlurCache()
            }
            canvas.store = store
            context.coordinator.canvas = canvas
            context.coordinator.updateToolHandler(for: activeTool, store: store)
            canvas.needsLayout = true
            canvas.needsDisplay = true

            context.coordinator.store = store

            if isNewImage {
                context.coordinator.currentImageID = imageID
                // Restore saved magnification or default to 1:1
                context.coordinator.restoreMagnification(store.magnification ?? 1.0, on: scrollView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var canvas: CanvasView?
        weak var store: AnnotationStore?
        var currentImageID: ObjectIdentifier?
        private var currentTool: EditorTool?
        private var currentHandler: ToolHandler?
        private weak var currentStore: AnnotationStore?
        private var magnificationObservation: NSKeyValueObservation?
        private var isRestoringMagnification = false

        func observeMagnification(of scrollView: NSScrollView) {
            magnificationObservation = scrollView.observe(\.magnification, options: [.new]) { [weak self] scrollView, change in
                guard let self else { return }
                guard !self.isRestoringMagnification else { return }
                guard let value = change.newValue else { return }
                self.store?.magnification = value
            }
        }

        func restoreMagnification(_ value: CGFloat, on scrollView: NSScrollView) {
            isRestoringMagnification = true
            scrollView.magnification = value
            isRestoringMagnification = false
        }


        func updateToolHandler(for tool: EditorTool, store: AnnotationStore) {
            let storeChanged = currentStore !== store
            guard tool != currentTool || storeChanged, let canvas else {
                canvas?.needsDisplay = true
                return
            }
            currentStore = store
            // Clear crop preview when switching away from crop tool
            canvas.cropPreviewRect = nil
            currentTool = tool
            let handler: ToolHandler = switch tool {
            case .selection: SelectionTool(store: store)
            case .arrow: ArrowTool(store: store)
            case .text: TextTool(store: store)
            case .shape: ShapeTool(store: store)
            case .line: LineTool(store: store)
            case .highlighter: HighlighterTool(store: store)
            case .blur: BlurTool(store: store)
            case .crop: CropTool(store: store)
            }
            currentHandler = handler
            canvas.toolHandler = handler
            LibraryViewModel.shared.currentToolHandler = handler
            canvas.cropToolActive = tool == .crop

            // When switching to crop tool, initialize crop to full image if none set
            if tool == .crop, store.cropRect == nil {
                let fullImage = CGRect(origin: .zero, size: canvas.image.size)
                store.setCrop(fullImage)
            }
            canvas.window?.invalidateCursorRects(for: canvas)
        }
    }
}

// MARK: - Centering Clip View

/// NSClipView subclass that centers the document when it's smaller than the visible area.
@MainActor
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }

        let docFrame = documentView.frame
        if docFrame.width < constrained.width {
            constrained.origin.x = (docFrame.width - constrained.width) / 2
        }
        if docFrame.height < constrained.height {
            constrained.origin.y = (docFrame.height - constrained.height) / 2
        }
        return constrained
    }
}

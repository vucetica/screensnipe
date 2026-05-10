import AppKit

@MainActor
protocol ToolHandler: AnyObject {
    func mouseDown(at point: CGPoint, in canvas: CanvasView)
    func mouseDragged(to point: CGPoint, in canvas: CanvasView)
    func mouseUp(at point: CGPoint, in canvas: CanvasView)
    func keyDown(with event: NSEvent, in canvas: CanvasView) -> Bool
    func cursor() -> NSCursor
}

@MainActor
final class CanvasView: NSView {
    var image: NSImage
    var store: AnnotationStore
    var toolHandler: ToolHandler?

    /// Ad-hoc TextTool used when double-clicking a text annotation from a non-text tool.
    private var inlineEditTool: TextTool?

    /// Live crop preview rect set by CropTool during drag.
    var cropPreviewRect: CGRect?

    /// Whether the crop tool is currently active (overlay only draws when true).
    var cropToolActive = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Offset applied to shift all drawing so that negative-coordinate annotations are visible.
    /// Image coordinate (0,0) is drawn at view coordinate (canvasOffset.x, canvasOffset.y).
    private(set) var canvasOffset = CGPoint.zero

    /// Cached CIContext for blur rendering — creating one per draw call is expensive (GPU state init).
    private lazy var ciContext = CIContext()

    /// Cache of rendered blur images keyed by annotation ID, invalidated when blur parameters change.
    private var blurCache: [UUID: BlurCacheEntry] = [:]

    private struct BlurCacheEntry {
        let rect: CGRect
        let style: BlurStyle
        let intensity: CGFloat
        let rendered: CGImage
    }

    // Base selection state — works regardless of active tool
    private var selectionOverrideActive = false
    private var selectionDragOrigin: CGPoint?
    private var selectionOriginalAnnotation: AnyAnnotation?
    private var selectionIsDragging = false
    private var selectionEndpointDrag = false
    private var selectionHandleDrag: HandleKind?

    init(image: NSImage, store: AnnotationStore) {
        self.image = image
        self.store = store
        super.init(frame: CGRect(origin: .zero, size: image.size))
    }

    // MARK: - Tracking Areas

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = imagePoint(from: convert(event.locationInWindow, from: nil))
        updateCursorForPosition(pt)
    }

    override func mouseExited(with event: NSEvent) {
        toolHandler?.cursor().set()
    }

    func updateCursorForPosition(_ pt: CGPoint) {
        // When crop tool is active, use its context-aware cursor
        if let cropTool = toolHandler as? CropTool {
            cropTool.cursorForPosition(pt, in: self).set()
            return
        }

        guard let selectedID = store.selectedID,
              let selected = store.annotations.first(where: { $0.id == selectedID }),
              let cursor = SelectionTool.cursorForPosition(pt, selected: selected, in: self) else {
            toolHandler?.cursor().set()
            return
        }
        cursor.set()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Coordinate Helpers

    /// Convert view coordinates to image coordinates (subtract canvas offset).
    func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x - canvasOffset.x, y: viewPoint.y - canvasOffset.y)
    }

    /// Convert image coordinates to view coordinates (add canvas offset).
    func viewPoint(from imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: imagePoint.x + canvasOffset.x, y: imagePoint.y + canvasOffset.y)
    }

    // MARK: - Layout

    private var isUpdatingLayout = false

    override func layout() {
        super.layout()
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        updateFrameForAnnotations()
        isUpdatingLayout = false
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        guard bounds.width > 0, bounds.height > 0 else { return }

        // System-aware background — covers image area plus any annotation overflow
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // Translate so image origin (0,0) draws at (canvasOffset.x, canvasOffset.y)
        context.saveGState()
        context.translateBy(x: canvasOffset.x, y: canvasOffset.y)

        // When crop is set and crop tool is not active, clip all drawing to the crop rect
        if let crop = store.cropRect, !cropToolActive {
            context.clip(to: crop)
        }

        // Draw base image at 1:1 — NSScrollView handles magnification
        let imageRect = CGRect(origin: .zero, size: image.size)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        let zoom = enclosingScrollView?.magnification ?? 1.0

        // Draw blur annotations first (they need base image access)
        var activeBlurIDs: Set<UUID> = []
        for annotation in store.annotations {
            if let blur = annotation.unwrap(as: BlurAnnotation.self) {
                activeBlurIDs.insert(blur.id)
                drawBlur(blur, in: context)
            }
        }
        // Evict stale cache entries for deleted blur annotations
        if blurCache.count > activeBlurIDs.count {
            blurCache = blurCache.filter { activeBlurIDs.contains($0.key) }
        }

        // Draw all other annotations at scale 1 — they scale naturally with zoom
        let editingID = (toolHandler as? TextTool)?.activeAnnotationID ?? inlineEditTool?.activeAnnotationID
        for annotation in store.annotations {
            if annotation.unwrap(as: BlurAnnotation.self) != nil { continue }
            if annotation.id == editingID { continue }
            annotation.draw(in: context, scale: 1.0)
        }

        // Draw selection handles (these stay constant screen size)
        if let selectedID = store.selectedID,
           let selected = store.annotations.first(where: { $0.id == selectedID }) {
            if let arrow = selected.unwrap(as: ArrowAnnotation.self) {
                drawEndpointHandles(start: arrow.start, end: arrow.end, in: context, zoom: zoom)
            } else if let line = selected.unwrap(as: LineAnnotation.self) {
                drawEndpointHandles(start: line.start, end: line.end, in: context, zoom: zoom)
            } else if let highlighter = selected.unwrap(as: HighlighterAnnotation.self) {
                drawStrokeSelectionIndicator(points: highlighter.points, in: context, zoom: zoom)
            } else {
                drawSelectionHandles(for: selected.boundingRect, in: context, zoom: zoom)
            }
        }

        // Draw crop overlay only when crop tool is active
        if cropToolActive {
            let effectiveCropRect = cropPreviewRect ?? store.cropRect
            if let cropRect = effectiveCropRect {
                drawCropOverlay(cropRect, in: context, zoom: zoom)
            }
        }

        context.restoreGState()
    }

    // MARK: - Crop Overlay

    private func drawCropOverlay(_ cropRect: CGRect, in context: CGContext, zoom: CGFloat) {
        let imageRect = CGRect(origin: .zero, size: image.size)

        // Dim area outside crop with semi-transparent black using even-odd fill
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.beginPath()
        context.addRect(imageRect)
        context.addRect(cropRect)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        // Dual-stroke border: outer black + inner white for visibility on both light and dark content
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(2.5 / zoom)
        context.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
        context.stroke(cropRect)
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
        context.stroke(cropRect)
        context.restoreGState()

        // Resize handles
        let handleSize: CGFloat = 8 / zoom
        let handles = selectionHandleRects(for: cropRect, handleSize: handleSize)

        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1 / zoom)
        context.setLineDash(phase: 0, lengths: [])

        for handle in handles {
            context.fillEllipse(in: handle)
            context.strokeEllipse(in: handle)
        }
    }

    private func drawBlur(_ blur: BlurAnnotation, in context: CGContext) {
        // Use cached result if blur parameters haven't changed
        if let cached = blurCache[blur.id],
           cached.rect == blur.rect,
           cached.style == blur.style,
           cached.intensity == blur.intensity {
            let blurredImage = NSImage(cgImage: cached.rendered, size: blur.rect.size)
            context.saveGState()
            context.clip(to: blur.rect)
            blurredImage.draw(in: blur.rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            context.restoreGState()
            return
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)
        let scaleX = imgWidth / image.size.width
        let scaleY = imgHeight / image.size.height

        let pixelRect = CGRect(
            x: blur.rect.origin.x * scaleX,
            y: blur.rect.origin.y * scaleY,
            width: blur.rect.width * scaleX,
            height: blur.rect.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))

        guard pixelRect.width > 0, pixelRect.height > 0,
              let cropped = cgImage.cropping(to: pixelRect) else { return }

        let ciImage = CIImage(cgImage: cropped)
        let filter: CIFilter?
        switch blur.style {
        case .gaussian:
            filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(blur.intensity, forKey: kCIInputRadiusKey)
        case .pixelate:
            filter = CIFilter(name: "CIPixellate")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(blur.intensity, forKey: kCIInputScaleKey)
        }

        guard let output = filter?.outputImage else { return }
        let extent = ciImage.extent
        guard let blurredCG = ciContext.createCGImage(output, from: extent) else { return }

        blurCache[blur.id] = BlurCacheEntry(rect: blur.rect, style: blur.style, intensity: blur.intensity, rendered: blurredCG)

        let blurredImage = NSImage(cgImage: blurredCG, size: blur.rect.size)
        context.saveGState()
        context.clip(to: blur.rect)
        blurredImage.draw(in: blur.rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        context.restoreGState()
    }

    /// Invalidate blur cache (call when base image changes).
    func invalidateBlurCache() {
        blurCache.removeAll()
    }

    private func drawSelectionHandles(for rect: CGRect, in context: CGContext, zoom: CGFloat) {
        let handleSize: CGFloat = 8 / zoom
        let handles = selectionHandleRects(for: rect, handleSize: handleSize)

        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1 / zoom)

        for handle in handles {
            context.fillEllipse(in: handle)
            context.strokeEllipse(in: handle)
        }

        // Dashed border
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineDash(phase: 0, lengths: [4 / zoom, 4 / zoom])
        context.stroke(rect)
    }

    private func drawEndpointHandles(start: CGPoint, end: CGPoint, in context: CGContext, zoom: CGFloat) {
        let handleSize: CGFloat = 8 / zoom

        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / zoom)

        for point in [start, end] {
            let handle = CGRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)
            context.fillEllipse(in: handle)
            context.strokeEllipse(in: handle)
        }

        // Dashed line between endpoints
        context.setLineDash(phase: 0, lengths: [4 / zoom, 4 / zoom])
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private func drawStrokeSelectionIndicator(points: [CGPoint], in context: CGContext, zoom: CGFloat) {
        guard points.count >= 2 else { return }
        let handleSize: CGFloat = 8 / zoom

        // Dashed path following the stroke
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [4 / zoom, 4 / zoom])
        context.beginPath()
        context.move(to: points[0])
        for i in 1..<points.count {
            context.addLine(to: points[i])
        }
        context.strokePath()
        context.restoreGState()

        // Endpoint handles at first and last point
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [])

        for point in [points[0], points[points.count - 1]] {
            let handle = CGRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2, width: handleSize, height: handleSize)
            context.fillEllipse(in: handle)
            context.strokeEllipse(in: handle)
        }
    }

    func selectionHandleRects(for rect: CGRect, handleSize: CGFloat = 8) -> [CGRect] {
        let hs = handleSize
        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
        ]
        return points.map { CGRect(x: $0.x - hs / 2, y: $0.y - hs / 2, width: hs, height: hs) }
    }

    // MARK: - Canvas Size

    private func updateFrameForAnnotations() {
        // When crop is set and crop tool is NOT active, viewport = crop rect only
        if let crop = store.cropRect, !cropToolActive {
            let newOffset = CGPoint(x: -crop.origin.x, y: -crop.origin.y)
            let neededSize = NSSize(width: crop.width, height: crop.height)

            let offsetChanged = abs(canvasOffset.x - newOffset.x) > 1 || abs(canvasOffset.y - newOffset.y) > 1
            let sizeChanged = abs(frame.size.width - neededSize.width) > 1 || abs(frame.size.height - neededSize.height) > 1

            if offsetChanged || sizeChanged {
                canvasOffset = newOffset
                setFrameSize(neededSize)
            }
            return
        }

        let padding: CGFloat = 20
        var minX: CGFloat = 0
        var minY: CGFloat = 0
        var maxX: CGFloat = image.size.width
        var maxY: CGFloat = image.size.height

        for annotation in store.annotations {
            let rect = annotation.boundingRect
            minX = min(minX, rect.minX)
            minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }

        // Offset: shift everything right/down to make negative coords visible
        let offsetX = minX < 0 ? -minX + padding : 0
        let offsetY = minY < 0 ? -minY + padding : 0
        let neededWidth = maxX + offsetX + (maxX > image.size.width ? padding : 0)
        let neededHeight = maxY + offsetY + (maxY > image.size.height ? padding : 0)

        let newOffset = CGPoint(x: offsetX, y: offsetY)
        let neededSize = NSSize(width: neededWidth, height: neededHeight)

        let offsetChanged = abs(canvasOffset.x - newOffset.x) > 1 || abs(canvasOffset.y - newOffset.y) > 1
        let sizeChanged = abs(frame.size.width - neededSize.width) > 1 || abs(frame.size.height - neededSize.height) > 1

        if offsetChanged || sizeChanged {
            canvasOffset = newOffset
            setFrameSize(neededSize)
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let pt = imagePoint(from: convert(event.locationInWindow, from: nil))

        // Double-click on a text annotation → enter inline edit mode (from any tool)
        if event.clickCount == 2 {
            if let hit = store.annotations.last(where: { $0.hitTest(point: pt) }),
               let textAnnotation = hit.unwrap(as: TextAnnotation.self) {
                let textTool: TextTool
                if let existing = toolHandler as? TextTool {
                    textTool = existing
                } else {
                    textTool = TextTool(store: store)
                    inlineEditTool = textTool
                }
                textTool.editExisting(textAnnotation, in: self)
                needsDisplay = true
                return
            }
        }

        // Commit any ad-hoc inline text edit when clicking elsewhere
        if let editTool = inlineEditTool, editTool.activeAnnotationID != nil {
            editTool.commitActiveText()
            inlineEditTool = nil
            needsDisplay = true
        }

        // Skip selection override when crop tool is active — crop handles its own interactions
        if !(toolHandler is SelectionTool) && !(toolHandler is CropTool) {
            // Check endpoint/handle hit on currently selected annotation first
            if let selectedID = store.selectedID,
               let selected = store.annotations.first(where: { $0.id == selectedID }) {
                if SelectionTool.endpointHit(for: selected, at: pt) != nil {
                    selectionOverrideActive = true
                    selectionEndpointDrag = true
                    selectionHandleDrag = nil
                    selectionDragOrigin = pt
                    selectionOriginalAnnotation = selected
                    selectionIsDragging = false
                    needsDisplay = true
                    return
                }
                if let handle = SelectionTool.handleHit(for: selected, at: pt, in: self) {
                    selectionOverrideActive = true
                    selectionEndpointDrag = false
                    selectionHandleDrag = handle
                    selectionDragOrigin = pt
                    selectionOriginalAnnotation = selected
                    selectionIsDragging = false
                    needsDisplay = true
                    return
                }
            }

            if let hit = store.select(at: pt) {
                selectionOverrideActive = true
                selectionEndpointDrag = false
                selectionHandleDrag = nil
                selectionDragOrigin = pt
                selectionOriginalAnnotation = hit
                selectionIsDragging = false
                needsDisplay = true
                return
            }
            // Click on empty space — deselect and let the drawing tool handle it
            store.deselect()
            needsDisplay = true
        }

        toolHandler?.mouseDown(at: pt, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = imagePoint(from: convert(event.locationInWindow, from: nil))

        if selectionOverrideActive {
            guard let origin = selectionDragOrigin, let annotation = selectionOriginalAnnotation else { return }
            selectionIsDragging = true

            if selectionEndpointDrag, let ep = SelectionTool.endpointHit(for: annotation, at: origin) {
                let updated = SelectionTool.moveEndpoint(ep, of: annotation, from: origin, to: pt)
                store.updateWithoutUndo(updated)
                SelectionTool.endpointResizeCursor(for: annotation, endpoint: ep).set()
            } else if let handle = selectionHandleDrag {
                let updated = SelectionTool.resizeWithHandle(handle, of: annotation, from: origin, to: pt)
                store.updateWithoutUndo(updated)
            } else {
                let delta = CGSize(width: pt.x - origin.x, height: pt.y - origin.y)
                store.updateWithoutUndo(annotation.moved(by: delta))
                NSCursor.closedHand.set()
            }
            needsDisplay = true
            return
        }

        toolHandler?.mouseDragged(to: pt, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        let pt = imagePoint(from: convert(event.locationInWindow, from: nil))

        if selectionOverrideActive {
            if selectionIsDragging, let origin = selectionDragOrigin, let original = selectionOriginalAnnotation {
                store.updateWithoutUndo(original)

                if selectionEndpointDrag, let ep = SelectionTool.endpointHit(for: original, at: origin) {
                    let updated = SelectionTool.moveEndpoint(ep, of: original, from: origin, to: pt)
                    store.update(updated)
                } else if let handle = selectionHandleDrag {
                    let updated = SelectionTool.resizeWithHandle(handle, of: original, from: origin, to: pt)
                    store.update(updated)
                } else {
                    let delta = CGSize(width: pt.x - origin.x, height: pt.y - origin.y)
                    store.update(original.moved(by: delta))
                }
            }
            selectionOverrideActive = false
            selectionDragOrigin = nil
            selectionOriginalAnnotation = nil
            selectionIsDragging = false
            selectionEndpointDrag = false
            selectionHandleDrag = nil
            updateCursorForPosition(pt)
            needsDisplay = true
            return
        }

        toolHandler?.mouseUp(at: pt, in: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              let scrollView = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 3)
        let factor = 1.0 + delta * 0.01
        let newMag = min(max(scrollView.magnification * factor,
                            scrollView.minMagnification),
                        scrollView.maxMagnification)
        scrollView.magnification = newMag
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if let chars = event.charactersIgnoringModifiers {
            // Cmd+Z → undo, Cmd+Shift+Z → redo
            if chars == "z" && flags == .command {
                store.undo()
                needsDisplay = true
                return true
            }
            if chars == "z" && flags == [.command, .shift] {
                store.redo()
                needsDisplay = true
                return true
            }
            // Cmd+S → save
            if chars == "s" && flags == .command {
                ImageExportService.save(image: image, annotations: store.annotations, cropRect: store.cropRect)
                return true
            }
            // Cmd+C → copy
            if chars == "c" && flags == .command {
                ImageExportService.copyToClipboard(image: image, annotations: store.annotations, cropRect: store.cropRect)
                CopiedToast.show(in: window)
                return true
            }
            // Cmd+= or Cmd++ → zoom in
            if (chars == "=" || chars == "+") && flags == .command {
                zoomIn()
                return true
            }
            // Cmd+- → zoom out
            if chars == "-" && flags == .command {
                zoomOut()
                return true
            }
            // Cmd+0 → fit to window
            if chars == "0" && flags == .command {
                zoomToFit()
                return true
            }
            // Cmd+1 → actual size (account for Retina backing scale)
            if chars == "1" && flags == .command {
                let scale = window?.backingScaleFactor ?? 1.0
                enclosingScrollView?.magnification = 1.0 / scale
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Delete key always removes selected annotation regardless of tool
        if (event.keyCode == 51 || event.keyCode == 117) && store.selectedID != nil {
            store.removeSelected()
            needsDisplay = true
            return
        }

        // Tool-switching shortcuts (bare key, no modifiers, not during text editing)
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           inlineEditTool?.activeAnnotationID == nil,
           !(toolHandler is TextTool && (toolHandler as? TextTool)?.activeAnnotationID != nil),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           let tool = EditorTool.allCases.first(where: { $0.shortcutHint?.lowercased() == chars }) {
            LibraryViewModel.shared.activeTool = tool
            return
        }

        // Arrow key nudging always works for selected annotations
        if [123, 124, 125, 126].contains(Int(event.keyCode)),
           let selectedID = store.selectedID,
           let selected = store.annotations.first(where: { $0.id == selectedID }) {
            let nudge: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var delta = CGSize.zero
            switch event.keyCode {
            case 123: delta.width = -nudge  // Left
            case 124: delta.width = nudge   // Right
            case 125: delta.height = nudge  // Down
            case 126: delta.height = -nudge // Up
            default: break
            }
            store.update(selected.moved(by: delta))
            needsDisplay = true
            return
        }

        if toolHandler?.keyDown(with: event, in: self) == true {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Zoom Helpers

    func zoomIn() {
        guard let scrollView = enclosingScrollView else { return }
        let newMag = min(scrollView.magnification * 1.25, scrollView.maxMagnification)
        scrollView.magnification = newMag
    }

    func zoomOut() {
        guard let scrollView = enclosingScrollView else { return }
        let newMag = max(scrollView.magnification / 1.25, scrollView.minMagnification)
        scrollView.magnification = newMag
    }

    func zoomToFit() {
        guard let scrollView = enclosingScrollView else { return }
        let viewport = scrollView.contentView.bounds.size
        let docSize = frame.size
        guard viewport.width > 0, viewport.height > 0,
              docSize.width > 0, docSize.height > 0 else { return }
        let fitMag = min(viewport.width / docSize.width,
                         viewport.height / docSize.height,
                         1.0)
        scrollView.magnification = max(fitMag, scrollView.minMagnification)
    }

    override func resetCursorRects() {
        if let cursor = toolHandler?.cursor() {
            addCursorRect(bounds, cursor: cursor)
        }
    }
}

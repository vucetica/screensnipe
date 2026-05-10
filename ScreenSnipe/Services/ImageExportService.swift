import AppKit

@MainActor
enum ImageExportService {

    /// Cached CIContext for blur rendering — creating one per call is expensive (GPU state init).
    private static let ciContext = CIContext()

    static func flatten(image: NSImage, annotations: [AnyAnnotation], cropRect: CGRect? = nil) -> NSImage {
        // Compute total bounds including negative coordinates
        var minX: CGFloat = 0
        var minY: CGFloat = 0
        var maxX: CGFloat = image.size.width
        var maxY: CGFloat = image.size.height
        for annotation in annotations {
            let rect = annotation.boundingRect
            minX = min(minX, rect.minX)
            minY = min(minY, rect.minY)
            maxX = max(maxX, rect.maxX)
            maxY = max(maxY, rect.maxY)
        }

        let offsetX = minX < 0 ? -minX : 0
        let offsetY = minY < 0 ? -minY : 0
        let size = NSSize(width: maxX + offsetX, height: maxY + offsetY)

        let result = NSImage(size: size)
        result.lockFocus()

        guard let cgContext = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return image
        }

        // Flip the CGContext for top-left origin (matching CanvasView's isFlipped=true)
        cgContext.translateBy(x: 0, y: size.height)
        cgContext.scaleBy(x: 1, y: -1)

        // Wrap the same CGContext in a flipped NSGraphicsContext so that
        // NSImage.draw with respectFlipped:true works correctly.
        let flippedCtx = NSGraphicsContext(cgContext: cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flippedCtx

        // White background
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()

        // Translate so image-space (0,0) maps to (offsetX, offsetY)
        cgContext.translateBy(x: offsetX, y: offsetY)

        // Draw base image at origin
        let imageRect = CGRect(origin: .zero, size: image.size)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        // Draw blur annotations first
        for annotation in annotations {
            if let blur = annotation.unwrap(as: BlurAnnotation.self) {
                drawBlurForExport(blur, image: image, in: cgContext)
            }
        }

        // Draw all other annotations
        for annotation in annotations {
            if annotation.unwrap(as: BlurAnnotation.self) != nil { continue }
            annotation.draw(in: cgContext, scale: 1.0)
        }

        NSGraphicsContext.restoreGraphicsState()
        result.unlockFocus()

        // Apply crop if set
        if let crop = cropRect {
            return cropImage(result, to: crop, offset: CGPoint(x: offsetX, y: offsetY))
        }

        return result
    }

    private static func cropImage(_ image: NSImage, to cropRect: CGRect, offset: CGPoint) -> NSImage {
        // cropRect is in image coordinates; offset shifts it to flattened-image coordinates
        let adjustedRect = cropRect.offsetBy(dx: offset.x, dy: offset.y)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }

        let scaleX = CGFloat(cgImage.width) / image.size.width
        let scaleY = CGFloat(cgImage.height) / image.size.height

        let pixelRect = CGRect(
            x: adjustedRect.origin.x * scaleX,
            y: adjustedRect.origin.y * scaleY,
            width: adjustedRect.width * scaleX,
            height: adjustedRect.height * scaleY
        )

        guard let cropped = cgImage.cropping(to: pixelRect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: adjustedRect.width, height: adjustedRect.height))
    }

    private static func drawBlurForExport(_ blur: BlurAnnotation, image: NSImage, in context: CGContext) {
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
        guard let blurredCG = ciContext.createCGImage(output, from: ciImage.extent) else { return }

        // Use NSImage.draw to respect the flipped context (same as CanvasView)
        let blurredImage = NSImage(cgImage: blurredCG, size: blur.rect.size)
        context.saveGState()
        context.clip(to: blur.rect)
        blurredImage.draw(in: blur.rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        context.restoreGState()
    }

    // MARK: - Save

    static func save(image: NSImage, annotations: [AnyAnnotation], cropRect: CGRect? = nil, defaultName: String? = nil) {
        let flattened = flatten(image: image, annotations: annotations, cropRect: cropRect)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        let baseName = defaultName ?? "Screenshot"
        panel.nameFieldStringValue = "\(baseName).png"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let isPNG = url.pathExtension.lowercased() != "jpg" && url.pathExtension.lowercased() != "jpeg"

        guard let tiffData = flattened.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return }

        let data: Data?
        if isPNG {
            data = bitmapRep.representation(using: .png, properties: [:])
        } else {
            data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }

        do {
            try data?.write(to: url)
        } catch {
            ErrorReporter.report(error, context: "Failed to save image")
        }
    }

    // MARK: - Copy to Clipboard

    static func copyToClipboard(image: NSImage, annotations: [AnyAnnotation], cropRect: CGRect? = nil) {
        let flattened = flatten(image: image, annotations: annotations, cropRect: cropRect)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([flattened])
    }
}

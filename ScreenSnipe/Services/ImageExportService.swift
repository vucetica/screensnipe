import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

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

    // MARK: - Series Export

    /// One frame of a series, ready to flatten.
    struct SeriesExportFrame: Sendable {
        let image: NSImage
        let annotations: [AnyAnnotation]
        let cropRect: CGRect?
    }

    /// Saves every frame of a series as one multi-page TIFF or PDF.
    ///
    /// TIFF is offered here rather than used as the library's storage format:
    /// appending a frame to a multi-page TIFF means rewriting the whole file
    /// with every frame resident in memory, and it is far larger than PNG.
    /// Handing the whole series to someone else is where one file earns its keep.
    /// The chosen file type decides the scope: PNG and JPEG write the frame
    /// currently open in the editor, TIFF and PDF write the whole series as one
    /// multi-page file. `allFrames` is only consulted for the latter, so picking
    /// PNG never pays the cost of loading every frame.
    static func saveSeries(
        currentFrame: SeriesExportFrame,
        allFrames: () -> [SeriesExportFrame],
        defaultName: String? = nil
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiff, .pdf, .gif, .png, .jpeg]
        let baseName = defaultName ?? "Series"
        panel.nameFieldStringValue = "\(baseName).tiff"
        panel.canCreateDirectories = true
        panel.message = "TIFF, PDF, and GIF save every frame in one file. PNG and JPEG save the current frame."

        let gifOptions = GIFOptionsAccessory()
        panel.accessoryView = gifOptions.view

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "tiff", "tif", "pdf", "gif":
            let frames = allFrames()
            guard !frames.isEmpty else { return }
            let flattened = frames.map {
                flatten(image: $0.image, annotations: $0.annotations, cropRect: $0.cropRect)
            }
            do {
                switch ext {
                case "pdf":
                    try writePDF(flattened, to: url)
                case "gif":
                    let options = gifOptions.commit()
                    try writeAnimatedGIF(flattened, delay: options.delay, loopCount: options.loopCount, to: url)
                default:
                    try writeMultiPageTIFF(flattened, to: url)
                }
            } catch {
                ErrorReporter.report(error, context: "Failed to save series")
            }
        default:
            let flattened = flatten(
                image: currentFrame.image,
                annotations: currentFrame.annotations,
                cropRect: currentFrame.cropRect
            )
            write(flattened, to: url)
        }
    }

    /// Encodes and writes a flattened image, picking the format from the
    /// extension the save panel produced.
    private static func write(_ image: NSImage, to url: URL) {
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return }
        let data = isJPEG
            ? bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            : bitmapRep.representation(using: .png, properties: [:])
        do {
            try data?.write(to: url)
        } catch {
            ErrorReporter.report(error, context: "Failed to save image")
        }
    }

    private static func writeMultiPageTIFF(_ images: [NSImage], to url: URL) throws {
        let reps: [NSBitmapImageRep] = images.compactMap { image in
            guard let tiff = image.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)
        }
        guard !reps.isEmpty, let data = NSBitmapImageRep.representationOfImageReps(
            in: reps,
            using: .tiff,
            properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]
        ) else {
            throw NSError(domain: "ImageExportService", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Could not build a multi-page TIFF from the series frames.",
            ])
        }
        try data.write(to: url, options: .atomic)
    }

    /// Writes the frames as an animated GIF.
    ///
    /// - Parameters:
    ///   - delay: seconds each frame stays on screen.
    ///   - loopCount: how many times the animation plays; 0 loops forever.
    ///
    /// A GIF has one canvas size, taken from its first frame. Frames can differ
    /// in size when they have different crops, so every frame is centered on a
    /// white canvas as large as the biggest frame.
    private static func writeAnimatedGIF(_ images: [NSImage], delay: Double, loopCount: Int, to url: URL) throws {
        let cgImages = images.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let canvasWidth = cgImages.map(\.width).max() ?? 0
        let canvasHeight = cgImages.map(\.height).max() ?? 0

        guard !cgImages.isEmpty,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, cgImages.count, nil)
        else {
            throw NSError(domain: "ImageExportService", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Could not build an animated GIF from the series frames.",
            ])
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
        ] as CFDictionary)

        // Both keys are set: viewers that honor the unclamped value show short
        // delays as given, and the others fall back to the clamped one.
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        for image in cgImages {
            let frame = padded(image, toWidth: canvasWidth, height: canvasHeight) ?? image
            CGImageDestinationAddImage(destination, frame, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageExportService", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Could not write the animated GIF.",
            ])
        }
    }

    /// Centers `image` on a white canvas of the given pixel size.
    private static func padded(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        guard image.width != width || image.height != height else { return image }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let origin = CGPoint(x: (width - image.width) / 2, y: (height - image.height) / 2)
        context.draw(image, in: CGRect(origin: origin, size: CGSize(width: image.width, height: image.height)))
        return context.makeImage()
    }

    private static func writePDF(_ images: [NSImage], to url: URL) throws {
        let document = PDFDocument()
        for (index, image) in images.enumerated() {
            guard let page = PDFPage(image: image) else { continue }
            document.insert(page, at: index)
        }
        guard document.pageCount > 0, document.write(to: url) else {
            throw NSError(domain: "ImageExportService", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Could not build a PDF from the series frames.",
            ])
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

/// The animated GIF fields shown under the series save panel. The last values
/// used are remembered so a repeat export does not need retyping.
@MainActor
private final class GIFOptionsAccessory {
    private static let delayKey = "seriesGIFFrameDelay"
    private static let loopCountKey = "seriesGIFLoopCount"

    let view: NSView
    private let delayField: NSTextField
    private let loopField: NSTextField

    init() {
        let defaults = UserDefaults.standard
        let delay = defaults.object(forKey: Self.delayKey) as? Double ?? 1.0
        let loops = defaults.object(forKey: Self.loopCountKey) as? Int ?? 0

        let delayFormatter = NumberFormatter()
        delayFormatter.numberStyle = .decimal
        delayFormatter.minimum = 0.01
        delayFormatter.maximum = 600
        delayFormatter.maximumFractionDigits = 2

        let loopFormatter = NumberFormatter()
        loopFormatter.numberStyle = .none
        loopFormatter.allowsFloats = false
        loopFormatter.minimum = 0
        loopFormatter.maximum = 65535

        delayField = NSTextField(string: delayFormatter.string(from: delay as NSNumber) ?? "1")
        delayField.formatter = delayFormatter
        loopField = NSTextField(string: loopFormatter.string(from: loops as NSNumber) ?? "0")
        loopField.formatter = loopFormatter

        let title = NSTextField(labelWithString: "Animated GIF")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Delay (seconds):"), delayField],
            [NSTextField(labelWithString: "Loops:"), loopField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        delayField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        loopField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let hint = NSTextField(labelWithString: "Delay is how long each frame stays on screen. 0 loops plays forever.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view = stack
    }

    /// Reads the fields, falling back to the defaults for anything left empty,
    /// and remembers the values for next time.
    func commit() -> (delay: Double, loopCount: Int) {
        let delay = (delayField.objectValue as? NSNumber)?.doubleValue ?? 1.0
        let loops = (loopField.objectValue as? NSNumber)?.intValue ?? 0
        UserDefaults.standard.set(delay, forKey: Self.delayKey)
        UserDefaults.standard.set(loops, forKey: Self.loopCountKey)
        return (delay, loops)
    }
}

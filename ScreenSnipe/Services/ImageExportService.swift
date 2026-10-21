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

    /// Saves every frame of a series as one multi-page TIFF or PDF, or an
    /// animated GIF.
    ///
    /// TIFF is offered here rather than used as the library's storage format:
    /// appending a frame to a multi-page TIFF means rewriting the whole file
    /// with every frame resident in memory, and it is far larger than PNG.
    /// Handing the whole series to someone else is where one file earns its keep.
    /// The format picked in the panel's Format popup decides the scope: PNG
    /// and JPEG write the frame currently open in the editor, TIFF, PDF, and
    /// GIF write the whole series as one file. `allFrames` is only consulted for the latter, so picking
    /// PNG never pays the cost of loading every frame.
    static func saveSeries(
        currentFrame: SeriesExportFrame,
        allFrames: () -> [SeriesExportFrame],
        defaultName: String? = nil
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName ?? "Series"
        panel.canCreateDirectories = true

        let accessory = SeriesExportAccessory(panel: panel)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format = accessory.commit()
        guard format.savesAllFrames else {
            let flattened = flatten(
                image: currentFrame.image,
                annotations: currentFrame.annotations,
                cropRect: currentFrame.cropRect
            )
            write(flattened, to: url)
            return
        }

        let frames = allFrames()
        guard !frames.isEmpty else { return }
        let flattened = frames.map {
            flatten(image: $0.image, annotations: $0.annotations, cropRect: $0.cropRect)
        }
        do {
            switch format {
            case .pdf:
                try writePDF(flattened, to: url)
            case .gif:
                try writeAnimatedGIF(flattened, delay: accessory.gifDelay, loopCount: accessory.gifLoopCount, to: url)
            default:
                try writeMultiPageTIFF(flattened, to: url)
            }
        } catch {
            ErrorReporter.report(error, context: "Failed to save series")
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

/// The file formats a series can be saved in.
private enum SeriesExportFormat: String, CaseIterable {
    case tiff, pdf, gif, png, jpeg

    var title: String {
        switch self {
        case .tiff: "TIFF"
        case .pdf: "PDF"
        case .gif: "Animated GIF"
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }

    var contentType: UTType {
        switch self {
        case .tiff: .tiff
        case .pdf: .pdf
        case .gif: .gif
        case .png: .png
        case .jpeg: .jpeg
        }
    }

    /// TIFF, PDF, and GIF hold every frame in one file. PNG and JPEG hold a
    /// single image, so they save the frame open in the editor.
    var savesAllFrames: Bool {
        switch self {
        case .tiff, .pdf, .gif: true
        case .png, .jpeg: false
        }
    }
}

/// The controls under the series save panel: a Format popup, and the animated
/// GIF fields, which only show while GIF is picked. Picking a format changes
/// the file name's extension. The last format and GIF values used are
/// remembered so a repeat export does not need choosing again.
@MainActor
private final class SeriesExportAccessory: NSObject {
    private static let formatKey = "seriesExportFormat"
    private static let delayKey = "seriesGIFFrameDelay"
    private static let loopCountKey = "seriesGIFLoopCount"

    private weak var panel: NSSavePanel?
    private let stack: NSStackView
    private let formatPopup: NSPopUpButton
    private let gifHint: NSTextField
    private let delayField: NSTextField
    private let loopField: NSTextField
    private let fixedWidth: CGFloat

    private var format: SeriesExportFormat {
        SeriesExportFormat.allCases[formatPopup.indexOfSelectedItem]
    }

    /// Seconds each GIF frame stays on screen.
    var gifDelay: Double {
        (delayField.objectValue as? NSNumber)?.doubleValue ?? 1.0
    }

    /// How many times the GIF plays; 0 loops forever.
    var gifLoopCount: Int {
        (loopField.objectValue as? NSNumber)?.intValue ?? 0
    }

    init(panel: NSSavePanel) {
        self.panel = panel
        let defaults = UserDefaults.standard
        let savedFormat = defaults.string(forKey: Self.formatKey).flatMap(SeriesExportFormat.init) ?? .tiff
        let delay = defaults.object(forKey: Self.delayKey) as? Double ?? 1.0
        let loops = defaults.object(forKey: Self.loopCountKey) as? Int ?? 0

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: SeriesExportFormat.allCases.map(\.title))
        formatPopup.selectItem(at: SeriesExportFormat.allCases.firstIndex(of: savedFormat) ?? 0)

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
        delayField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        loopField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Format:"), formatPopup],
            [NSTextField(labelWithString: "Delay (seconds):"), delayField],
            [NSTextField(labelWithString: "Loops:"), loopField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        // The GIF rows share the grid with Format so their labels line up.
        gifHint = NSTextField(labelWithString: "Delay is how long each frame stays on screen. 0 loops plays forever.")
        gifHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        gifHint.textColor = .secondaryLabelColor

        stack = NSStackView(views: [grid, gifHint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)

        // Sized with the GIF rows showing, the widest layout, and kept at that
        // width so the Format popup does not shift when the rows hide.
        fixedWidth = stack.fittingSize.width

        super.init()

        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        applyFormat()
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        applyFormat()
    }

    /// Updates the panel's file type and extension, and which fields are
    /// visible to match the selected format.
    private func applyFormat() {
        guard let panel else { return }
        let format = self.format

        panel.allowedContentTypes = [format.contentType]
        if let ext = format.contentType.preferredFilenameExtension {
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(ext)"
        }

        let showsGIF = format == .gif
        if let grid = stack.arrangedSubviews.first as? NSGridView {
            grid.row(at: 1).isHidden = !showsGIF
            grid.row(at: 2).isHidden = !showsGIF
        }
        gifHint.isHidden = !showsGIF

        // The panel only lays out its accessory when it is assigned, so the
        // view is reassigned after its size changes.
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(x: 0, y: 0, width: fixedWidth, height: stack.fittingSize.height)
        panel.accessoryView = nil
        panel.accessoryView = stack
    }

    /// Remembers the chosen format and GIF values for next time and returns
    /// the format to save in.
    func commit() -> SeriesExportFormat {
        let defaults = UserDefaults.standard
        defaults.set(format.rawValue, forKey: Self.formatKey)
        if format == .gif {
            defaults.set(gifDelay, forKey: Self.delayKey)
            defaults.set(gifLoopCount, forKey: Self.loopCountKey)
        }
        return format
    }
}

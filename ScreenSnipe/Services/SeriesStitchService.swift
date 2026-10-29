import Foundation
import ImageIO

/// Builds a new series out of screenshots and series frames.
///
/// Nothing is flattened. Each image is copied as it is, next to a copy of its
/// annotation sidecar, so annotations and crops stay editable in the new
/// series exactly as they were in the originals. The originals are not changed.
///
/// The frames are written into a staging folder whose name is not a library
/// timestamp, so `LibraryManager.reload()` ignores it until
/// `LibraryManager.publishStitchedSeries` moves it into place.
enum SeriesStitchService {

    enum SeriesStitchError: LocalizedError {
        case noFrames
        case unreadableImage(String)

        var errorDescription: String? {
            switch self {
            case .noFrames: "The selected items have no images to stitch."
            case .unreadableImage(let name): "Could not read the image \(name)."
            }
        }
    }

    /// Copies `frames` into `folderURL` and returns the manifest describing
    /// them. Removes the folder if it fails or is cancelled.
    static func stitch(
        frames: [SeriesStitchFrame],
        target: SeriesManifest.Target?,
        into folderURL: URL,
        progress: @Sendable (Double) -> Void
    ) throws -> SeriesManifest {
        guard !frames.isEmpty else { throw SeriesStitchError.noFrames }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folderURL.appendingPathComponent("frames"), withIntermediateDirectories: true)

            var manifestFrames: [SeriesManifest.Frame] = []
            for (position, source) in frames.enumerated() {
                try Task.checkCancellation()

                // Indices start at 1, matching how a captured series numbers
                // its frames.
                let index = position + 1
                let filePath = SeriesManifest.frameFileName(index: index)
                let annotationsPath = SeriesManifest.annotationsFileName(index: index)

                // A copy on the same volume is a clone on APFS, so even large
                // frames take almost no time or space.
                try fm.copyItem(at: source.imageURL, to: folderURL.appendingPathComponent(filePath))
                let annotationsURL = folderURL.appendingPathComponent(annotationsPath)
                if fm.fileExists(atPath: source.annotationsURL.path) {
                    try fm.copyItem(at: source.annotationsURL, to: annotationsURL)
                } else {
                    try Data("[]".utf8).write(to: annotationsURL, options: .atomic)
                }

                let (pixelSize, pointSize) = try sizes(of: source)
                manifestFrames.append(SeriesManifest.Frame(
                    index: index,
                    file: filePath,
                    annotations: annotationsPath,
                    capturedAt: source.capturedAt,
                    pixelWidth: pixelSize.width,
                    pixelHeight: pixelSize.height,
                    pointWidth: pointSize.width,
                    pointHeight: pointSize.height
                ))
                progress(Double(index) / Double(frames.count))
            }

            let first = manifestFrames[0]
            return SeriesManifest(
                createdAt: Date(),
                // The target is only kept for diagnostics. Screenshots do not
                // record one, so a stitch made only of screenshots describes
                // its first frame as a region.
                target: target ?? .region(x: 0, y: 0, width: first.pointWidth, height: first.pointHeight),
                displayScale: first.pointWidth > 0 ? CGFloat(first.pixelWidth) / first.pointWidth : 1,
                frames: manifestFrames,
                complete: true
            )
        } catch {
            try? fm.removeItem(at: folderURL)
            throw error
        }
    }

    /// Series frames carry their sizes in the manifest. For a screenshot they
    /// come from the PNG: the pixel size, and the point size from its DPI the
    /// same way `NSImage` would compute it.
    private static func sizes(of frame: SeriesStitchFrame) throws -> (pixels: (width: Int, height: Int), points: CGSize) {
        if let pixelSize = frame.pixelSize, let pointSize = frame.pointSize {
            return (pixelSize, pointSize)
        }
        guard let imageSource = CGImageSourceCreateWithURL(frame.imageURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw SeriesStitchError.unreadableImage(frame.imageURL.lastPathComponent)
        }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = dpi > 0 ? 72 / dpi : 1
        return ((width, height), CGSize(width: Double(width) * scale, height: Double(height) * scale))
    }
}

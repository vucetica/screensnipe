import Foundation
import CoreMedia

/// One resolved piece of media to append to a stitched video.
///
/// Library entries are flattened into sources before stitching, which is what
/// lets a series contribute one image per frame while the rest of the pipeline
/// stays unaware that series exist.
struct StitchSource: Sendable {
    enum Kind: Sendable {
        case image
        case video
    }

    let kind: Kind
    let url: URL
    /// Entry id (plus frame index for series frames), used in diagnostics.
    let id: String
    /// Stored trim for a video source; nil for images and untrimmed videos.
    ///
    /// A `VideoTrimRange` rather than a `CMTimeRange` so the source stays
    /// trivially `Sendable`; it converts at the point of use in `StitchService`.
    let trim: VideoTrimRange?

    init(kind: Kind, url: URL, id: String, trim: VideoTrimRange? = nil) {
        self.kind = kind
        self.url = url
        self.id = id
        self.trim = trim
    }

    var timeRange: CMTimeRange? { trim?.timeRange }
}

struct StitchConfiguration: Sendable {
    /// What a stitch produces.
    enum Output: Sendable {
        /// One video, with images shown for `imageDurationSeconds` each.
        case video
        /// A new series with one frame per image, keeping each frame's
        /// annotations and crop editable.
        case series
    }

    var items: [LibraryEntry]
    var pauseDurationSeconds: Double
    var imageDurationSeconds: Double
    var output: Output = .video

    /// A series can only hold images, so stitching into one is offered only
    /// when no recording is selected.
    static func canStitchAsSeries(_ entries: [LibraryEntry]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { $0.mediaType != .video }
    }

    /// Expands entries into playable sources, turning each series into its
    /// ordered frames.
    func resolvedSources() -> [StitchSource] {
        var sources: [StitchSource] = []
        for entry in items {
            switch entry.mediaType {
            case .image:
                if let url = entry.mediaURL {
                    sources.append(StitchSource(kind: .image, url: url, id: entry.id))
                }
            case .video:
                if let url = entry.mediaURL {
                    // A field read, not a disk read: metadata.json is already
                    // loaded for every entry, which is what lets this stay
                    // synchronous and non-throwing.
                    sources.append(StitchSource(kind: .video, url: url, id: entry.id, trim: entry.metadata.trim))
                }
            case .series:
                guard let manifest = try? SeriesManifest.load(from: entry.seriesManifestURL) else { continue }
                for frame in manifest.frames {
                    sources.append(StitchSource(
                        kind: .image,
                        url: entry.url(forFramePath: frame.file),
                        id: "\(entry.id)#\(frame.index)"
                    ))
                }
            }
        }
        return sources
    }
}

/// One frame to copy into a stitched series.
struct SeriesStitchFrame: Sendable {
    let imageURL: URL
    /// The annotation sidecar that goes with the image. A missing file becomes
    /// an empty sidecar in the new series.
    let annotationsURL: URL
    let capturedAt: Date
    /// Known for series frames from their manifest. Nil for screenshots, whose
    /// size is read from the PNG.
    let pixelSize: (width: Int, height: Int)?
    let pointSize: CGSize?
}

extension StitchConfiguration {
    /// The frames a series stitch copies, in order, plus the capture target of
    /// the first series among the items, which the new manifest reuses.
    func resolvedSeriesFrames() -> (frames: [SeriesStitchFrame], target: SeriesManifest.Target?) {
        var frames: [SeriesStitchFrame] = []
        var target: SeriesManifest.Target?
        for entry in items {
            switch entry.mediaType {
            case .image:
                guard let url = entry.mediaURL else { continue }
                frames.append(SeriesStitchFrame(
                    imageURL: url,
                    annotationsURL: entry.annotationsURL,
                    capturedAt: entry.captureDate,
                    pixelSize: nil,
                    pointSize: nil
                ))
            case .series:
                guard let manifest = try? SeriesManifest.load(from: entry.seriesManifestURL) else { continue }
                target = target ?? manifest.target
                for frame in manifest.frames {
                    frames.append(SeriesStitchFrame(
                        imageURL: entry.url(forFramePath: frame.file),
                        annotationsURL: entry.url(forFramePath: frame.annotations),
                        capturedAt: frame.capturedAt,
                        pixelSize: (frame.pixelWidth, frame.pixelHeight),
                        pointSize: CGSize(width: frame.pointWidth, height: frame.pointHeight)
                    ))
                }
            case .video:
                continue
            }
        }
        return (frames, target)
    }
}

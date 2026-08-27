import Foundation

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
}

struct StitchConfiguration: Sendable {
    var items: [LibraryEntry]
    var pauseDurationSeconds: Double
    var imageDurationSeconds: Double

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
                    sources.append(StitchSource(kind: .video, url: url, id: entry.id))
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

import Foundation

enum MediaType: String, Sendable {
    case image
    case video
    case series

    var iconName: String {
        switch self {
        case .image: "photo"
        case .video: "video"
        case .series: "rectangle.stack"
        }
    }

    /// Label shown in the sidebar row and the stitch dialog.
    var displayName: String {
        switch self {
        case .image: "Screenshot"
        case .video: "Recording"
        case .series: "Series"
        }
    }

    /// Prefix used to build a default export name.
    var exportPrefix: String {
        switch self {
        case .image: "Screenshot"
        case .video: "Recording"
        case .series: "Series"
        }
    }
}

struct CaptureMetadata: Codable, Sendable, Equatable {
    var name: String?
    var description: String?
    var tags: [String] = []
    /// Public iCloud link published for this capture, if any.
    var shareURL: URL?
    /// Date after which the published iCloud link stops working (system-determined).
    var shareExpiration: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case tags
        case shareURL
        case shareExpiration
    }

    init(name: String? = nil, description: String? = nil, tags: [String] = []) {
        self.name = name
        self.description = description
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.shareURL = try container.decodeIfPresent(URL.self, forKey: .shareURL)
        self.shareExpiration = try container.decodeIfPresent(Date.self, forKey: .shareExpiration)
    }
}

struct LibraryEntry: Identifiable, Sendable, Equatable {
    let id: String
    let folderURL: URL
    let captureDate: Date
    let mediaType: MediaType
    var metadata: CaptureMetadata

    var name: String? { metadata.name }

    /// The single file that *is* this capture.
    ///
    /// `nil` for `.series`, which has no canonical single file: use
    /// `seriesManifestURL` and resolve frame paths through the manifest.
    /// Returning the first frame instead would be a lie once that frame is
    /// deleted, and returning `folderURL` makes `NSImage(contentsOf:)` fail
    /// silently.
    var mediaURL: URL? {
        switch mediaType {
        case .image:
            folderURL.appendingPathComponent("screenshot.png")
        case .video:
            folderURL.appendingPathComponent("recording.mp4")
        case .series:
            nil
        }
    }

    var seriesManifestURL: URL {
        folderURL.appendingPathComponent("series.json")
    }

    var framesDirectoryURL: URL {
        folderURL.appendingPathComponent("frames")
    }

    /// Absolute URL for a manifest-relative frame path.
    func url(forFramePath path: String) -> URL {
        folderURL.appendingPathComponent(path)
    }

    var annotationsURL: URL {
        folderURL.appendingPathComponent("annotations.json")
    }

    var metadataURL: URL {
        folderURL.appendingPathComponent("metadata.json")
    }

    var thumbnailURL: URL {
        folderURL.appendingPathComponent("thumbnail.png")
    }
}

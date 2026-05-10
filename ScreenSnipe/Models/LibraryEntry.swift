import Foundation

enum MediaType: String, Sendable {
    case image
    case video
}

struct CaptureMetadata: Codable, Sendable, Equatable {
    var name: String?
    var description: String?
}

struct LibraryEntry: Identifiable, Sendable, Equatable {
    let id: String
    let folderURL: URL
    let captureDate: Date
    let mediaType: MediaType
    var metadata: CaptureMetadata

    var name: String? { metadata.name }

    var mediaURL: URL {
        switch mediaType {
        case .image:
            folderURL.appendingPathComponent("screenshot.png")
        case .video:
            folderURL.appendingPathComponent("recording.mp4")
        }
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

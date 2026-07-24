import Foundation

enum MediaType: String, Sendable {
    case image
    case video
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

import Foundation
import AppKit
import AVFoundation

@MainActor
final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    @Published var entries: [LibraryEntry] = []

    private static let bookmarkKey = "libraryBookmark"
    private static let dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"

    private var securityScopedURL: URL?

    var hasLibraryLocation: Bool {
        resolveBookmark() != nil
    }

    var libraryURL: URL? {
        get {
            resolveBookmark()
        }
        set {
            stopAccessing()
            if let newValue {
                saveBookmark(for: newValue)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            }
            startAccessing()
            reload()
        }
    }

    private init() {
        startAccessing()
        reload()
    }

    // MARK: - Security-Scoped Bookmarks

    private func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            saveBookmark(for: url)
        }
        return url
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    func startAccessing() {
        guard let url = resolveBookmark() else { return }
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
    }

    func stopAccessing() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Library Location Prompt

    /// Shows an NSOpenPanel for the user to choose a library folder.
    @discardableResult
    func promptForLibraryLocation() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.prompt = "Choose"
        panel.message = "Select a folder for the Screen Snipe library"
        panel.nameFieldStringValue = "Screen Snipe"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        libraryURL = url
        return url
    }

    /// Ensures the library directory exists and is writable. Returns true on success.
    /// Prompts the user to choose a location if none has been set.
    func ensureLibraryLocation() async -> Bool {
        if libraryURL == nil {
            guard promptForLibraryLocation() != nil else { return false }
        }
        guard let url = libraryURL else { return false }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }
        return fm.isWritableFile(atPath: url.path)
    }

    // MARK: - Scanning

    func reload() {
        let fm = FileManager.default
        guard let baseURL = libraryURL else {
            entries = []
            return
        }

        guard fm.fileExists(atPath: baseURL.path) else {
            entries = []
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = Self.dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var result: [LibraryEntry] = []

        guard let contents = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            entries = []
            return
        }

        for folderURL in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let folderName = folderURL.lastPathComponent
            guard let date = formatter.date(from: folderName) else { continue }

            let imageURL = folderURL.appendingPathComponent("screenshot.png")
            let videoURL = folderURL.appendingPathComponent("recording.mp4")

            let mediaType: MediaType
            if fm.fileExists(atPath: videoURL.path) {
                mediaType = .video
            } else if fm.fileExists(atPath: imageURL.path) {
                mediaType = .image
            } else {
                continue
            }

            let metadata = Self.loadMetadata(from: folderURL)
            result.append(LibraryEntry(
                id: folderName,
                folderURL: folderURL,
                captureDate: date,
                mediaType: mediaType,
                metadata: metadata
            ))
        }

        entries = result.sorted { $0.captureDate > $1.captureDate }
    }

    // MARK: - Save Image

    func saveImage(_ image: NSImage) throws -> LibraryEntry {
        guard let baseURL = libraryURL else {
            throw NSError(domain: "LibraryManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No library location set"])
        }
        let fm = FileManager.default
        let folderName = Self.timestampString()
        let folderURL = baseURL.appendingPathComponent(folderName)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let imageURL = folderURL.appendingPathComponent("screenshot.png")
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "LibraryManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to PNG"])
        }
        try pngData.write(to: imageURL)

        let annotationsURL = folderURL.appendingPathComponent("annotations.json")
        try Data("[]".utf8).write(to: annotationsURL)

        let thumbnailURL = folderURL.appendingPathComponent("thumbnail.png")
        if let thumbData = generateThumbnail(from: image) {
            try thumbData.write(to: thumbnailURL)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = Self.dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let entry = LibraryEntry(
            id: folderName,
            folderURL: folderURL,
            captureDate: formatter.date(from: folderName) ?? Date(),
            mediaType: .image,
            metadata: CaptureMetadata()
        )

        entries.insert(entry, at: 0)
        return entry
    }

    // MARK: - Save Video

    func saveVideo(from tempURL: URL) throws -> LibraryEntry {
        guard let baseURL = libraryURL else {
            throw NSError(domain: "LibraryManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No library location set"])
        }
        let fm = FileManager.default
        let folderName = Self.timestampString()
        let folderURL = baseURL.appendingPathComponent(folderName)
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let videoURL = folderURL.appendingPathComponent("recording.mp4")
        try fm.moveItem(at: tempURL, to: videoURL)

        let annotationsURL = folderURL.appendingPathComponent("annotations.json")
        try Data("[]".utf8).write(to: annotationsURL)

        let thumbnailURL = folderURL.appendingPathComponent("thumbnail.png")
        if let thumbData = generateVideoThumbnail(from: videoURL) {
            try thumbData.write(to: thumbnailURL)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = Self.dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let entry = LibraryEntry(
            id: folderName,
            folderURL: folderURL,
            captureDate: formatter.date(from: folderName) ?? Date(),
            mediaType: .video,
            metadata: CaptureMetadata()
        )

        entries.insert(entry, at: 0)
        return entry
    }

    // MARK: - Annotations

    func loadAnnotations(for entry: LibraryEntry) throws -> (annotations: [AnyAnnotation], cropRect: CGRect?, magnification: CGFloat?) {
        let data = try Data(contentsOf: entry.annotationsURL)
        guard !data.isEmpty else { return ([], nil, nil) }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" { return ([], nil, nil) }
        return try AnnotationSerializer.deserialize(data)
    }

    func saveAnnotations(_ annotations: [AnyAnnotation], cropRect: CGRect? = nil, magnification: CGFloat? = nil, for entry: LibraryEntry) throws {
        let data = try AnnotationSerializer.serialize(annotations, cropRect: cropRect, magnification: magnification)
        try data.write(to: entry.annotationsURL, options: .atomic)
    }

    // MARK: - Metadata

    private static func loadMetadata(from folderURL: URL) -> CaptureMetadata {
        let url = folderURL.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(CaptureMetadata.self, from: data) else {
            return CaptureMetadata()
        }
        return metadata
    }

    func saveMetadata(_ metadata: CaptureMetadata, for entry: LibraryEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: entry.metadataURL, options: .atomic)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].metadata = metadata
        }
    }

    // MARK: - Delete

    func delete(entry: LibraryEntry) throws {
        try FileManager.default.removeItem(at: entry.folderURL)
        entries.removeAll { $0.id == entry.id }
    }

    // MARK: - Thumbnails

    private func generateThumbnail(from image: NSImage) -> Data? {
        let maxDim: CGFloat = 200
        let aspect = image.size.width / image.size.height
        let thumbSize: NSSize
        if aspect > 1 {
            thumbSize = NSSize(width: maxDim, height: maxDim / aspect)
        } else {
            thumbSize = NSSize(width: maxDim * aspect, height: maxDim)
        }

        let thumbImage = NSImage(size: thumbSize)
        thumbImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        thumbImage.unlockFocus()

        guard let tiffData = thumbImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }

    private nonisolated func generateVideoThumbnail(from url: URL) -> Data? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)

        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }

    // MARK: - Helpers

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }
}

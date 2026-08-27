import Foundation
import AppKit
import AVFoundation

@MainActor
final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    @Published var entries: [LibraryEntry] = [] {
        didSet { rebuildTagIndex() }
    }
    @Published private(set) var allTags: [String] = []

    private static let bookmarkKey = "libraryBookmark"
    private static let dateFormat = "yyyy-MM-dd-HH-mm-ss-SSS"

    private var securityScopedURL: URL?

    /// Folder name of a series being captured right now. Skipped by `reload()`
    /// so a half-finished session never appears in the sidebar. Cleared when the
    /// session finishes or is cancelled. A folder left behind by a crash is
    /// deliberately still picked up on the next launch, because the manifest is
    /// rewritten after every frame.
    var inProgressSeriesID: String?

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
            if folderName == inProgressSeriesID { continue }

            let imageURL = folderURL.appendingPathComponent("screenshot.png")
            let videoURL = folderURL.appendingPathComponent("recording.mp4")
            let seriesURL = folderURL.appendingPathComponent("series.json")

            // Existence check only. reload() is @MainActor and runs over every
            // folder on init, on library relocation, and on every refresh, so
            // the manifest is decoded lazily on selection instead.
            let mediaType: MediaType
            if fm.fileExists(atPath: seriesURL.path) {
                mediaType = .series
            } else if fm.fileExists(atPath: videoURL.path) {
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

    // MARK: - Series

    /// Reserves a timestamped folder for a new series session and hides it from
    /// the sidebar until the session finishes.
    ///
    /// Frames are written incrementally rather than buffered: a full-screen 2x
    /// frame is ~120 MB as a bitmap, so a 30-frame series held in memory would
    /// be multiple gigabytes. Incremental writes also make a crash recoverable
    /// and make cancellation a single directory removal.
    func beginSeries() throws -> (id: String, folderURL: URL) {
        guard let baseURL = libraryURL else {
            throw NSError(domain: "LibraryManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No library location set"])
        }
        let folderName = Self.timestampString()
        let folderURL = baseURL.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folderURL.appendingPathComponent("frames"), withIntermediateDirectories: true)
        inProgressSeriesID = folderName
        return (folderName, folderURL)
    }

    /// Writes the thumbnail for a series (taken from its first frame).
    func writeSeriesThumbnail(from image: NSImage, to folderURL: URL) throws {
        guard let data = generateThumbnail(from: image) else { return }
        try data.write(to: folderURL.appendingPathComponent("thumbnail.png"), options: .atomic)
    }

    /// Publishes a finished series into the library.
    func finalizeSeries(id: String, folderURL: URL, manifest: SeriesManifest) throws -> LibraryEntry {
        var manifest = manifest
        manifest.complete = true
        try manifest.write(to: folderURL.appendingPathComponent("series.json"))
        inProgressSeriesID = nil

        let formatter = DateFormatter()
        formatter.dateFormat = Self.dateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let entry = LibraryEntry(
            id: id,
            folderURL: folderURL,
            captureDate: formatter.date(from: id) ?? Date(),
            mediaType: .series,
            metadata: CaptureMetadata()
        )
        entries.insert(entry, at: 0)
        return entry
    }

    /// Discards an in-progress series and everything captured for it.
    func discardSeries(id: String, folderURL: URL) {
        inProgressSeriesID = nil
        try? FileManager.default.removeItem(at: folderURL)
    }

    func loadSeriesManifest(for entry: LibraryEntry) throws -> SeriesManifest {
        try SeriesManifest.load(from: entry.seriesManifestURL)
    }

    func saveSeriesManifest(_ manifest: SeriesManifest, for entry: LibraryEntry) throws {
        try manifest.write(to: entry.seriesManifestURL)
    }

    // MARK: - Annotations

    func loadAnnotations(for entry: LibraryEntry) throws -> (annotations: [AnyAnnotation], cropRect: CGRect?, magnification: CGFloat?) {
        try loadAnnotations(at: entry.annotationsURL)
    }

    /// Loads an annotation sidecar from an explicit URL. Series frames each have
    /// their own sidecar next to their PNG, so they cannot go through the
    /// entry-addressed overload.
    func loadAnnotations(at url: URL) throws -> (annotations: [AnyAnnotation], cropRect: CGRect?, magnification: CGFloat?) {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return ([], nil, nil) }
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" { return ([], nil, nil) }
        return try AnnotationSerializer.deserialize(data)
    }

    func saveAnnotations(_ annotations: [AnyAnnotation], cropRect: CGRect? = nil, magnification: CGFloat? = nil, for entry: LibraryEntry) throws {
        try saveAnnotations(annotations, cropRect: cropRect, magnification: magnification, to: entry.annotationsURL)
    }

    func saveAnnotations(_ annotations: [AnyAnnotation], cropRect: CGRect? = nil, magnification: CGFloat? = nil, to url: URL) throws {
        let data = try AnnotationSerializer.serialize(annotations, cropRect: cropRect, magnification: magnification)
        try data.write(to: url, options: .atomic)
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

    // MARK: - Tag Index

    private func rebuildTagIndex() {
        var seen: [String: String] = [:]
        for entry in entries {
            for tag in entry.metadata.tags {
                let key = tag.lowercased()
                if seen[key] == nil {
                    seen[key] = tag
                }
            }
        }
        allTags = seen.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

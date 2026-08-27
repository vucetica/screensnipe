import Foundation

/// On-disk description of a series capture.
///
/// The manifest is the source of truth for frame order and frame count; the PNG
/// files themselves are opaque. Frame indices are allocated once and never
/// renumbered, so deleting a frame removes one array element and leaves the
/// remaining files untouched on disk. Deriving paths from ordinal position
/// instead would force a rename cascade of every PNG and its JSON sibling on
/// each deletion, which is exactly the operation that fails halfway and leaves
/// annotations attached to the wrong image.
struct SeriesManifest: Codable, Sendable, Equatable {
    static let currentVersion = 1

    struct Frame: Codable, Sendable, Equatable, Identifiable {
        /// Monotonic, allocated once, never reused or renumbered.
        let index: Int
        /// Path relative to the entry folder, e.g. "frames/frame-001.png".
        let file: String
        /// Path relative to the entry folder, e.g. "frames/frame-001.json".
        let annotations: String
        let capturedAt: Date
        let pixelWidth: Int
        let pixelHeight: Int
        let pointWidth: CGFloat
        let pointHeight: CGFloat

        var id: Int { index }
    }

    enum Target: Codable, Sendable, Equatable {
        case fullScreen(displayID: UInt32)
        case region(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
        case window(windowID: UInt32, appName: String?, title: String?)
    }

    var version: Int = Self.currentVersion
    var createdAt: Date
    var target: Target
    /// Backing scale factor of the capture display, kept for diagnostics.
    var displayScale: CGFloat
    /// Ordered. Source of truth for frame order and count.
    var frames: [Frame]
    /// False while a session is live. A `false` value that survives a crash
    /// still yields a usable entry, since the manifest is rewritten per frame.
    var complete: Bool

    // MARK: - Coding

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load(from url: URL) throws -> SeriesManifest {
        try makeDecoder().decode(SeriesManifest.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        try Self.makeEncoder().encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Frame Naming

    static func frameFileName(index: Int) -> String {
        "frames/frame-\(String(format: "%03d", index)).png"
    }

    static func annotationsFileName(index: Int) -> String {
        "frames/frame-\(String(format: "%03d", index)).json"
    }

    // MARK: - Lookup

    func frame(at index: Int) -> Frame? {
        frames.first { $0.index == index }
    }

    /// Position of a frame index within the ordered list, for "Frame N of M".
    func position(of index: Int) -> Int? {
        frames.firstIndex { $0.index == index }
    }
}

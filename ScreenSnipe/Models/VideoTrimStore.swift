import Foundation
import AVFoundation
import Combine

/// Trim selection for the video entry currently open in the library.
///
/// Deliberately separate from `AnnotationStore`. The trim is movie-time state
/// persisted to a different sidecar (`metadata.json` rather than
/// `annotations.json`), and folding it into the annotation undo stack would put
/// it behind a toolbar Undo that is gated on `selectedImage != nil`, so it would
/// be unreachable for the videos it applies to. "Reset Trim" in the trim bar is
/// the escape hatch instead.
@MainActor
final class VideoTrimStore: ObservableObject {
    /// Shortest selection the handles can produce: two frames at 30 fps.
    static let minimumDuration = CMTime(value: 2, timescale: 30)

    /// nil means no trim is stored, which is the whole asset.
    @Published private(set) var trim: VideoTrimRange?
    /// `.invalid` until the asset's duration has loaded.
    @Published private(set) var assetDuration: CMTime = .invalid
    /// True while a handle is under the mouse.
    @Published private(set) var isDragging = false

    private(set) var entryID: String?

    /// Set while `load` is swapping contents in, so the view model's autosave
    /// subscription does not write a freshly loaded value straight back to disk.
    private(set) var isLoading = false

    private var durationTask: Task<Void, Never>?

    var isReady: Bool { assetDuration.isValid && assetDuration > .zero }
    var hasTrim: Bool { trim != nil }

    /// The selection to draw and to bound playback with: the stored trim, or the
    /// whole asset when there is none.
    var effectiveRange: CMTimeRange? {
        guard isReady else { return nil }
        return trim?.timeRange ?? CMTimeRange(start: .zero, duration: assetDuration)
    }

    /// The range export paths should apply, nil when there is nothing to cut.
    var exportRange: CMTimeRange? { trim?.timeRange }

    // MARK: - Loading

    func load(entry: LibraryEntry) {
        durationTask?.cancel()
        entryID = entry.id
        isLoading = true
        trim = entry.metadata.trim
        assetDuration = .invalid
        isLoading = false
        isDragging = false

        guard entry.mediaType == .video, let url = entry.mediaURL else { return }
        let id = entry.id
        durationTask = Task { [weak self] in
            let duration = try? await AVURLAsset(url: url).load(.duration)
            // A late duration must never land on an entry the user has since
            // navigated away from.
            guard let self, !Task.isCancelled, self.entryID == id else { return }
            self.isLoading = true
            self.assetDuration = duration ?? .zero
            self.trim = self.trim?.clamped(
                toAssetDuration: self.assetDuration,
                minimum: Self.minimumDuration
            )
            self.isLoading = false
        }
    }

    func unload() {
        durationTask?.cancel()
        durationTask = nil
        entryID = nil
        isLoading = true
        trim = nil
        assetDuration = .invalid
        isDragging = false
        isLoading = false
    }

    // MARK: - Mutations

    /// Both setters always write a concrete range, even when it happens to cover
    /// the whole asset. That keeps the drag math free of nil-punning; a
    /// full-asset range collapses back to nil in `VideoTrimRange.clamped`.
    func setStart(_ time: CMTime) {
        guard let current = effectiveRange else { return }
        let upper = current.end - Self.minimumDuration
        let clamped = min(max(time, .zero), max(upper, .zero))
        trim = VideoTrimRange(start: clamped, end: current.end)
    }

    func setEnd(_ time: CMTime) {
        guard let current = effectiveRange else { return }
        let lower = current.start + Self.minimumDuration
        let clamped = max(min(time, assetDuration), lower)
        trim = VideoTrimRange(start: current.start, end: clamped)
    }

    func reset() {
        guard trim != nil else { return }
        trim = nil
    }

    func beginDrag() { isDragging = true }
    func endDrag() { isDragging = false }
}

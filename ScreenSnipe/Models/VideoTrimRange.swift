import Foundation
import CoreMedia

/// Codable mirror of `CMTime`.
///
/// Stores the rational parts rather than a `Double` of seconds so a trim
/// round-trips to the exact sample boundary the user picked. One frame at 30 fps
/// is 1/30 of a second, which has no exact binary representation, so a seconds
/// round-trip would drift the cut by a fraction of a frame on every save.
struct CodableCMTime: Codable, Sendable, Equatable, Hashable {
    let value: Int64
    let timescale: CMTimeScale

    init(_ time: CMTime) {
        let resolved = time.isValid ? time : .zero
        self.value = resolved.value
        self.timescale = resolved.timescale == 0 ? Self.defaultTimescale : resolved.timescale
    }

    init(seconds: Double, preferredTimescale: CMTimeScale = CodableCMTime.defaultTimescale) {
        self.init(CMTime(seconds: seconds, preferredTimescale: preferredTimescale))
    }

    /// 600 is the conventional QuickTime timescale and divides 24, 25, 30 and 60
    /// exactly, so a handle dropped on a frame boundary stays on it.
    static let defaultTimescale: CMTimeScale = 600

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    var seconds: Double { CMTimeGetSeconds(cmTime) }
}

/// A stored, non-destructive time selection over a recording.
///
/// The range is never applied to `recording.mp4`. It lives in the entry's
/// `metadata.json` and the export paths apply it on the way out, which is what
/// lets the user come back later and widen a trim they already made. This is the
/// video counterpart of `AnnotationStore.cropRect` for images.
struct VideoTrimRange: Codable, Sendable, Equatable, Hashable {
    let start: CodableCMTime
    let end: CodableCMTime

    init(start: CMTime, end: CMTime) {
        self.start = CodableCMTime(start)
        self.end = CodableCMTime(end)
    }

    var timeRange: CMTimeRange { CMTimeRange(start: start.cmTime, end: end.cmTime) }
    var duration: CMTime { end.cmTime - start.cmTime }

    /// Clamps the range to what the file on disk actually contains.
    ///
    /// Returns nil when the stored range no longer overlaps the asset (a shorter
    /// re-recording, a hand-edited sidecar) or when it has grown to cover the
    /// whole asset, which is the same thing as having no trim at all. Callers
    /// persist the result, so a stale range heals itself on the next save.
    func clamped(toAssetDuration assetDuration: CMTime, minimum: CMTime) -> VideoTrimRange? {
        guard assetDuration.isValid, assetDuration > .zero else { return nil }
        let hit = timeRange.intersection(CMTimeRange(start: .zero, duration: assetDuration))
        guard hit.duration >= minimum else { return nil }
        if hit.start <= .zero && hit.end >= assetDuration { return nil }
        return VideoTrimRange(start: hit.start, end: hit.end)
    }
}

import AVFoundation
import AppKit

/// Evenly spaced preview frames for the video trim bar.
///
/// Uses the async `images(for:)` sequence rather than the synchronous
/// `copyCGImage` that `LibraryManager.generateVideoThumbnail` uses: a strip needs
/// a dozen frames at once, and decoding each one synchronously would stall the
/// main thread for as long as that takes.
enum VideoFilmstripGenerator {

    /// Frames sampled at the midpoint of `count` equal slices of the asset, so
    /// each thumbnail represents the slice it is drawn over.
    static func frames(
        url: URL,
        duration: CMTime,
        count: Int,
        maxPixelSize: CGFloat
    ) async -> [NSImage] {
        guard count > 0, duration.isValid, duration > .zero else { return [] }
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else { return [] }

        return await Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            // A loose tolerance lets the generator snap to a nearby keyframe
            // instead of decoding forward to an exact time. At strip size the
            // difference is invisible and it is far faster.
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)

            let step = totalSeconds / Double(count)
            let times = (0..<count).map { index in
                CMTime(seconds: (Double(index) + 0.5) * step, preferredTimescale: 600)
            }

            var images: [NSImage] = []
            images.reserveCapacity(count)
            for await result in generator.images(for: times) {
                if Task.isCancelled { break }
                guard let cgImage = try? result.image else { continue }
                images.append(NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                ))
            }
            return images
        }.value
    }
}

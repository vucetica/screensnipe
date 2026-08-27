import SwiftUI
import AppKit
import ImageIO

/// Thumbnail that decodes at thumbnail size instead of full resolution.
///
/// `AsyncThumbnailView` is fine for the sidebar, where the file on disk is
/// already a 200px thumbnail. The series filmstrip points at full frames, and a
/// full-screen 2x frame decodes to well over a hundred megabytes, so a strip of
/// them has to downsample while reading.
struct DownsampledThumbnailView: View {
    let url: URL
    var maxPixelSize: Int = 320

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
            }
        }
        .task(id: url) {
            let target = maxPixelSize
            let source = url
            image = await Task.detached(priority: .utility) {
                Self.downsample(url: source, maxPixelSize: target)
            }.value
        }
    }

    private nonisolated static func downsample(url: URL, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

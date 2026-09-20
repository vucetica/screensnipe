import SwiftUI
import AppKit

struct AsyncThumbnailView: View {
    let url: URL
    /// Bump to force a reload when the file's contents change under a stable
    /// URL. Trimming rewrites `thumbnail.png` in place, and keying the task on
    /// the URL alone would keep showing the old frame until the next launch.
    var version: Int = 0

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
        .task(id: ThumbnailKey(url: url, version: version)) {
            image = NSImage(contentsOf: url)
        }
    }
}

private struct ThumbnailKey: Hashable {
    let url: URL
    let version: Int
}

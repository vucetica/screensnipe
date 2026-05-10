import SwiftUI
import AppKit

struct AsyncThumbnailView: View {
    let url: URL
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
            image = NSImage(contentsOf: url)
        }
    }
}

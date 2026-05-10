import SwiftUI
import AVKit

struct LibraryDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var annotationStore: AnnotationStore

    var body: some View {
        Group {
            if viewModel.selectedEntryIDs.count >= 2 {
                multiSelectionPlaceholder
            } else if let image = viewModel.selectedImage {
                imageEditor(image: image)
            } else if let videoURL = viewModel.selectedVideoURL {
                VideoPlayerView(url: videoURL)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select a capture")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var multiSelectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("\(viewModel.selectedEntryIDs.count) items selected")
                .foregroundStyle(.secondary)
            Button("Stitch Together...") {
                viewModel.beginStitch()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func imageEditor(image: NSImage) -> some View {
        CanvasRepresentable(image: image, store: annotationStore, activeTool: $viewModel.activeTool)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Video Player (NSViewRepresentable)

/// Custom NSViewRepresentable wrapping AVPlayerView directly.
/// Avoids _AVKit_SwiftUI framework which crashes on macOS 26.3
/// during class metadata initialization in TestFlight/Release builds.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.player = AVPlayer(url: url)
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        let currentURL = (playerView.player?.currentItem?.asset as? AVURLAsset)?.url
        guard currentURL != url else { return }
        playerView.player?.pause()
        playerView.player = AVPlayer(url: url)
    }
}

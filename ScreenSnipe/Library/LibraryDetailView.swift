import SwiftUI
import AVKit

struct LibraryDetailView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var annotationStore: AnnotationStore
    @ObservedObject var trimStore: VideoTrimStore
    @ObservedObject var playback: VideoPlaybackController

    var body: some View {
        Group {
            if viewModel.selectedEntryIDs.count >= 2 {
                multiSelectionPlaceholder
            } else if let image = viewModel.selectedImage {
                if viewModel.currentFrameIndex != nil {
                    VStack(spacing: 0) {
                        imageEditor(image: image)
                        SeriesFilmstripView(viewModel: viewModel)
                    }
                } else {
                    imageEditor(image: image)
                }
            } else if let videoURL = viewModel.selectedVideoURL {
                // Mirrors the series layout above: the media fills the space and
                // its strip hugs the bottom edge.
                VStack(spacing: 0) {
                    VideoPlayerView(url: videoURL, trim: trimStore.effectiveRange, controller: playback)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VideoTrimBarView(store: trimStore, playback: playback, videoURL: videoURL)
                        // Resets the bar's @State (thumbnails, active handle,
                        // measured width) when one recording replaces another.
                        .id(videoURL)
                }
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

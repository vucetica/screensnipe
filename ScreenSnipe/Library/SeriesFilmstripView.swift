import SwiftUI

/// Horizontal strip of frame thumbnails shown under the canvas for series entries.
///
/// Frames are addressed by manifest index, never by position, so deleting a
/// frame cannot shift the selection onto a different image.
struct SeriesFilmstripView: View {
    @ObservedObject var viewModel: LibraryViewModel

    /// Focus lives here so bare arrow keys can step through frames. The canvas
    /// consumes arrow keys to nudge a selected annotation, so the two only
    /// coexist because focus is genuinely somewhere else while the strip is active.
    @FocusState private var isFocused: Bool

    private let thumbnailHeight: CGFloat = 52
    private let thumbnailWidth: CGFloat = 70
    private let verticalPadding: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFocused ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(height: isFocused ? 2 : 1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(viewModel.seriesFrames.enumerated()), id: \.element.index) { position, frame in
                            thumbnail(for: frame, position: position + 1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, verticalPadding)
                }
                // Hug the thumbnails vertically. Without this the scroll view
                // takes whatever height the split view offers it.
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: viewModel.currentFrameIndex) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .background(.bar)
        .focusable()
        .focused($isFocused)
        // The system ring would trace the full width of the strip; the accent
        // rule along the top reads better at this size.
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: viewModel.goToPreviousFrame()
            case .right: viewModel.goToNextFrame()
            default: break
            }
        }
        .onTapGesture { isFocused = true }
        .accessibilityLabel("Series frames")
        .accessibilityHint("Use the left and right arrow keys to move between frames")
    }

    @ViewBuilder
    private func thumbnail(for frame: SeriesManifest.Frame, position: Int) -> some View {
        let isCurrent = frame.index == viewModel.currentFrameIndex
        Group {
            if let url = viewModel.frameImageURL(frame) {
                DownsampledThumbnailView(url: url, maxPixelSize: 240)
            } else {
                Color.secondary.opacity(0.2)
            }
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // The number sits on the thumbnail rather than under it: a second row
        // of text would more than double the strip's height.
        .overlay(alignment: .bottomLeading) {
            Text("\(position)")
                .font(.caption2.bold())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.35),
                              lineWidth: isCurrent ? 2.5 : 1)
        )
        .id(frame.index)
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            viewModel.loadFrame(frame.index)
        }
        .help("Frame \(position)")
        .contextMenu {
            Button("Delete Frame") {
                viewModel.deleteFrame(frame.index)
            }
            .disabled(viewModel.seriesFrames.count <= 1)
        }
    }
}

import SwiftUI
import AVFoundation

/// Filmstrip trim bar shown under the player for video entries.
///
/// Structurally the video counterpart of `SeriesFilmstripView`: a strip hugging
/// the bottom of the detail pane, focusable for keyboard use, with an accent rule
/// along the top standing in for the focus ring.
///
/// The trim it edits is non-destructive. Nothing here rewrites `recording.mp4`;
/// the range is stored in the entry's metadata and applied by the export paths.
struct VideoTrimBarView: View {
    @ObservedObject var store: VideoTrimStore
    @ObservedObject var playback: VideoPlaybackController
    let videoURL: URL

    @FocusState private var isFocused: Bool
    @State private var activeHandle: Handle = .start
    @State private var stripWidth: CGFloat = 0
    @State private var thumbnails: [NSImage] = []

    private enum Handle { case start, end }

    /// Named so handle drags report a location already in strip coordinates,
    /// rather than one relative to the offset handle that has to be re-derived.
    private static let stripSpace = "videoTrimStrip"

    private let stripHeight: CGFloat = 48
    private let handleWidth: CGFloat = 10
    private let hitSlop: CGFloat = 8
    /// Target width of one thumbnail. The count follows from the strip's width.
    private let thumbnailWidth: CGFloat = 70

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFocused ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(height: isFocused ? 2 : 1)
            VStack(spacing: 6) {
                strip
                controlsRow
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        // Hug the strip vertically. Without this it takes whatever height the
        // split view offers.
        .fixedSize(horizontal: false, vertical: true)
        .focusable()
        .focused($isFocused)
        // The system ring would trace the full width of the bar; the accent rule
        // along the top reads better at this size.
        .focusEffectDisabled()
        .onMoveCommand(perform: handleMove)
        .onKeyPress("[") { setActiveEdgeToPlayhead(.start); return .handled }
        .onKeyPress("]") { setActiveEdgeToPlayhead(.end); return .handled }
        .onKeyPress(.escape) {
            guard store.hasTrim else { return .ignored }
            store.reset()
            return .handled
        }
        .onTapGesture { isFocused = true }
        .accessibilityLabel("Trim recording")
        .accessibilityHint("Drag the start and end handles, or use the left and right arrow keys to move the selected handle")
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 8) {
            Text(timeReadout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset Trim", systemImage: "arrow.uturn.backward") {
                store.reset()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!store.hasTrim)
            .help("Clear the trim and export the whole recording")
        }
    }

    private var timeReadout: String {
        guard let range = store.effectiveRange else { return "Loading…" }
        let selected = Self.format(range.duration)
        return "\(Self.format(range.start)) to \(Self.format(range.end))  ·  \(selected) selected"
    }

    private static func format(_ time: CMTime) -> String {
        let total = CMTimeGetSeconds(time)
        guard total.isFinite, total >= 0 else { return "0:00.0" }
        let minutes = Int(total) / 60
        let seconds = total - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }

    // MARK: - Strip

    private var strip: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                thumbnailRow(width: width)
                if let range = store.effectiveRange {
                    dimming(range: range, width: width)
                    selectionBorder(range: range, width: width)
                    playhead(width: width)
                    handle(.start, at: x(for: range.start, in: width), width: width)
                    handle(.end, at: x(for: range.end, in: width), width: width)
                }
            }
            .frame(width: width, height: stripHeight)
            .coordinateSpace(name: Self.stripSpace)
            .onAppear { stripWidth = width }
            .onChange(of: width) { _, newValue in stripWidth = newValue }
        }
        .frame(height: stripHeight)
        .task(id: FilmstripKey(url: videoURL, bucket: widthBucket, duration: store.assetDuration)) {
            guard store.isReady, stripWidth > 0 else { return }
            thumbnails = await VideoFilmstripGenerator.frames(
                url: videoURL,
                duration: store.assetDuration,
                count: thumbnailCount,
                maxPixelSize: 160
            )
        }
    }

    /// Identity for the thumbnail task. The width is bucketed so a live window
    /// resize does not regenerate the strip on every pixel.
    private struct FilmstripKey: Hashable {
        let url: URL
        let bucket: Int
        let duration: CMTime
    }

    private var thumbnailCount: Int { max(1, Int(stripWidth / thumbnailWidth)) }
    private var widthBucket: Int { Int(stripWidth / 40) }

    private func thumbnailRow(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Rectangle().fill(Color.secondary.opacity(0.2))
            } else {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(thumbnails.count), height: stripHeight)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Scrim over everything outside the selection, matching the 40% black
    /// `CanvasView.drawCropOverlay` puts outside a crop rect.
    private func dimming(range: CMTimeRange, width: CGFloat) -> some View {
        let startX = x(for: range.start, in: width)
        let endX = x(for: range.end, in: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.black.opacity(0.4))
                .frame(width: max(startX, 0), height: stripHeight)
            Rectangle()
                .fill(.black.opacity(0.4))
                .frame(width: max(width - endX, 0), height: stripHeight)
                .offset(x: endX)
        }
        .frame(width: width, height: stripHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }

    private func selectionBorder(range: CMTimeRange, width: CGFloat) -> some View {
        let startX = x(for: range.start, in: width)
        let endX = x(for: range.end, in: width)
        return RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .frame(width: max(endX - startX, 0), height: stripHeight)
            .offset(x: startX)
            .allowsHitTesting(false)
    }

    private func playhead(width: CGFloat) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2, height: stripHeight)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .offset(x: x(for: playback.currentTime, in: width) - 1)
            .allowsHitTesting(false)
    }

    /// Each handle owns its own drag gesture, so SwiftUI decides which one the
    /// mouse grabbed and no manual hit-testing is needed. They cannot overlap
    /// because the store keeps them `minimumDuration` apart.
    private func handle(_ which: Handle, at position: CGFloat, width: CGFloat) -> some View {
        let isActive = isFocused && activeHandle == which
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(isActive ? 1.0 : 0.85))
            .overlay(
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: 16)
            )
            .frame(width: handleWidth, height: stripHeight + 6)
            .contentShape(Rectangle().inset(by: -hitSlop))
            .offset(x: position - handleWidth / 2, y: -3)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.stripSpace))
                    .onChanged { value in
                        if !store.isDragging {
                            store.beginDrag()
                            activeHandle = which
                            isFocused = true
                            // Scrub preview needs a paused player.
                            playback.pause()
                        }
                        let time = self.time(forX: value.location.x, in: width)
                        switch which {
                        case .start: store.setStart(time)
                        case .end: store.setEnd(time)
                        }
                        playback.scrub(to: time)
                    }
                    .onEnded { _ in
                        store.endDrag()
                        if let range = store.effectiveRange {
                            playback.finishScrub(to: which == .start ? range.start : range.end)
                        }
                    }
            )
            .help(which == .start ? "Drag to set where the export starts" : "Drag to set where the export ends")
    }

    // MARK: - Geometry

    private func x(for time: CMTime, in width: CGFloat) -> CGFloat {
        guard store.isReady else { return 0 }
        let total = CMTimeGetSeconds(store.assetDuration)
        guard total > 0 else { return 0 }
        let fraction = min(max(CMTimeGetSeconds(time) / total, 0), 1)
        return CGFloat(fraction) * width
    }

    private func time(forX position: CGFloat, in width: CGFloat) -> CMTime {
        guard width > 0, store.isReady else { return .zero }
        let fraction = min(max(Double(position / width), 0), 1)
        return CMTime(
            seconds: fraction * CMTimeGetSeconds(store.assetDuration),
            preferredTimescale: CodableCMTime.defaultTimescale
        )
    }

    // MARK: - Keyboard

    private func handleMove(_ direction: MoveCommandDirection) {
        guard let range = store.effectiveRange else { return }
        let frame = CMTime(value: 1, timescale: 30)
        switch direction {
        case .up, .down:
            activeHandle = activeHandle == .start ? .end : .start
        case .left:
            nudge(by: CMTime.zero - frame, from: range)
        case .right:
            nudge(by: frame, from: range)
        @unknown default:
            break
        }
    }

    private func nudge(by delta: CMTime, from range: CMTimeRange) {
        switch activeHandle {
        case .start: store.setStart(range.start + delta)
        case .end: store.setEnd(range.end + delta)
        }
    }

    /// The standard editing gesture: put the selected edge where the playhead is.
    private func setActiveEdgeToPlayhead(_ which: Handle) {
        activeHandle = which
        switch which {
        case .start: store.setStart(playback.currentTime)
        case .end: store.setEnd(playback.currentTime)
        }
    }
}

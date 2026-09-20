import SwiftUI
import AVKit

/// Bridge between the trim bar and the `AVPlayer` owned by `VideoPlayerView`'s
/// coordinator.
///
/// The trim bar needs to scrub the player and read the playhead, but the player
/// lives inside an `NSViewRepresentable` that SwiftUI owns, so neither can hold
/// the other directly.
@MainActor
final class VideoPlaybackController: ObservableObject {
    @Published private(set) var currentTime: CMTime = .zero

    fileprivate weak var player: AVPlayer?
    private var isSeeking = false
    private var pendingSeek: CMTime?

    func pause() { player?.pause() }

    /// Coarse seek for live scrubbing.
    ///
    /// Infinite tolerance, and only one seek in flight at a time with the newest
    /// target coalesced. Without the coalescing a drag queues dozens of seeks and
    /// the preview lags several frames behind the handle.
    func scrub(to time: CMTime) {
        currentTime = time
        guard let player else { return }
        guard !isSeeking else {
            pendingSeek = time
            return
        }
        isSeeking = true
        // AVFoundation calls this on an internal queue, not the main one, so it
        // has to hop rather than assume isolation.
        player.seek(to: time, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.scrub(to: next)
                }
            }
        }
    }

    /// Exact seek at the end of a drag, so the frame shown is the frame the
    /// stored cut will actually produce.
    func finishScrub(to time: CMTime) {
        pendingSeek = nil
        currentTime = time
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    fileprivate func attach(_ player: AVPlayer?) {
        self.player = player
        pendingSeek = nil
        isSeeking = false
        currentTime = .zero
    }

    fileprivate func report(_ time: CMTime) { currentTime = time }
}

// MARK: - Video Player (NSViewRepresentable)

/// Custom NSViewRepresentable wrapping AVPlayerView directly.
/// Avoids _AVKit_SwiftUI framework which crashes on macOS 26.3
/// during class metadata initialization in TestFlight/Release builds.
///
/// The player always holds the *full* recording rather than a trimmed
/// composition, so dragging a trim handle can seek to frames outside the
/// selection for preview. The selection is enforced on the player item instead,
/// via `forwardPlaybackEndTime`.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    let trim: CMTimeRange?
    @ObservedObject var controller: VideoPlaybackController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        context.coordinator.install(url: url, trim: trim, into: playerView)
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        let currentURL = (playerView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            context.coordinator.install(url: url, trim: trim, into: playerView)
        } else {
            context.coordinator.apply(trim: trim)
        }
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        coordinator.teardown()
        playerView.player = nil
    }

    @MainActor
    final class Coordinator {
        private let controller: VideoPlaybackController
        private var player: AVPlayer?
        private var trim: CMTimeRange?
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?

        /// The periodic observer samples at 10 Hz, so a bound is only enforced
        /// once the playhead is clearly outside the range. Without the slack a
        /// seek that is still settling gets fought by the next sample.
        private static let boundsSlack = CMTime(value: 1, timescale: 4)

        init(controller: VideoPlaybackController) {
            self.controller = controller
        }

        func install(url: URL, trim: CMTimeRange?, into playerView: AVPlayerView) {
            teardown()

            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            playerView.player = player
            self.player = player
            controller.attach(player)
            self.trim = nil
            apply(trim: trim)

            // Feeds the trim bar's playhead, and re-asserts the range after
            // arbitrary seeks: forwardPlaybackEndTime stops *playback* at the out
            // point but does not stop the user dragging AVPlayerView's own
            // scrubber past it.
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 10),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.controller.report(time)
                    self.enforceBounds(at: time)
                }
            }

            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let start = self.trim?.start else { return }
                    // Without this the playhead parks at the out point and the
                    // next press of Play is a no-op.
                    self.player?.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }

        /// Guarded on inequality because `updateNSView` runs on every redraw the
        /// view model triggers; re-seeking there would fight the user's scrubber.
        func apply(trim: CMTimeRange?) {
            guard trim != self.trim else { return }
            self.trim = trim
            guard let item = player?.currentItem else { return }
            item.forwardPlaybackEndTime = trim?.end ?? .invalid
            item.reversePlaybackEndTime = trim?.start ?? .invalid
            if let start = trim?.start, (player?.currentTime() ?? .zero) < start {
                player?.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        private func enforceBounds(at time: CMTime) {
            guard let trim, let player else { return }
            if time < trim.start - Self.boundsSlack {
                player.seek(to: trim.start, toleranceBefore: .zero, toleranceAfter: .zero)
            } else if time > trim.end + Self.boundsSlack {
                player.pause()
                player.seek(to: trim.start, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }

        /// Removing the observer while the player is still alive is required:
        /// dropping a player that still has a periodic observer attached crashes.
        func teardown() {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            timeObserver = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
            player?.pause()
            controller.attach(nil)
            player = nil
            trim = nil
        }
    }
}

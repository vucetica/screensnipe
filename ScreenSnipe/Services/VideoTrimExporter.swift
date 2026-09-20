import AVFoundation
import Foundation

/// Nonisolated engine that writes a time-bounded copy of a recording.
///
/// Follows the `VideoExportMerger` / `StitchService` pattern for Swift 6 strict
/// concurrency: every AV object is created and consumed inside one call, and the
/// non-Sendable reader/writer pairs cross into the sample pumps through a box
/// that is only ever touched by the pump that owns it.
///
/// ## Why trimming re-encodes the video
///
/// `AVAssetReaderTrackOutput` with `outputSettings: nil` delivers compressed
/// samples, and a compressed range has to begin at the sync sample at or before
/// the requested start, because the frames in between cannot be decoded without
/// it. That leaves no good option: starting the writer session at the requested
/// time throws the keyframe away and opens the file on garbage, and starting it
/// at the first delivered sample silently includes up to one whole GOP of
/// lead-in. Recordings use `AVVideoMaxKeyFrameIntervalKey: 30` at 30 fps, so
/// that lead-in is up to a full second earlier than the handle the user dragged.
///
/// Decoding and re-encoding gives a frame-exact start, and it also removes the
/// PTS/DTS retiming hazard entirely, because the encoder mints fresh timing
/// rather than something having to guess decode order for B-frames.
/// `StitchService` already re-encodes every source on the same settings, so the
/// quality bar is unchanged. Untrimmed exports never come through here, so they
/// stay a lossless copy.
enum VideoTrimExporter {

    enum AudioMode: Sendable {
        /// One track per source audio track, passed through without re-encoding,
        /// so system audio and microphone stay separable downstream.
        case preserveTracks
        /// All source audio mixed down into a single AAC track.
        case mergeToSingleTrack
    }

    enum TrimExportError: LocalizedError {
        case noVideoTrack
        case readerSetupFailed(Error?)
        case writerSetupFailed(Error?)
        case emptyRange

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "Source video has no video track."
            case .readerSetupFailed(let e): "Failed to set up video reader: \(e?.localizedDescription ?? "unknown")"
            case .writerSetupFailed(let e): "Failed to set up video writer: \(e?.localizedDescription ?? "unknown")"
            case .emptyRange: "The selected range is empty."
            }
        }
    }

    /// Writes `range` of `sourceURL` to `destinationURL` as an MP4.
    /// Honours `Task` cancellation, removing any partial file on the way out.
    static func export(
        sourceURL: URL,
        destinationURL: URL,
        range: CMTimeRange,
        audioMode: AudioMode,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else { throw TrimExportError.noVideoTrack }

        let assetDuration = try await asset.load(.duration)
        let clipped = range.intersection(CMTimeRange(start: .zero, duration: assetDuration))
        guard clipped.duration > .zero else { throw TrimExportError.emptyRange }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // One reader for everything, so video and audio are cut on exactly the
        // same boundary. `timeRange` must be set before `startReading()`.
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = clipped

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(videoOutput) else { throw TrimExportError.readerSetupFailed(nil) }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        // Encoders require even dimensions.
        let width = max(Int(abs(transformed.width)) & ~1, 2)
        let height = max(Int(abs(transformed.height)) & ~1, 2)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw TrimExportError.writerSetupFailed(nil) }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        let cancellation = CancellationFlag()
        var audioPumps: [AudioPump] = []
        switch audioMode {
        case .mergeToSingleTrack where !audioTracks.isEmpty:
            let mix = AVMutableAudioMix()
            mix.inputParameters = audioTracks.map { track in
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(1.0, at: .zero)
                return params
            }
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
            mixOutput.audioMix = mix
            guard reader.canAdd(mixOutput) else { throw TrimExportError.readerSetupFailed(nil) }
            reader.add(mixOutput)

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw TrimExportError.writerSetupFailed(nil) }
            writer.add(input)
            audioPumps.append(AudioPump(output: mixOutput, input: input, label: "merged", cancellation: cancellation))

        case .preserveTracks:
            // Tracks are added in source order, so system audio stays track 0
            // and the microphone stays track 1.
            for (index, track) in audioTracks.enumerated() {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(output) else { continue }
                reader.add(output)

                let formatDescriptions = try await track.load(.formatDescriptions)
                let input: AVAssetWriterInput
                if let hint = formatDescriptions.first {
                    input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
                } else {
                    input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                }
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { continue }
                writer.add(input)
                audioPumps.append(AudioPump(output: output, input: input, label: "audio\(index)", cancellation: cancellation))
            }

        default:
            break
        }

        guard reader.startReading() else {
            throw TrimExportError.readerSetupFailed(reader.error)
        }
        guard writer.startWriting() else {
            throw TrimExportError.writerSetupFailed(writer.error)
        }
        // Starting the session at the trim start means every sample keeps its
        // original presentation time and the writer rebases the tracks itself.
        // Nothing has to be retimed, so audio and video cannot drift apart.
        writer.startSession(atSourceTime: clipped.start)

        let videoPump = VideoPump(
            output: videoOutput,
            input: videoInput,
            adaptor: adaptor,
            range: clipped,
            progress: progress,
            cancellation: cancellation
        )

        let pumps = audioPumps
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await videoPump.run() }
                for pump in pumps {
                    group.addTask { await pump.run() }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }

        if cancellation.isCancelled || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        }

        await writer.finishWriting()

        if writer.status == .failed {
            try? FileManager.default.removeItem(at: destinationURL)
            throw TrimExportError.writerSetupFailed(writer.error)
        }
        progress?(1.0)
    }

    // MARK: - Settings

    // Computed rather than stored: `[String: Any]` is not Sendable, so a stored
    // static would be shared mutable state under strict concurrency. Elsewhere in
    // the app these dictionaries are locals inside the function that uses them.
    private static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
        ]
    }

    private static var aacSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    // MARK: - Sample pumps

    /// Shared cancellation flag.
    ///
    /// `Task.isCancelled` cannot be used inside the pumps: their work runs in a
    /// `requestMediaDataWhenReady` block on a dispatch queue, which carries no
    /// task context, so the property would read false forever and the Cancel
    /// button would do nothing.
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// Each pump owns its reader output and writer input outright and touches
    /// them only from its own serial queue, which is what makes the unchecked
    /// conformance sound for these non-Sendable AV types.
    private final class VideoPump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let range: CMTimeRange
        private let progress: (@Sendable (Double) -> Void)?
        private let cancellation: CancellationFlag
        private var lastReportedPercent = -1

        init(
            output: AVAssetReaderOutput,
            input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            range: CMTimeRange,
            progress: (@Sendable (Double) -> Void)?,
            cancellation: CancellationFlag
        ) {
            self.output = output
            self.input = input
            self.adaptor = adaptor
            self.range = range
            self.progress = progress
            self.cancellation = cancellation
        }

        func run() async {
            await withCheckedContinuation { continuation in
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "app.screensnipe.trim.video")) { [self] in
                    while input.isReadyForMoreMediaData {
                        if cancellation.isCancelled {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        guard let sampleBuffer = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        // The reader's timeRange should already have discarded
                        // these, but appending before the session start fails the
                        // whole writer, so never rely on that alone.
                        guard pts >= range.start,
                              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                        adaptor.append(pixelBuffer, withPresentationTime: pts)
                        report(pts)
                    }
                }
            }
        }

        private func report(_ pts: CMTime) {
            guard let progress else { return }
            let total = CMTimeGetSeconds(range.duration)
            guard total > 0 else { return }
            let fraction = min(max(CMTimeGetSeconds(pts - range.start) / total, 0), 1)
            let percent = Int(fraction * 100)
            guard percent != lastReportedPercent else { return }
            lastReportedPercent = percent
            progress(fraction)
        }
    }

    private final class AudioPump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let label: String
        private let cancellation: CancellationFlag

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, cancellation: CancellationFlag) {
            self.output = output
            self.input = input
            self.label = label
            self.cancellation = cancellation
        }

        func run() async {
            await withCheckedContinuation { continuation in
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "app.screensnipe.trim.\(label)")) { [self] in
                    while input.isReadyForMoreMediaData {
                        if cancellation.isCancelled {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        guard let sampleBuffer = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        input.append(sampleBuffer)
                    }
                }
            }
        }
    }
}

// MARK: - Staging

/// Produces a real file reflecting an entry's stored trim, for callers that need
/// one (the share sheet, the iCloud publish) rather than a save-panel destination.
@MainActor
enum VideoTrimStaging {
    private static let directoryName = "ScreenSnipeTrim"

    /// Returns `videoURL` unchanged when there is no trim, so untrimmed sharing
    /// stays instant and byte-identical. `name` becomes the filename the
    /// recipient sees.
    static func materialize(videoURL: URL, trim: CMTimeRange?, name: String) async throws -> URL {
        guard let trim else { return videoURL }
        // The app's own temp container, not the library folder: this file is
        // transient and app-owned, unlike a stitch result that becomes an entry.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory
            .appendingPathComponent(sanitized(name))
            .appendingPathExtension("mp4")
        try await VideoTrimExporter.export(
            sourceURL: videoURL,
            destinationURL: output,
            range: trim,
            audioMode: .preserveTracks
        )
        return output
    }

    static func discard(_ url: URL, original: URL) {
        guard url != original else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Clears anything left behind by a share that was still in flight at quit.
    static func clearStagingDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.isEmpty ? "Recording" : cleaned
    }
}

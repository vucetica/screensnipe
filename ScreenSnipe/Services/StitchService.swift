import AVFoundation
import AppKit
import CoreVideo
import Metal

/// Nonisolated engine that composites videos + images into a single MP4.
/// Follows the VideoExportMerger pattern for Swift 6 strict concurrency.
enum StitchService {

    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    enum StitchError: LocalizedError {
        case noItems
        case writerSetupFailed
        case writerFailed(Error?)
        case readerFailed(Error?)
        case cancelled
        case imageLoadFailed(String)

        var errorDescription: String? {
            switch self {
            case .noItems: "No items to stitch."
            case .writerSetupFailed: "Failed to set up video writer."
            case .writerFailed(let e): "Video writer failed: \(e?.localizedDescription ?? "unknown")"
            case .readerFailed(let e): "Video reader failed: \(e?.localizedDescription ?? "unknown")"
            case .cancelled: "Stitch was cancelled."
            case .imageLoadFailed(let name): "Failed to load image: \(name)"
            }
        }
    }

    // MARK: - Public API

    /// Stitches the given configuration into a single MP4.
    /// - Parameters:
    ///   - config: The stitch configuration with items, pause, and image duration.
    ///   - progress: Called on MainActor with fraction 0...1.
    /// - Returns: URL of the temporary output file.
    static func stitch(
        config: StitchConfiguration,
        tempDirectory: URL? = nil,
        progress: @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        guard !config.items.isEmpty else { throw StitchError.noItems }

        NSLog("[StitchService] Starting stitch with \(config.items.count) items")

        // 1. Determine output dimensions and estimate total duration for progress
        let outputSize = try await resolveOutputSize(items: config.items)
        let totalEstimatedFrames = try await estimateTotalFrames(config: config, fps: 30)
        NSLog("[StitchService] Output size: \(outputSize), estimated frames: \(totalEstimatedFrames)")

        // 2. Create temp output file in the library directory (user-accessible)
        let tempURL = (tempDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(".stitch-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        // 3. Set up AVAssetWriter
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)

        let width = Int(outputSize.width)
        let height = Int(outputSize.height)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ] as [String: Any],
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw StitchError.writerSetupFailed }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        let systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(systemAudioInput) else { throw StitchError.writerSetupFailed }
        writer.add(systemAudioInput)

        let micAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micAudioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(micAudioInput) else { throw StitchError.writerSetupFailed }
        writer.add(micAudioInput)

        guard writer.startWriting() else {
            throw StitchError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // 4. Process each item sequentially
        let totalItems = config.items.count
        var currentTime = CMTime.zero
        let fps: Int32 = 30
        var framesWritten: Int64 = 0

        for (index, item) in config.items.enumerated() {
            try Task.checkCancellation()

            NSLog("[StitchService] Processing item \(index + 1)/\(totalItems): \(item.mediaType) - \(item.id)")
            switch item.mediaType {
            case .video:
                let result = try await appendVideo(
                    entry: item,
                    writer: writer,
                    videoInput: videoInput,
                    adaptor: adaptor,
                    systemAudioInput: systemAudioInput,
                    micAudioInput: micAudioInput,
                    startTime: currentTime,
                    outputSize: outputSize,
                    fps: fps
                ) { segmentFrames in
                    framesWritten += segmentFrames
                    let fraction = min(Double(framesWritten) / Double(max(totalEstimatedFrames, 1)), 0.99)
                    await progress(fraction)
                }
                currentTime = result
            case .image:
                let result = try await appendImage(
                    entry: item,
                    writer: writer,
                    adaptor: adaptor,
                    videoInput: videoInput,
                    systemAudioInput: systemAudioInput,
                    micAudioInput: micAudioInput,
                    startTime: currentTime,
                    outputSize: outputSize,
                    duration: config.imageDurationSeconds,
                    fps: fps
                ) { segmentFrames in
                    framesWritten += segmentFrames
                    let fraction = min(Double(framesWritten) / Double(max(totalEstimatedFrames, 1)), 0.99)
                    await progress(fraction)
                }
                currentTime = result
            }

            // Add pause between items (not after the last)
            if config.pauseDurationSeconds > 0 && index < totalItems - 1 {
                try Task.checkCancellation()
                currentTime = try appendBlack(
                    writer: writer,
                    adaptor: adaptor,
                    videoInput: videoInput,
                    systemAudioInput: systemAudioInput,
                    micAudioInput: micAudioInput,
                    startTime: currentTime,
                    duration: config.pauseDurationSeconds,
                    outputSize: outputSize,
                    fps: fps
                )
                framesWritten += Int64(config.pauseDurationSeconds * Double(fps))
            }
        }

        // 5. Finish writing
        NSLog("[StitchService] All items processed, finishing writer")
        videoInput.markAsFinished()
        systemAudioInput.markAsFinished()
        micAudioInput.markAsFinished()

        await writer.finishWriting()

        if writer.status == .failed {
            throw StitchError.writerFailed(writer.error)
        }

        await progress(1.0)
        return tempURL
    }

    // MARK: - Duration Estimation

    private static func estimateTotalFrames(config: StitchConfiguration, fps: Int32) async throws -> Int64 {
        var total: Int64 = 0
        for (index, item) in config.items.enumerated() {
            switch item.mediaType {
            case .video:
                let asset = AVURLAsset(url: item.mediaURL)
                let duration = try await asset.load(.duration)
                total += Int64(CMTimeGetSeconds(duration) * Double(fps))
            case .image:
                total += Int64(config.imageDurationSeconds * Double(fps))
            }
            if config.pauseDurationSeconds > 0 && index < config.items.count - 1 {
                total += Int64(config.pauseDurationSeconds * Double(fps))
            }
        }
        return total
    }

    // MARK: - Resolution

    private static func resolveOutputSize(items: [LibraryEntry]) async throws -> CGSize {
        var maxWidth: Int = 0
        var maxHeight: Int = 0

        for item in items {
            switch item.mediaType {
            case .video:
                let asset = AVURLAsset(url: item.mediaURL)
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let transformed = size.applying(transform)
                    maxWidth = max(maxWidth, Int(abs(transformed.width)))
                    maxHeight = max(maxHeight, Int(abs(transformed.height)))
                }
            case .image:
                if let image = NSImage(contentsOf: item.mediaURL) {
                    let rep = image.representations.first
                    let w = rep?.pixelsWide ?? Int(image.size.width)
                    let h = rep?.pixelsHigh ?? Int(image.size.height)
                    maxWidth = max(maxWidth, w)
                    maxHeight = max(maxHeight, h)
                }
            }
        }

        // Round to even (H.264/HEVC encoder requirement)
        maxWidth = (maxWidth + 1) & ~1
        maxHeight = (maxHeight + 1) & ~1

        if maxWidth == 0 || maxHeight == 0 {
            return CGSize(width: 1920, height: 1080)
        }

        return CGSize(width: maxWidth, height: maxHeight)
    }

    // MARK: - Append Video

    private static func appendVideo(
        entry: LibraryEntry,
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        systemAudioInput: AVAssetWriterInput,
        micAudioInput: AVAssetWriterInput,
        startTime: CMTime,
        outputSize: CGSize,
        fps: Int32,
        chunkProgress: @MainActor @Sendable (Int64) async -> Void
    ) async throws -> CMTime {
        let asset = AVURLAsset(url: entry.mediaURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = videoTracks.first else {
            return startTime
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedSize = CGSize(
            width: abs(naturalSize.applying(transform).width),
            height: abs(naturalSize.applying(transform).height)
        )

        // Video reader
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard videoReader.canAdd(videoOutput) else { throw StitchError.readerFailed(nil) }
        videoReader.add(videoOutput)
        guard videoReader.startReading() else {
            throw StitchError.readerFailed(videoReader.error)
        }

        // Audio reader — uses its own AVURLAsset so tracks belong to the reader's asset.
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
        ]

        var systemAudioBuffers: [CMSampleBuffer] = []
        var micAudioBuffers: [CMSampleBuffer] = []

        let audioAsset = AVURLAsset(url: entry.mediaURL)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)

        if !audioTracks.isEmpty {
            let audioReader = try AVAssetReader(asset: audioAsset)
            for track in audioTracks {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
                if audioReader.canAdd(output) { audioReader.add(output) }
            }

            if audioReader.startReading() {
                let outputs = audioReader.outputs
                if outputs.count >= 1 {
                    while let buf = outputs[0].copyNextSampleBuffer() {
                        systemAudioBuffers.append(buf)
                    }
                }
                if outputs.count >= 2 {
                    while let buf = outputs[1].copyNextSampleBuffer() {
                        micAudioBuffers.append(buf)
                    }
                }
                audioReader.cancelReading()
            }
        }

        NSLog("[StitchService] appendVideo: audioTracks=\(audioTracks.count), sysBuffers=\(systemAudioBuffers.count), micBuffers=\(micAudioBuffers.count), startTime=\(CMTimeGetSeconds(startTime))s")

        let needsScaling = Int(transformedSize.width) != Int(outputSize.width) ||
                          Int(transformedSize.height) != Int(outputSize.height)

        // Write video frames using their ORIGINAL timestamps (offset by startTime)
        // so video and audio stay in perfect sync regardless of source framerate.
        let hasSysAudio = !systemAudioBuffers.isEmpty
        let hasMicAudio = !micAudioBuffers.isEmpty
        var frameCount: Int64 = 0
        var sysAudioIdx = 0
        var micAudioIdx = 0
        var videoDone = false
        var lastSourcePTS = CMTime.zero // tracks how far we've read in source time
        var chunkStartSourcePTS = CMTime.zero // tracks where the current silence chunk begins
        let chunkInterval = CMTime(value: 1, timescale: 1) // flush audio every ~1s of source time
        var nextAudioFlush = chunkInterval

        while !videoDone {
            try Task.checkCancellation()
            let chunkStartFrame = frameCount

            // Write video frames until we've advanced ~1 second of source time
            while true {
                guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                    videoDone = true
                    break
                }

                let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let outputPTS = sourcePTS + startTime

                if needsScaling {
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        frameCount += 1
                        lastSourcePTS = sourcePTS
                        continue
                    }
                    let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                    let scaled = letterbox(ciImage, sourceSize: transformedSize, outputSize: outputSize)

                    guard let pool = adaptor.pixelBufferPool else {
                        frameCount += 1
                        lastSourcePTS = sourcePTS
                        continue
                    }
                    var outputBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                    guard let outBuf = outputBuffer else {
                        frameCount += 1
                        lastSourcePTS = sourcePTS
                        continue
                    }

                    Self.ciContext.render(scaled, to: outBuf)
                    try waitForReady(videoInput, writer: writer)
                    adaptor.append(outBuf, withPresentationTime: outputPTS)
                } else {
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                        frameCount += 1
                        lastSourcePTS = sourcePTS
                        continue
                    }
                    try waitForReady(videoInput, writer: writer)
                    adaptor.append(imageBuffer, withPresentationTime: outputPTS)
                }

                frameCount += 1
                lastSourcePTS = sourcePTS

                // Break after ~1 second of source time to flush audio
                if CMTimeCompare(sourcePTS, nextAudioFlush) >= 0 {
                    nextAudioFlush = sourcePTS + chunkInterval
                    break
                }
            }

            // Flush audio up to current source position
            let flushTime = lastSourcePTS + CMTime(value: 1, timescale: fps) // slightly ahead
            let framesInChunk = frameCount - chunkStartFrame
            guard framesInChunk > 0 else { continue }

            if hasSysAudio {
                sysAudioIdx = writeAudioUpTo(
                    time: flushTime, buffers: systemAudioBuffers, startIndex: sysAudioIdx,
                    input: systemAudioInput, writer: writer, offset: startTime
                )
            }
            if hasMicAudio {
                micAudioIdx = writeAudioUpTo(
                    time: flushTime, buffers: micAudioBuffers, startIndex: micAudioIdx,
                    input: micAudioInput, writer: writer, offset: startTime
                )
            }

            // Write interleaved silence for any missing audio tracks
            if !hasSysAudio || !hasMicAudio {
                let silenceStart = chunkStartSourcePTS + startTime
                let silenceDuration = lastSourcePTS - chunkStartSourcePTS + CMTime(value: 1, timescale: fps)
                writeInterleavedSilence(
                    to: hasSysAudio ? nil : systemAudioInput,
                    and: hasMicAudio ? nil : micAudioInput,
                    writer: writer, startTime: silenceStart, duration: silenceDuration
                )
                chunkStartSourcePTS = lastSourcePTS + CMTime(value: 1, timescale: fps)
            }

            await chunkProgress(framesInChunk)
        }

        // Flush remaining pre-read audio samples
        while sysAudioIdx < systemAudioBuffers.count {
            writeRetimedSample(systemAudioBuffers[sysAudioIdx], to: systemAudioInput, writer: writer, offset: startTime)
            sysAudioIdx += 1
        }
        while micAudioIdx < micAudioBuffers.count {
            writeRetimedSample(micAudioBuffers[micAudioIdx], to: micAudioInput, writer: writer, offset: startTime)
            micAudioIdx += 1
        }

        // Pad missing tracks with silence to cover full segment duration
        if !hasSysAudio || !hasMicAudio {
            let finalSilenceStart = chunkStartSourcePTS + startTime
            let endPTS = lastSourcePTS + startTime + CMTime(value: 1, timescale: fps)
            let remaining = endPTS - finalSilenceStart
            if CMTimeGetSeconds(remaining) > 0 {
                writeInterleavedSilence(
                    to: hasSysAudio ? nil : systemAudioInput,
                    and: hasMicAudio ? nil : micAudioInput,
                    writer: writer, startTime: finalSilenceStart, duration: remaining
                )
            }
        }

        videoReader.cancelReading()

        // End time based on actual source duration, not frame count
        let endTime = lastSourcePTS + startTime + CMTime(value: 1, timescale: fps)
        NSLog("[StitchService] appendVideo: done, \(frameCount) frames, endTime=\(CMTimeGetSeconds(endTime))s")
        return endTime
    }

    // MARK: - Append Image

    private static func appendImage(
        entry: LibraryEntry,
        writer: AVAssetWriter,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput,
        micAudioInput: AVAssetWriterInput,
        startTime: CMTime,
        outputSize: CGSize,
        duration: Double,
        fps: Int32,
        chunkProgress: @MainActor @Sendable (Int64) async -> Void
    ) async throws -> CMTime {
        guard let image = NSImage(contentsOf: entry.mediaURL) else {
            throw StitchError.imageLoadFailed(entry.id)
        }

        let rep = image.representations.first
        let sourceSize = CGSize(
            width: rep?.pixelsWide ?? Int(image.size.width),
            height: rep?.pixelsHigh ?? Int(image.size.height)
        )

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw StitchError.imageLoadFailed(entry.id)
        }

        let ciImage = CIImage(cgImage: cgImage)
        let scaled = letterbox(ciImage, sourceSize: sourceSize, outputSize: outputSize)

        guard let pool = adaptor.pixelBufferPool else { throw StitchError.writerSetupFailed }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw StitchError.writerSetupFailed }

        Self.ciContext.render(scaled, to: buffer)

        let totalFrames = Int64(duration * Double(fps))

        // Write video and audio interleaved in 1-second chunks
        let chunkFrames = Int64(fps)
        var frame: Int64 = 0

        while frame < totalFrames {
            try Task.checkCancellation()
            let chunkEnd = min(frame + chunkFrames, totalFrames)

            // Write one chunk of video frames
            for f in frame..<chunkEnd {
                let time = startTime + CMTime(value: f, timescale: fps)
                try waitForReady(videoInput, writer: writer)
                adaptor.append(buffer, withPresentationTime: time)
            }

            // Write interleaved silence for both audio tracks
            let chunkStartTime = startTime + CMTime(value: frame, timescale: fps)
            let chunkDuration = CMTime(value: chunkEnd - frame, timescale: fps)
            writeInterleavedSilence(
                to: systemAudioInput, and: micAudioInput,
                writer: writer, startTime: chunkStartTime, duration: chunkDuration
            )

            // Report progress
            await chunkProgress(chunkEnd - frame)

            frame = chunkEnd
        }

        let segmentDuration = CMTime(value: totalFrames, timescale: fps)
        return startTime + segmentDuration
    }

    // MARK: - Append Black (Pause)

    private static func appendBlack(
        writer: AVAssetWriter,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoInput: AVAssetWriterInput,
        systemAudioInput: AVAssetWriterInput,
        micAudioInput: AVAssetWriterInput,
        startTime: CMTime,
        duration: Double,
        outputSize: CGSize,
        fps: Int32
    ) throws -> CMTime {
        guard let pool = adaptor.pixelBufferPool else { throw StitchError.writerSetupFailed }

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { throw StitchError.writerSetupFailed }

        // Fill with black
        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            memset(baseAddress, 0, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let totalFrames = Int64(duration * Double(fps))

        // Write video and audio interleaved in 1-second chunks
        let chunkFrames = Int64(fps)
        var frame: Int64 = 0

        while frame < totalFrames {
            try Task.checkCancellation()
            let chunkEnd = min(frame + chunkFrames, totalFrames)

            for f in frame..<chunkEnd {
                let time = startTime + CMTime(value: f, timescale: fps)
                try waitForReady(videoInput, writer: writer)
                adaptor.append(buffer, withPresentationTime: time)
            }

            let chunkStartTime = startTime + CMTime(value: frame, timescale: fps)
            let chunkDuration = CMTime(value: chunkEnd - frame, timescale: fps)
            writeInterleavedSilence(
                to: systemAudioInput, and: micAudioInput,
                writer: writer, startTime: chunkStartTime, duration: chunkDuration
            )

            frame = chunkEnd
        }

        let segmentDuration = CMTime(value: totalFrames, timescale: fps)
        return startTime + segmentDuration
    }

    // MARK: - Audio Helpers

    /// Writes audio buffers whose original PTS is less than `time`, starting from `startIndex`.
    /// Returns the new index (first unwritten buffer).
    private static func writeAudioUpTo(
        time: CMTime,
        buffers: [CMSampleBuffer],
        startIndex: Int,
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        offset: CMTime
    ) -> Int {
        var idx = startIndex
        while idx < buffers.count {
            let buf = buffers[idx]
            let pts = CMSampleBufferGetPresentationTimeStamp(buf)
            guard CMTimeCompare(pts, time) < 0 else { break }
            writeRetimedSample(buf, to: input, writer: writer, offset: offset)
            idx += 1
        }
        return idx
    }

    /// Retimes a single audio sample buffer by adding `offset` to its PTS, then appends it.
    private static func writeRetimedSample(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        offset: CMTime
    ) {
        guard writer.status != .failed else { return }

        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let newPTS = originalPTS + offset

        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: newPTS,
            decodeTimeStamp: .invalid
        )

        var retimedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &retimedBuffer
        )

        if let retimed = retimedBuffer {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { return }
                Thread.sleep(forTimeInterval: 0.001)
            }
            input.append(retimed)
        }
    }

    /// Writes silence to one or two audio inputs in alternating small chunks,
    /// preventing the writer from throttling one input while the other is behind.
    /// Pass `nil` for an input that doesn't need silence (already has real data).
    private static func writeInterleavedSilence(
        to inputA: AVAssetWriterInput?,
        and inputB: AVAssetWriterInput?,
        writer: AVAssetWriter,
        startTime: CMTime,
        duration: CMTime
    ) {
        let sampleRate: Double = 48000
        let channels: UInt32 = 2
        let totalSamples = Int(CMTimeGetSeconds(duration) * sampleRate)
        guard totalSamples > 0 else { return }

        // Write in small chunks, alternating between inputs
        let chunkSize = 4096
        var samplesWritten = 0

        // Cache format description — same for all chunks
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channels,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &formatDescription
        )
        guard let format = formatDescription else { return }

        while samplesWritten < totalSamples {
            guard writer.status != .failed else { return }

            let count = min(chunkSize, totalSamples - samplesWritten)
            let chunkTime = startTime + CMTime(value: Int64(samplesWritten), timescale: Int32(sampleRate))

            // Write one chunk to inputA, then one to inputB — keeps them balanced
            if let a = inputA {
                if let buf = createSilenceBuffer(format: format, sampleCount: count, time: chunkTime, channels: channels) {
                    while !a.isReadyForMoreMediaData {
                        if writer.status == .failed { return }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    a.append(buf)
                }
            }
            if let b = inputB {
                if let buf = createSilenceBuffer(format: format, sampleCount: count, time: chunkTime, channels: channels) {
                    while !b.isReadyForMoreMediaData {
                        if writer.status == .failed { return }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    b.append(buf)
                }
            }

            samplesWritten += count
        }
    }

    /// Creates a single silent CMSampleBuffer.
    private static func createSilenceBuffer(
        format: CMAudioFormatDescription,
        sampleCount: Int,
        time: CMTime,
        channels: UInt32
    ) -> CMSampleBuffer? {
        let byteCount = sampleCount * Int(channels) * MemoryLayout<Float>.size
        let data = Data(count: byteCount)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil,
                blockLength: byteCount, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0,
                dataLength: byteCount, flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard let block = blockBuffer else { return }
            CMBlockBufferReplaceDataBytes(
                with: baseAddress, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount
            )

            CMSampleBufferCreate(
                allocator: nil, dataBuffer: block,
                dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format, sampleCount: sampleCount,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sampleBuffer
            )
        }
        return sampleBuffer
    }

    // MARK: - Busy Wait

    private static func waitForReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw StitchError.writerFailed(writer.error)
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    // MARK: - Letterboxing

    private static func letterbox(_ image: CIImage, sourceSize: CGSize, outputSize: CGSize) -> CIImage {
        let scaleX = outputSize.width / sourceSize.width
        let scaleY = outputSize.height / sourceSize.height
        let scale = min(scaleX, scaleY)

        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        let offsetX = (outputSize.width - scaledWidth) / 2
        let offsetY = (outputSize.height - scaledHeight) / 2

        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: outputSize))

        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        return scaled.composited(over: black)
    }
}

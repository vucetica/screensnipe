import AVFoundation
import ScreenCaptureKit

@MainActor
final class VideoRecordingService: NSObject, ObservableObject {

    struct AudioConfig {
        var captureSystemAudio: Bool
        var micDevice: AVCaptureDevice?
    }

    enum RecordingTarget {
        case fullScreen
        case region(display: SCDisplay, cropRect: CGRect)
        case window(SCWindow)
    }

    enum RecordingError: Error, LocalizedError {
        case noDisplayFound
        case writerSetupFailed(String)
        case writerFailedDuringRecording(String)
        case notRecording
        case microphoneAccessDenied

        var errorDescription: String? {
            switch self {
            case .noDisplayFound: "No display found for recording."
            case .writerSetupFailed(let msg): "Failed to set up video writer: \(msg)"
            case .writerFailedDuringRecording(let msg): "Recording failed: \(msg)"
            case .notRecording: "No recording in progress."
            case .microphoneAccessDenied: "Microphone access was denied."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published var writerError: Error?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStarted = false
    private var streamOutput: StreamOutputHandler?
    private var streamErrorDelegate: StreamErrorDelegate?

    // Dispatch queues
    private let videoQueue = DispatchQueue(label: "app.screensnipe.videorecording.video", qos: .userInitiated)
    private let systemAudioQueue = DispatchQueue(label: "app.screensnipe.videorecording.systemaudio", qos: .userInitiated)
    private let micAudioQueue = DispatchQueue(label: "app.screensnipe.videorecording.micaudio", qos: .userInitiated)

    // Microphone capture
    private var micCaptureSession: AVCaptureSession?
    private var micOutputDelegate: MicAudioOutputDelegate?

    // All nonisolated(unsafe) vars below are accessed exclusively on videoQueue.
    // Main-actor methods dispatch to videoQueue to read/write them.

    // Pause timing — accessed only on videoQueue
    private nonisolated(unsafe) var pauseStartTime: CMTime = .invalid
    private nonisolated(unsafe) var totalPauseOffset: CMTime = .zero
    private nonisolated(unsafe) var videoQueuePaused = false

    // Mute flags — toggled via videoQueue dispatch, read on videoQueue
    private nonisolated(unsafe) var _isSystemAudioMuted = false
    private nonisolated(unsafe) var _isMicMuted = true

    // Writer failure tracking — accessed on videoQueue
    private nonisolated(unsafe) var hasReportedWriterFailure = false
    private nonisolated(unsafe) var droppedFrameCount = 0
    private nonisolated(unsafe) var totalFrameCount = 0

    // MARK: - Start Recording

    func startRecording(target: RecordingTarget = .fullScreen, audio: AudioConfig = AudioConfig(captureSystemAudio: true, micDevice: nil)) async throws -> Void {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let filter: SCContentFilter
        let videoWidth: Int
        let videoHeight: Int

        switch target {
        case .fullScreen:
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayFound
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            videoWidth = display.width * 2
            videoHeight = display.height * 2

        case .region(let display, let cropRect):
            filter = SCContentFilter(display: display, excludingWindows: [])
            videoWidth = Int(cropRect.width) * 2
            videoHeight = Int(cropRect.height) * 2

        case .window(let scWindow):
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            videoWidth = Int(scWindow.frame.width) * 2
            videoHeight = Int(scWindow.frame.height) * 2
        }

        let config = SCStreamConfiguration()
        config.width = videoWidth
        config.height = videoHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.showsCursor = true
        config.queueDepth = 6

        // Apply source rect for region recording
        if case .region(_, let cropRect) = target {
            config.sourceRect = cropRect
            config.scalesToFit = true
        }

        // Always enable system audio in the stream so it can be toggled mid-recording
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // Apply initial mute state from audio config (synchronized on videoQueue)
        let initialSystemMuted = !audio.captureSystemAudio
        let initialMicMuted = audio.micDevice == nil
        videoQueue.sync {
            _isSystemAudioMuted = initialSystemMuted
            _isMicMuted = initialMicMuted
        }

        // Write directly to the library directory to avoid sandbox temp quota limits.
        // Falls back to NSTemporaryDirectory if the library folder isn't accessible.
        let tempDir = Self.recordingTempDirectory()
        let tempURL = tempDir.appendingPathComponent(".recording-\(UUID().uuidString)").appendingPathExtension("mp4")
        outputURL = tempURL

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)

        // Video input — explicit compression properties keep the encoder fast
        // and prevent frame buildup during long recordings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: videoWidth,
            AVVideoHeightKey: videoHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoWidth * videoHeight * 4,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoExpectedSourceFrameRateKey: 30,
            ] as [String: Any],
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(vInput) else {
            throw RecordingError.writerSetupFailed("Cannot add video input to writer.")
        }
        writer.add(vInput)

        // Audio settings shared by system and mic tracks
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        // System audio input (always created so it can be toggled mid-recording)
        let sysAudioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        sysAudioIn.expectsMediaDataInRealTime = true

        guard writer.canAdd(sysAudioIn) else {
            throw RecordingError.writerSetupFailed("Cannot add system audio input to writer.")
        }
        writer.add(sysAudioIn)

        // Microphone audio input (always created so mic can be switched mid-recording)
        let micAudioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micAudioIn.expectsMediaDataInRealTime = true

        guard writer.canAdd(micAudioIn) else {
            throw RecordingError.writerSetupFailed("Cannot add microphone audio input to writer.")
        }
        writer.add(micAudioIn)

        guard writer.startWriting() else {
            throw RecordingError.writerSetupFailed(writer.error?.localizedDescription ?? "Unknown error")
        }

        assetWriter = writer
        videoInput = vInput
        systemAudioInput = sysAudioIn
        micAudioInput = micAudioIn
        sessionStarted = false
        hasReportedWriterFailure = false
        droppedFrameCount = 0
        totalFrameCount = 0
        writerError = nil

        // Set up SCStream with video + system audio outputs
        let streamDelegate = StreamErrorDelegate(service: self)
        self.streamErrorDelegate = streamDelegate
        let scStream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
        let handler = StreamOutputHandler(service: self)
        streamOutput = handler
        try scStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: videoQueue)
        try scStream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: systemAudioQueue)

        try await scStream.startCapture()
        stream = scStream
        isRecording = true

        // Set up microphone capture if a device is specified
        if let micDevice = audio.micDevice {
            await startMicCapture(device: micDevice)
        }
    }

    // MARK: - Microphone Capture

    private func startMicCapture(device micDevice: AVCaptureDevice) async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            print("Microphone access denied — recording without mic audio.")
            return
        }

        let session = AVCaptureSession()
        do {
            let deviceInput = try AVCaptureDeviceInput(device: micDevice)
            guard session.canAddInput(deviceInput) else {
                print("Cannot add mic input to capture session.")
                return
            }
            session.addInput(deviceInput)
        } catch {
            print("Failed to create mic device input: \(error.localizedDescription)")
            return
        }

        let audioOutput = AVCaptureAudioDataOutput()
        let delegate = MicAudioOutputDelegate(service: self)
        audioOutput.setSampleBufferDelegate(delegate, queue: micAudioQueue)

        guard session.canAddOutput(audioOutput) else {
            print("Cannot add audio output to mic capture session.")
            return
        }
        session.addOutput(audioOutput)

        session.startRunning()
        micCaptureSession = session
        micOutputDelegate = delegate
    }

    // MARK: - Mid-Recording Audio Control

    func setSystemAudioEnabled(_ enabled: Bool) {
        let muted = !enabled
        videoQueue.async { [weak self] in
            self?._isSystemAudioMuted = muted
        }
    }

    func switchMicrophone(to device: AVCaptureDevice?) async {
        if let device {
            // Switching to a (different) device — tear down old session, start new one
            micCaptureSession?.stopRunning()
            micCaptureSession = nil
            micOutputDelegate = nil
            videoQueue.async { [weak self] in self?._isMicMuted = false }
            await startMicCapture(device: device)
        } else {
            // "None" — keep session running so silent buffers maintain the timeline
            videoQueue.async { [weak self] in self?._isMicMuted = true }
        }
    }

    // MARK: - Pause / Resume

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        videoQueue.async { [weak self] in self?.videoQueuePaused = true }
        micCaptureSession?.stopRunning()
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        videoQueue.async { [weak self] in
            guard let self else { return }
            if self.pauseStartTime.isValid {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let pauseDuration = CMTimeSubtract(now, self.pauseStartTime)
                self.totalPauseOffset = CMTimeAdd(self.totalPauseOffset, pauseDuration)
                self.pauseStartTime = .invalid
            }
            self.videoQueuePaused = false
        }
        isPaused = false
        micCaptureSession?.startRunning()
    }

    // MARK: - Stop Recording

    func stopRecording() async throws -> URL {
        guard isRecording, let stream, let writer = assetWriter, let vInput = videoInput else {
            throw RecordingError.notRecording
        }

        // Stop mic capture session
        micCaptureSession?.stopRunning()
        micCaptureSession = nil
        micOutputDelegate = nil

        try await stream.stopCapture()
        self.stream = nil
        self.streamOutput = nil
        self.streamErrorDelegate = nil
        isRecording = false
        isPaused = false

        // Finish writing on the video queue (serializes after last buffer)
        let url = outputURL!
        let sysAudioIn = systemAudioInput
        let micAudioIn = micAudioInput
        let writerFailed = writer.status == .failed
        let writerErrorMsg = writer.error?.localizedDescription

        if !writerFailed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                videoQueue.async {
                    vInput.markAsFinished()
                    sysAudioIn?.markAsFinished()
                    micAudioIn?.markAsFinished()
                    writer.finishWriting {
                        continuation.resume()
                    }
                }
            }
        }

        let finalDropped = droppedFrameCount
        let finalTotal = totalFrameCount
        print("[ScreenSnipe] Recording stopped — \(finalTotal) frames, \(finalDropped) dropped, writer status: \(writer.status.rawValue)")
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 {
            print("[ScreenSnipe]   File size: \(String(format: "%.1f", Double(fileSize) / 1_048_576)) MB")
        }

        assetWriter = nil
        videoInput = nil
        systemAudioInput = nil
        micAudioInput = nil
        outputURL = nil
        sessionStarted = false
        pauseStartTime = .invalid
        totalPauseOffset = .zero
        videoQueuePaused = false
        _isSystemAudioMuted = false
        _isMicMuted = true

        if writerFailed {
            throw RecordingError.writerFailedDuringRecording(writerErrorMsg ?? "Unknown error")
        }

        return url
    }

    // MARK: - Sample Buffer Handling

    nonisolated func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            if self.videoQueuePaused {
                if !self.pauseStartTime.isValid {
                    self.pauseStartTime = sampleBuffer.presentationTimeStamp
                }
                return
            }
            guard let writer = self.assetWriter, let input = self.videoInput else { return }

            if writer.status == .failed {
                self.reportWriterFailure(writer)
                return
            }
            guard writer.status == .writing else { return }

            let adjusted = self.adjustedBuffer(sampleBuffer)

            if !self.sessionStarted {
                writer.startSession(atSourceTime: adjusted.presentationTimeStamp)
                self.sessionStarted = true
            }

            self.totalFrameCount += 1
            if input.isReadyForMoreMediaData {
                input.append(adjusted)
            } else {
                self.droppedFrameCount += 1
                if self.droppedFrameCount % 30 == 1 {
                    print("[ScreenSnipe] Dropped \(self.droppedFrameCount)/\(self.totalFrameCount) video frames (encoder can't keep up)")
                }
            }
        }
    }

    nonisolated func handleSystemAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            if self.videoQueuePaused { return }
            guard let writer = self.assetWriter, let input = self.systemAudioInput else { return }
            if writer.status == .failed { self.reportWriterFailure(writer); return }
            guard writer.status == .writing, self.sessionStarted else { return }

            let adjusted = self.adjustedBuffer(sampleBuffer)
            if self._isSystemAudioMuted {
                self.silenceBuffer(adjusted)
            }
            if input.isReadyForMoreMediaData {
                input.append(adjusted)
            }
        }
    }

    nonisolated func handleMicSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            if self.videoQueuePaused { return }
            guard let writer = self.assetWriter, let input = self.micAudioInput else { return }
            if writer.status == .failed { self.reportWriterFailure(writer); return }
            guard writer.status == .writing, self.sessionStarted else { return }

            let adjusted = self.adjustedBuffer(sampleBuffer)
            if self._isMicMuted {
                self.silenceBuffer(adjusted)
            }
            if input.isReadyForMoreMediaData {
                input.append(adjusted)
            }
        }
    }

    /// Reports a writer failure once, logging the error and publishing it to the UI.
    /// Called on videoQueue only.
    private nonisolated func reportWriterFailure(_ writer: AVAssetWriter) {
        guard !hasReportedWriterFailure else { return }
        hasReportedWriterFailure = true
        let errorMsg = writer.error?.localizedDescription ?? "Unknown error"
        let url = writer.outputURL
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let fileSizeMB = Double(fileSize) / 1_048_576
        print("[ScreenSnipe] AVAssetWriter FAILED — \(errorMsg)")
        print("[ScreenSnipe]   Status: \(writer.status.rawValue), frames written: \(totalFrameCount), dropped: \(droppedFrameCount)")
        print("[ScreenSnipe]   File size at failure: \(String(format: "%.1f", fileSizeMB)) MB")
        print("[ScreenSnipe]   Output URL: \(url.path)")
        DispatchQueue.main.async { [weak self] in
            self?.writerError = RecordingError.writerFailedDuringRecording(errorMsg)
        }
    }

    /// Zeros out audio sample data in-place so the buffer produces silence while preserving its timestamp.
    /// Called on videoQueue only.
    private nonisolated func silenceBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        if let dataPointer {
            memset(dataPointer, 0, length)
        }
    }

    /// Returns a directory for temporary recording files.
    /// Prefers the library directory if set, falling back to NSTemporaryDirectory.
    private static func recordingTempDirectory() -> URL {
        if let libraryURL = LibraryManager.shared.libraryURL {
            let fm = FileManager.default
            if fm.isWritableFile(atPath: libraryURL.path) {
                return libraryURL
            }
            try? fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            if fm.isWritableFile(atPath: libraryURL.path) {
                return libraryURL
            }
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// Adjusts the sample buffer's presentation timestamp by subtracting accumulated pause duration.
    /// Called on videoQueue only.
    private nonisolated func adjustedBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard totalPauseOffset > .zero else { return sampleBuffer }

        var timing = CMSampleTimingInfo(
            duration: sampleBuffer.duration,
            presentationTimeStamp: CMTimeSubtract(sampleBuffer.presentationTimeStamp, totalPauseOffset),
            decodeTimeStamp: sampleBuffer.decodeTimeStamp.isValid
                ? CMTimeSubtract(sampleBuffer.decodeTimeStamp, totalPauseOffset)
                : .invalid
        )

        var adjustedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjustedBuffer
        )
        return adjustedBuffer ?? sampleBuffer
    }
}

// MARK: - SCStreamOutput

private final class StreamOutputHandler: NSObject, SCStreamOutput, Sendable {
    private let service: VideoRecordingService

    init(service: VideoRecordingService) {
        self.service = service
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Check for invalid/empty frames
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusValue = attachments.first?[.status] as? Int,
                  statusValue == SCFrameStatus.complete.rawValue else {
                return
            }
            service.handleVideoSampleBuffer(sampleBuffer)

        case .audio:
            service.handleSystemAudioSampleBuffer(sampleBuffer)

        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate (error handling)

private final class StreamErrorDelegate: NSObject, SCStreamDelegate, Sendable {
    private let service: VideoRecordingService

    init(service: VideoRecordingService) {
        self.service = service
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("[ScreenSnipe] SCStream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.service.writerError = VideoRecordingService.RecordingError.writerFailedDuringRecording(
                "Stream error: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Microphone AVCaptureAudioDataOutput Delegate

private final class MicAudioOutputDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    private let service: VideoRecordingService

    init(service: VideoRecordingService) {
        self.service = service
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        service.handleMicSampleBuffer(sampleBuffer)
    }
}

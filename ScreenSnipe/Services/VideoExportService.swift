import AppKit
import AVFoundation
import ObjectiveC
import UniformTypeIdentifiers

@MainActor
enum VideoExportService {

    static func save(videoURL: URL, defaultName: String? = nil) {
        let asset = AVURLAsset(url: videoURL)
        let name = defaultName

        Task {
            let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
            let audioTrackCount = audioTracks?.count ?? 0

            await MainActor.run {
                showSavePanel(videoURL: videoURL, audioTrackCount: audioTrackCount, defaultName: name)
            }
        }
    }

    private static func showSavePanel(videoURL: URL, audioTrackCount: Int, defaultName: String? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let baseName = defaultName ?? "Recording"
        panel.nameFieldStringValue = "\(baseName).mp4"
        panel.canCreateDirectories = true

        // Accessory view with audio track option
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 70))

        let label = NSTextField(labelWithString: "Audio tracks:")
        label.frame = NSRect(x: 0, y: 44, width: 90, height: 20)
        container.addSubview(label)

        let popup = NSPopUpButton(frame: NSRect(x: 94, y: 40, width: 220, height: 26), pullsDown: false)
        popup.addItems(withTitles: ["Merge into one track", "Independent tracks"])
        popup.selectItem(at: 0)
        if audioTrackCount <= 1 {
            popup.isEnabled = false
        }
        container.addSubview(popup)

        let hint = NSTextField(wrappingLabelWithString: AudioTrackHintHandler.mergeHint)
        hint.frame = NSRect(x: 0, y: 8, width: 320, height: 28)
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        container.addSubview(hint)

        let hintHandler = AudioTrackHintHandler(hint: hint)
        popup.target = hintHandler
        popup.action = #selector(AudioTrackHintHandler.popupChanged(_:))
        objc_setAssociatedObject(popup, "hintHandler", hintHandler, .OBJC_ASSOCIATION_RETAIN)

        panel.accessoryView = container

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let mergeAudio = popup.isEnabled && popup.indexOfSelectedItem == 0

        if mergeAudio {
            exportWithMergedAudio(sourceURL: videoURL, destinationURL: destinationURL)
        } else {
            copyVideo(sourceURL: videoURL, destinationURL: destinationURL)
        }
    }

    private static func copyVideo(sourceURL: URL, destinationURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            showError("Failed to save video: \(error.localizedDescription)")
        }
    }

    private static func exportWithMergedAudio(sourceURL: URL, destinationURL: URL) {
        let window = NSApp.keyWindow

        // Build a button-free progress sheet
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 70),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        sheet.title = "Exporting Video"

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 70))

        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        contentView.addSubview(spinner)

        let label = NSTextField(labelWithString: "Exporting video…")
        label.frame = NSRect(x: 52, y: 26, width: 190, height: 20)
        contentView.addSubview(label)

        sheet.contentView = contentView

        window?.beginSheet(sheet)

        Task.detached {
            let result = await VideoExportMerger.performMerge(sourceURL: sourceURL, destinationURL: destinationURL)

            await MainActor.run {
                window?.endSheet(sheet)

                if case .failure(let error) = result {
                    showError("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    fileprivate static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Video Export"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
private final class AudioTrackHintHandler: NSObject {
    static let mergeHint = "Combines all audio into one track for wider player compatibility."
    static let independentHint = "Keeps tracks separate so you can remove system sounds or voiceover when editing."

    private let hint: NSTextField

    init(hint: NSTextField) {
        self.hint = hint
    }

    @objc func popupChanged(_ sender: NSPopUpButton) {
        hint.stringValue = sender.indexOfSelectedItem == 0
            ? Self.mergeHint
            : Self.independentHint
    }
}

// Nonisolated helper to avoid @MainActor inheritance on AV types
private enum VideoExportMerger {

    enum ExportError: LocalizedError {
        case noVideoTrack
        case readerSetupFailed
        case writerSetupFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "Source video has no video track."
            case .readerSetupFailed: "Failed to set up video reader."
            case .writerSetupFailed: "Failed to set up video writer."
            }
        }
    }

    static func performMerge(sourceURL: URL, destinationURL: URL) async -> Result<Void, Error> {
        let asset = AVURLAsset(url: sourceURL)

        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            guard let videoTrack = videoTracks.first else {
                return .failure(ExportError.noVideoTrack)
            }

            // Remove destination if it exists
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            // Setup reader
            let reader = try AVAssetReader(asset: asset)

            // Video: passthrough (no re-encode)
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            guard reader.canAdd(videoOutput) else {
                return .failure(ExportError.readerSetupFailed)
            }
            reader.add(videoOutput)

            // Audio: mix all tracks together
            let audioMix = AVMutableAudioMix()
            var inputParameters: [AVMutableAudioMixInputParameters] = []
            for track in audioTracks {
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(1.0, at: .zero)
                inputParameters.append(params)
            }
            audioMix.inputParameters = inputParameters

            let audioMixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
            ])
            audioMixOutput.audioMix = audioMix
            guard reader.canAdd(audioMixOutput) else {
                return .failure(ExportError.readerSetupFailed)
            }
            reader.add(audioMixOutput)

            guard reader.startReading() else {
                return .failure(reader.error ?? ExportError.readerSetupFailed)
            }

            // Setup writer
            let writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)

            // Video input: passthrough
            let videoFormatDescs = try await videoTrack.load(.formatDescriptions)
            let videoInput: AVAssetWriterInput
            if let formatDesc = videoFormatDescs.first {
                videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDesc)
            } else {
                videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
            }
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else {
                return .failure(ExportError.writerSetupFailed)
            }
            writer.add(videoInput)

            // Audio input: AAC encoding
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else {
                return .failure(ExportError.writerSetupFailed)
            }
            writer.add(audioInput)

            guard writer.startWriting() else {
                return .failure(writer.error ?? ExportError.writerSetupFailed)
            }
            writer.startSession(atSourceTime: .zero)

            // Process video and audio in parallel
            await transferAllSamples(
                videoOutput: videoOutput, videoInput: videoInput,
                audioOutput: audioMixOutput, audioInput: audioInput
            )

            await writer.finishWriting()

            if writer.status == .failed {
                return .failure(writer.error ?? ExportError.writerSetupFailed)
            }

            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func transferAllSamples(
        videoOutput: AVAssetReaderOutput, videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderOutput, audioInput: AVAssetWriterInput
    ) async {
        // Bridge non-Sendable AV types across isolation boundary
        nonisolated(unsafe) let vOut = videoOutput
        nonisolated(unsafe) let vIn = videoInput
        nonisolated(unsafe) let aOut = audioOutput
        nonisolated(unsafe) let aIn = audioInput

        async let videoDone: Void = transferSamples(from: vOut, to: vIn)
        async let audioDone: Void = transferSamples(from: aOut, to: aIn)
        _ = await (videoDone, audioDone)
    }

    private static func transferSamples(
        from output: sending AVAssetReaderOutput,
        to input: sending AVAssetWriterInput
    ) async {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "com.screensnipe.export.\(input.mediaType.rawValue)")) {
                while input.isReadyForMoreMediaData {
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

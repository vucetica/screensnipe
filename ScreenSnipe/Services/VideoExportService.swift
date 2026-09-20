import AppKit
import AVFoundation
import ObjectiveC
import UniformTypeIdentifiers

@MainActor
enum VideoExportService {

    /// - Parameter trim: the entry's stored range, or nil to export the whole
    ///   recording. When nil the untrimmed paths below are byte-for-byte what
    ///   they have always been.
    static func save(videoURL: URL, trim: CMTimeRange? = nil, defaultName: String? = nil) {
        let asset = AVURLAsset(url: videoURL)
        let name = defaultName

        Task {
            let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
            let audioTrackCount = audioTracks?.count ?? 0

            await MainActor.run {
                showSavePanel(videoURL: videoURL, trim: trim, audioTrackCount: audioTrackCount, defaultName: name)
            }
        }
    }

    /// Shares a recording, exporting the trimmed range to a temp file first when
    /// there is one. Untrimmed sharing still hands over the original file
    /// immediately, with no sheet and no copy.
    static func share(videoURL: URL, trim: CMTimeRange?, name: String, from sender: NSView) {
        guard trim != nil else {
            presentPicker(for: videoURL, from: sender)
            return
        }

        let window = NSApp.keyWindow
        let sheet = progressSheet(title: "Preparing Video", message: "Trimming video…", determinate: false, onCancel: nil)
        window?.beginSheet(sheet.panel)

        Task {
            defer { window?.endSheet(sheet.panel) }
            do {
                let staged = try await VideoTrimStaging.materialize(videoURL: videoURL, trim: trim, name: name)
                // The toolbar item can be gone by now if the window closed.
                guard sender.window != nil else { return }
                // Not discarded here: the sharing service reads the file
                // asynchronously after the picker returns. The staging directory
                // is swept at launch instead.
                presentPicker(for: staged, from: sender)
            } catch is CancellationError {
                return
            } catch {
                showError("Failed to prepare video for sharing: \(error.localizedDescription)")
            }
        }
    }

    private static func presentPicker(for url: URL, from sender: NSView) {
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private static func showSavePanel(videoURL: URL, trim: CMTimeRange?, audioTrackCount: Int, defaultName: String? = nil) {
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

        if let trim {
            // This is what stops "Independent tracks" being a plain file copy
            // once a trim exists: it becomes a real export that still gives each
            // source audio track its own track in the output.
            exportTrimmed(
                sourceURL: videoURL,
                destinationURL: destinationURL,
                range: trim,
                audioMode: mergeAudio ? .mergeToSingleTrack : .preserveTracks
            )
        } else if mergeAudio {
            exportWithMergedAudio(sourceURL: videoURL, destinationURL: destinationURL)
        } else {
            copyVideo(sourceURL: videoURL, destinationURL: destinationURL)
        }
    }

    private static func exportTrimmed(
        sourceURL: URL,
        destinationURL: URL,
        range: CMTimeRange,
        audioMode: VideoTrimExporter.AudioMode
    ) {
        let window = NSApp.keyWindow
        var task: Task<Void, Never>?
        let sheet = progressSheet(
            title: "Exporting Video",
            message: "Exporting trimmed video…",
            determinate: true,
            onCancel: { task?.cancel() }
        )
        window?.beginSheet(sheet.panel)

        task = Task {
            defer { window?.endSheet(sheet.panel) }
            do {
                try await VideoTrimExporter.export(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    range: range,
                    audioMode: audioMode,
                    progress: { fraction in
                        Task { @MainActor in sheet.setProgress(fraction) }
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                showError("Export failed: \(error.localizedDescription)")
            }
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
        let sheet = progressSheet(title: "Exporting Video", message: "Exporting video…", determinate: false, onCancel: nil)
        window?.beginSheet(sheet.panel)

        Task.detached {
            let result = await VideoExportMerger.performMerge(sourceURL: sourceURL, destinationURL: destinationURL)

            await MainActor.run {
                window?.endSheet(sheet.panel)

                if case .failure(let error) = result {
                    showError("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Progress Sheet

    /// Shared by every long-running video export.
    ///
    /// Determinate with a Cancel button for trimmed exports, which re-encode and
    /// can take a while; an indeterminate spinner with no button for the
    /// audio-merge path, which is what it has always shown.
    private static func progressSheet(
        title: String,
        message: String,
        determinate: Bool,
        onCancel: (() -> Void)?
    ) -> ProgressSheet {
        let height: CGFloat = onCancel == nil ? 70 : 108
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = title

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        let topRow = height - 46

        let indicator: NSProgressIndicator
        let label: NSTextField
        if determinate {
            indicator = NSProgressIndicator(frame: NSRect(x: 20, y: topRow - 4, width: 260, height: 20))
            indicator.style = .bar
            indicator.isIndeterminate = false
            indicator.minValue = 0
            indicator.maxValue = 1
            indicator.doubleValue = 0
            label = NSTextField(labelWithString: message)
            label.frame = NSRect(x: 20, y: topRow + 20, width: 260, height: 20)
        } else {
            indicator = NSProgressIndicator(frame: NSRect(x: 20, y: topRow, width: 24, height: 24))
            indicator.style = .spinning
            indicator.startAnimation(nil)
            label = NSTextField(labelWithString: message)
            label.frame = NSRect(x: 52, y: topRow + 2, width: 228, height: 20)
        }
        contentView.addSubview(indicator)
        contentView.addSubview(label)

        if let onCancel {
            let handler = ProgressSheetCanceller(action: onCancel)
            let button = NSButton(title: "Cancel", target: handler, action: #selector(ProgressSheetCanceller.cancel))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 196, y: 16, width: 84, height: 24)
            contentView.addSubview(button)
            // The button's target is unowned, so the handler has to outlive this
            // function; the panel is the natural owner.
            objc_setAssociatedObject(panel, "cancelHandler", handler, .OBJC_ASSOCIATION_RETAIN)
        }

        panel.contentView = contentView
        return ProgressSheet(panel: panel, indicator: determinate ? indicator : nil)
    }

    /// A class rather than a struct so that, being `@MainActor`-isolated, it is
    /// Sendable and the exporter's `@Sendable` progress callback can hop back to
    /// it without carrying the AppKit views across the boundary.
    @MainActor
    final class ProgressSheet {
        let panel: NSPanel
        private let indicator: NSProgressIndicator?

        init(panel: NSPanel, indicator: NSProgressIndicator?) {
            self.panel = panel
            self.indicator = indicator
        }

        func setProgress(_ fraction: Double) {
            indicator?.doubleValue = fraction
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
private final class ProgressSheetCanceller: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func cancel() {
        action()
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

import Foundation
import Combine
import AppKit

@MainActor
final class LibraryViewModel: ObservableObject {
    static let shared = LibraryViewModel()

    @Published var selectedEntryIDs: Set<String> = []
    @Published var selectedEntryID: String?
    @Published var activeTool: EditorTool = .selection
    @Published var showInspector = true
    @Published var searchQuery: String = ""
    var selectedImage: NSImage?
    var selectedVideoURL: URL?
    var currentToolHandler: ToolHandler?

    /// Manifest frame index currently loaded into the editor, or nil when the
    /// selected entry is not a series.
    @Published private(set) var currentFrameIndex: Int?
    private(set) var currentSeriesManifest: SeriesManifest?

    // Stitch state
    @Published var showStitchDialog = false
    @Published var showStitchProgress = false
    @Published var stitchProgress: Double = 0
    @Published var stitchError: String?
    var stitchEntries: [LibraryEntry] = []
    private var stitchTask: Task<Void, Never>?

    // iCloud link state
    @Published var showShareLinkProgress = false
    private var shareLinkTask: Task<Void, Never>?

    let annotationStore = AnnotationStore()

    private var cancellables: Set<AnyCancellable> = []
    private var currentEntryID: String?

    /// Identifies exactly which file a pending save belongs to. Stamped when the
    /// save is *scheduled*, so a save can never land in a file the user has
    /// since navigated away from.
    private struct SaveTarget: Equatable, Sendable {
        let entryID: String
        /// Manifest frame index for series entries; nil for image and video.
        let frameIndex: Int?
    }

    private var saveTask: Task<Void, Never>?
    private var pendingSaveTarget: SaveTarget?

    private init() {
        // Scheduling is owned explicitly rather than using Combine's debounce,
        // because a debounce cannot be flushed. Switching entries or frames must
        // be able to write pending edits to the file they were made in before
        // the store's contents are swapped.
        let editSignals: [AnyPublisher<Void, Never>] = [
            annotationStore.$annotations.map { _ in () }.eraseToAnyPublisher(),
            annotationStore.$cropRect.map { _ in () }.eraseToAnyPublisher(),
            annotationStore.$magnification.map { _ in () }.eraseToAnyPublisher(),
        ]
        for signal in editSignals {
            signal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.scheduleAutoSave()
                }
                .store(in: &cancellables)
        }

        // Derive selectedEntryID from selectedEntryIDs
        $selectedEntryIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                guard let self else { return }
                switch ids.count {
                case 1:
                    self.selectedEntryID = ids.first
                default:
                    // 0 or 2+ selected → nil (show empty/multi-select state)
                    self.selectedEntryID = nil
                }
            }
            .store(in: &cancellables)

        $selectedEntryID
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadSelectedEntry()
            }
            .store(in: &cancellables)
    }

    var entries: [LibraryEntry] {
        let all = LibraryManager.shared.entries
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        let (filters, text) = Self.parseSearchQuery(query)
        return all.filter { entry in
            guard filters.allSatisfy({ $0.matches(entry) }) else { return false }
            guard !text.isEmpty else { return true }
            let name = entry.metadata.name ?? Self.defaultName(for: entry)
            if name.localizedCaseInsensitiveContains(text) { return true }
            if Self.rowDisplayDate(for: entry).localizedCaseInsensitiveContains(text) { return true }
            if let description = entry.metadata.description,
               description.localizedCaseInsensitiveContains(text) { return true }
            return entry.metadata.tags.contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    /// A structured `is:` filter parsed from the search query.
    enum SearchFilter: String, CaseIterable {
        case shared
        case image
        case video
        case series

        func matches(_ entry: LibraryEntry) -> Bool {
            switch self {
            case .shared: entry.metadata.shareURL != nil
            case .image: entry.mediaType == .image
            case .video: entry.mediaType == .video
            case .series: entry.mediaType == .series
            }
        }
    }

    /// Splits a raw query into `is:` filters and the remaining free text.
    /// Unrecognized `is:` values stay in the free text so they still match literally.
    static func parseSearchQuery(_ query: String) -> (filters: [SearchFilter], text: String) {
        var filters: [SearchFilter] = []
        var textTokens: [String] = []
        for token in query.split(separator: " ") {
            let lowered = token.lowercased()
            if lowered.hasPrefix("is:"), let filter = SearchFilter(rawValue: String(lowered.dropFirst(3))) {
                filters.append(filter)
            } else {
                textTokens.append(String(token))
            }
        }
        return (filters, textTokens.joined(separator: " "))
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return f
    }()

    private static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func defaultName(for entry: LibraryEntry) -> String {
        let timestamp = exportDateFormatter.string(from: entry.captureDate)
        return "\(entry.mediaType.exportPrefix) \(timestamp)"
    }

    /// Date string shown in the library sidebar row when an entry has no custom name
    /// (e.g. "May 13, 2026 at 3:42 PM"). Kept here so search and rendering stay in sync.
    static func rowDisplayDate(for entry: LibraryEntry) -> String {
        rowDateFormatter.string(from: entry.captureDate)
    }

    /// Returns the export filename (without extension) for the currently selected entry.
    var selectedExportName: String? {
        guard let id = selectedEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else { return nil }
        return entry.name ?? Self.defaultName(for: entry)
    }

    func refreshLibrary() {
        LibraryManager.shared.reload()
        objectWillChange.send()
    }

    func deleteSelectedEntry() {
        guard let id = selectedEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else { return }
        deleteEntry(entry)
    }

    func deleteEntry(_ entry: LibraryEntry) {
        // Drop, don't flush: the folder is about to go away.
        if entry.id == currentEntryID {
            cancelPendingSave()
        }
        do {
            try LibraryManager.shared.delete(entry: entry)
        } catch {
            ErrorReporter.report(error, context: "Failed to delete capture")
        }
        selectedEntryIDs.remove(entry.id)
        objectWillChange.send()
    }

    // MARK: - Loading

    private func loadSelectedEntry() {
        // Write the outgoing entry's pending edits before anything is retargeted.
        flushPendingSave()

        currentEntryID = selectedEntryID
        currentFrameIndex = nil
        currentSeriesManifest = nil
        activeTool = .selection

        guard let id = selectedEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else {
            selectedImage = nil
            selectedVideoURL = nil
            annotationStore.replaceAllWithoutUndo([])
            objectWillChange.send()
            return
        }

        switch entry.mediaType {
        case .image:
            selectedImage = entry.mediaURL.flatMap { NSImage(contentsOf: $0) }
            selectedVideoURL = nil
        case .video:
            selectedImage = nil
            selectedVideoURL = entry.mediaURL
        case .series:
            selectedVideoURL = nil
            loadSeries(entry)
            return
        }

        let result: (annotations: [AnyAnnotation], cropRect: CGRect?, magnification: CGFloat?)
        do {
            result = try LibraryManager.shared.loadAnnotations(for: entry)
        } catch {
            ErrorReporter.log(error, context: "Failed to load annotations for \(entry.id)")
            result = (annotations: [], cropRect: nil, magnification: nil)
        }
        annotationStore.replaceAllWithoutUndo(result.annotations, cropRect: result.cropRect, magnification: result.magnification)
        objectWillChange.send()
    }

    // MARK: - Series Frames

    /// Ordered frames of the selected series, or an empty array for other entries.
    var seriesFrames: [SeriesManifest.Frame] {
        currentSeriesManifest?.frames ?? []
    }

    /// 1-based position of the current frame, for "Frame N of M".
    var currentFramePosition: Int? {
        guard let index = currentFrameIndex else { return nil }
        return currentSeriesManifest?.position(of: index).map { $0 + 1 }
    }

    var canGoToPreviousFrame: Bool {
        guard let position = currentFramePosition else { return false }
        return position > 1
    }

    var canGoToNextFrame: Bool {
        guard let position = currentFramePosition else { return false }
        return position < seriesFrames.count
    }

    /// Absolute URL of a frame's PNG, for the filmstrip.
    func frameImageURL(_ frame: SeriesManifest.Frame) -> URL? {
        guard let id = currentEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else { return nil }
        return entry.url(forFramePath: frame.file)
    }

    private func loadSeries(_ entry: LibraryEntry) {
        do {
            currentSeriesManifest = try LibraryManager.shared.loadSeriesManifest(for: entry)
        } catch {
            ErrorReporter.log(error, context: "Failed to load series manifest for \(entry.id)")
            currentSeriesManifest = nil
        }
        guard let first = currentSeriesManifest?.frames.first else {
            selectedImage = nil
            annotationStore.replaceAllWithoutUndo([])
            objectWillChange.send()
            return
        }
        applyFrame(first, of: entry)
    }

    /// Switches the editor to a different frame of the currently selected series.
    /// `index` is the manifest frame index, not the filmstrip position.
    func loadFrame(_ index: Int) {
        guard let id = currentEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }),
              entry.mediaType == .series,
              let frame = currentSeriesManifest?.frame(at: index),
              index != currentFrameIndex else { return }

        // Frame N's edits go to frame N's file, before the target is moved.
        flushPendingSave()
        applyFrame(frame, of: entry)
    }

    func goToPreviousFrame() {
        guard let position = currentFramePosition, position > 1 else { return }
        loadFrame(seriesFrames[position - 2].index)
    }

    func goToNextFrame() {
        guard let position = currentFramePosition, position < seriesFrames.count else { return }
        loadFrame(seriesFrames[position].index)
    }

    /// Loads a frame's image and annotations into the shared editor state.
    ///
    /// The retarget happens before the store is refilled, so the save that the
    /// refill schedules is stamped with the *new* frame and writes the
    /// just-loaded annotations back into their own file. That round-trip is
    /// idempotent because the serializer preserves annotation identity. A
    /// timing-based "is loading" flag would not work here: the edit sinks are
    /// asynchronous, so they run after any such flag was reset.
    private func applyFrame(_ frame: SeriesManifest.Frame, of entry: LibraryEntry) {
        currentFrameIndex = frame.index
        activeTool = .selection
        selectedImage = NSImage(contentsOf: entry.url(forFramePath: frame.file))
        selectedVideoURL = nil

        let result: (annotations: [AnyAnnotation], cropRect: CGRect?, magnification: CGFloat?)
        do {
            result = try LibraryManager.shared.loadAnnotations(at: entry.url(forFramePath: frame.annotations))
        } catch {
            result = (annotations: [], cropRect: nil, magnification: nil)
        }
        annotationStore.replaceAllWithoutUndo(result.annotations, cropRect: result.cropRect, magnification: result.magnification)
        objectWillChange.send()
    }

    /// Every frame of the selected series, flattened-ready, for a multi-page export.
    ///
    /// The frame currently open in the editor is taken from the live store so
    /// unsaved edits are included; the rest are read from disk.
    func seriesExportFrames() -> [ImageExportService.SeriesExportFrame] {
        guard let id = currentEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }),
              let manifest = currentSeriesManifest else { return [] }

        return manifest.frames.compactMap { frame in
            if frame.index == currentFrameIndex, let image = selectedImage {
                return ImageExportService.SeriesExportFrame(
                    image: image,
                    annotations: annotationStore.annotations,
                    cropRect: annotationStore.cropRect
                )
            }
            guard let image = NSImage(contentsOf: entry.url(forFramePath: frame.file)) else { return nil }
            let result = try? LibraryManager.shared.loadAnnotations(at: entry.url(forFramePath: frame.annotations))
            return ImageExportService.SeriesExportFrame(
                image: image,
                annotations: result?.annotations ?? [],
                cropRect: result?.cropRect
            )
        }
    }

    /// Removes a frame from the series, keeping its files' siblings intact.
    /// Frame indices are never renumbered, so nothing else on disk moves.
    func deleteFrame(_ index: Int) {
        guard let id = currentEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }),
              var manifest = currentSeriesManifest,
              let position = manifest.position(of: index),
              manifest.frames.count > 1 else { return }

        if index == currentFrameIndex {
            cancelPendingSave()
        } else {
            flushPendingSave()
        }

        let frame = manifest.frames.remove(at: position)
        try? FileManager.default.removeItem(at: entry.url(forFramePath: frame.file))
        try? FileManager.default.removeItem(at: entry.url(forFramePath: frame.annotations))
        do {
            try LibraryManager.shared.saveSeriesManifest(manifest, for: entry)
        } catch {
            ErrorReporter.report(error, context: "Failed to update series")
            return
        }
        currentSeriesManifest = manifest

        if index == currentFrameIndex {
            let neighbour = manifest.frames[min(position, manifest.frames.count - 1)]
            currentFrameIndex = nil
            applyFrame(neighbour, of: entry)
        } else {
            objectWillChange.send()
        }
    }

    // MARK: - Metadata

    func updateMetadata(for entry: LibraryEntry, name: String?, description: String?, tags: [String]) {
        var metadata = entry.metadata
        metadata.name = name
        metadata.description = description
        metadata.tags = tags
        do {
            try LibraryManager.shared.saveMetadata(metadata, for: entry)
        } catch {
            ErrorReporter.log(error, context: "Failed to save metadata for \(entry.id)")
        }
        objectWillChange.send()
    }

    // MARK: - Stitch

    func beginStitch() {
        let allEntries = LibraryManager.shared.entries
        stitchEntries = allEntries
            .filter { selectedEntryIDs.contains($0.id) }
            .sorted { $0.captureDate < $1.captureDate }
        showStitchDialog = true
    }

    func performStitch(_ config: StitchConfiguration) {
        stitchProgress = 0
        showStitchProgress = true
        stitchError = nil

        // Resolve library URL on MainActor before detaching
        let libraryDir = LibraryManager.shared.libraryURL ?? URL(fileURLWithPath: NSTemporaryDirectory())

        // Task.detached avoids inheriting @MainActor — the synchronous
        // frame-writing loops in StitchService would otherwise block the main thread.
        stitchTask = Task.detached {
            do {
                let outputURL = try await StitchService.stitch(config: config, tempDirectory: libraryDir) { fraction in
                    self.stitchProgress = fraction
                }

                guard await LibraryManager.shared.ensureLibraryLocation() else {
                    await MainActor.run { self.showStitchProgress = false }
                    return
                }

                try await MainActor.run {
                    let entry = try LibraryManager.shared.saveVideo(from: outputURL)
                    self.showStitchProgress = false
                    self.objectWillChange.send()
                    self.selectedEntryIDs = [entry.id]
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.showStitchProgress = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.showStitchProgress = false
                    self.stitchError = message
                    ErrorReporter.report(error, context: "Failed to stitch captures")
                }
            }
        }
    }

    func cancelStitch() {
        stitchTask?.cancel()
        stitchTask = nil
        showStitchProgress = false
    }

    // MARK: - iCloud Link

    /// Copies a public iCloud link for the entry to the clipboard, publishing one
    /// first if no valid link exists yet.
    func copyICloudLink(for entry: LibraryEntry) {
        if let existing = entry.metadata.shareURL,
           (entry.metadata.shareExpiration ?? .distantFuture) > Date() {
            copyLinkToClipboard(existing)
            showLinkCopiedToast()
            return
        }

        // Flatten on the main actor before handing Sendable data to the service.
        let payload: ICloudSharePayload
        switch entry.mediaType {
        case .image, .series:
            // For a series this publishes the frame currently open in the editor.
            guard let data = flattenedPNGData(for: entry) else {
                ErrorReporter.report(
                    NSError(domain: "LibraryViewModel", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to render the image for sharing"]),
                    context: "Failed to create iCloud link"
                )
                return
            }
            payload = .imageData(data)
        case .video:
            guard let url = entry.mediaURL else { return }
            payload = .file(url)
        }

        showShareLinkProgress = true
        shareLinkTask = Task {
            do {
                let link: ICloudShareService.PublishedLink
                switch payload {
                case .imageData(let data):
                    link = try await ICloudShareService.publish(data: data, entryID: entry.id, fileExtension: "png")
                case .file(let url):
                    link = try await ICloudShareService.publish(fileAt: url, entryID: entry.id)
                }
                var metadata = entry.metadata
                metadata.shareURL = link.url
                metadata.shareExpiration = link.expiration
                do {
                    try LibraryManager.shared.saveMetadata(metadata, for: entry)
                } catch {
                    ErrorReporter.log(error, context: "Failed to save share link for \(entry.id)")
                }
                showShareLinkProgress = false
                copyLinkToClipboard(link.url)
                confirmLinkPublished()
                objectWillChange.send()
            } catch is CancellationError {
                showShareLinkProgress = false
            } catch {
                showShareLinkProgress = false
                ErrorReporter.report(error, context: "Failed to create iCloud link")
            }
        }
    }

    func copyICloudLinkForSelection() {
        guard let id = selectedEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else { return }
        copyICloudLink(for: entry)
    }

    func cancelShareLink() {
        shareLinkTask?.cancel()
        shareLinkTask = nil
        showShareLinkProgress = false
    }

    /// Deletes the shared copy from the iCloud container (invalidating the link)
    /// and clears the share fields from the entry's metadata.
    func stopSharing(_ entry: LibraryEntry) {
        Task {
            do {
                try await ICloudShareService.revoke(entryID: entry.id)
                var metadata = entry.metadata
                metadata.shareURL = nil
                metadata.shareExpiration = nil
                try LibraryManager.shared.saveMetadata(metadata, for: entry)
                objectWillChange.send()
            } catch {
                ErrorReporter.report(error, context: "Failed to stop sharing")
            }
        }
    }

    private enum ICloudSharePayload {
        case imageData(Data)
        case file(URL)
    }

    private static let shareLinkInfoShownKey = "icloudLinkInfoShown"

    private func copyLinkToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    private func showLinkCopiedToast() {
        CopiedToast.show(in: LibraryWindow.current ?? NSApp.keyWindow, message: "iCloud link copied")
    }

    /// After a publish: a one-time alert explaining the clipboard and where to
    /// find the link again; a toast on every later share. Delayed slightly so the
    /// progress sheet finishes dismissing before another sheet or toast appears.
    private func confirmLinkPublished() {
        let firstTime = !UserDefaults.standard.bool(forKey: Self.shareLinkInfoShownKey)
        if firstTime {
            UserDefaults.standard.set(true, forKey: Self.shareLinkInfoShownKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard firstTime else {
                self.showLinkCopiedToast()
                return
            }
            let alert = NSAlert()
            alert.messageText = "iCloud Link Copied"
            alert.informativeText = "A public link to this capture is now on your clipboard. Paste it anywhere; anyone with the link can download the file.\n\nTo copy the link again or to stop sharing, right-click the capture in the library."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            if let window = LibraryWindow.current {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    /// Renders the entry's annotated image to PNG data. Uses the live annotation
    /// store for the selected entry so unsaved edits are included; other entries
    /// load from disk.
    private func flattenedPNGData(for entry: LibraryEntry) -> Data? {
        let image: NSImage?
        let annotations: [AnyAnnotation]
        let cropRect: CGRect?
        if entry.id == selectedEntryID, let selected = selectedImage {
            image = selected
            annotations = annotationStore.annotations
            cropRect = annotationStore.cropRect
        } else if entry.mediaType == .series {
            // Not the selected entry, so fall back to the series' first frame.
            let manifest = try? SeriesManifest.load(from: entry.seriesManifestURL)
            if let frame = manifest?.frames.first {
                image = NSImage(contentsOf: entry.url(forFramePath: frame.file))
                let result = try? LibraryManager.shared.loadAnnotations(at: entry.url(forFramePath: frame.annotations))
                annotations = result?.annotations ?? []
                cropRect = result?.cropRect
            } else {
                image = nil
                annotations = []
                cropRect = nil
            }
        } else {
            image = entry.mediaURL.flatMap { NSImage(contentsOf: $0) }
            if let result = try? LibraryManager.shared.loadAnnotations(for: entry) {
                annotations = result.annotations
                cropRect = result.cropRect
            } else {
                annotations = []
                cropRect = nil
            }
        }
        guard let image else { return nil }
        let flattened = ImageExportService.flatten(image: image, annotations: annotations, cropRect: cropRect)
        guard let tiffData = flattened.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }

    // MARK: - Auto-save

    private var currentSaveTarget: SaveTarget? {
        guard let id = currentEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else { return nil }
        return SaveTarget(entryID: id, frameIndex: entry.mediaType == .series ? currentFrameIndex : nil)
    }

    private func scheduleAutoSave() {
        guard let target = currentSaveTarget else { return }
        saveTask?.cancel()
        pendingSaveTarget = target
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.pendingSaveTarget = nil
            self.saveTask = nil
            self.performSave(to: target)
        }
    }

    /// Writes any pending annotation edits to the file they were actually made in.
    ///
    /// Must be called *before* the annotation store's contents are swapped for a
    /// different entry or frame, while the store still holds the old contents.
    /// Without it, a save still in flight fires after the swap and writes the
    /// newly loaded annotations into the previous file, losing the last edits
    /// with no error.
    func flushPendingSave() {
        guard let target = pendingSaveTarget else { return }
        saveTask?.cancel()
        saveTask = nil
        pendingSaveTarget = nil
        performSave(to: target)
    }

    /// Drops a pending save without writing it. Used when the target file is
    /// about to be deleted, so the write does not race the removal and report a
    /// spurious failure.
    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        pendingSaveTarget = nil
    }

    private func performSave(to target: SaveTarget) {
        guard let entry = LibraryManager.shared.entries.first(where: { $0.id == target.entryID }) else { return }
        do {
            if let frameIndex = target.frameIndex {
                guard let frame = currentSeriesManifest?.frame(at: frameIndex) else { return }
                try LibraryManager.shared.saveAnnotations(
                    annotationStore.annotations,
                    cropRect: annotationStore.cropRect,
                    magnification: annotationStore.magnification,
                    to: entry.url(forFramePath: frame.annotations)
                )
            } else {
                try LibraryManager.shared.saveAnnotations(
                    annotationStore.annotations,
                    cropRect: annotationStore.cropRect,
                    magnification: annotationStore.magnification,
                    for: entry
                )
            }
        } catch {
            ErrorReporter.report(error, context: "Failed to save annotations")
        }
    }
}


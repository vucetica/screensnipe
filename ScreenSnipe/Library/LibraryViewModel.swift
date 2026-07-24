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

    private init() {
        annotationStore.$annotations
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.autoSave()
            }
            .store(in: &cancellables)

        annotationStore.$cropRect
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.autoSave()
            }
            .store(in: &cancellables)

        annotationStore.$magnification
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.autoSave()
            }
            .store(in: &cancellables)

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

        func matches(_ entry: LibraryEntry) -> Bool {
            switch self {
            case .shared: entry.metadata.shareURL != nil
            case .image: entry.mediaType == .image
            case .video: entry.mediaType == .video
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
        let typePrefix = entry.mediaType == .image ? "Screenshot" : "Recording"
        let timestamp = exportDateFormatter.string(from: entry.captureDate)
        return "\(typePrefix) \(timestamp)"
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
        currentEntryID = selectedEntryID
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
            selectedImage = NSImage(contentsOf: entry.mediaURL)
            selectedVideoURL = nil
        case .video:
            selectedImage = nil
            selectedVideoURL = entry.mediaURL
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
        case .image:
            guard let data = flattenedPNGData(for: entry) else {
                ErrorReporter.report(
                    NSError(domain: "LibraryViewModel", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to render the image for sharing"]),
                    context: "Failed to create iCloud link"
                )
                return
            }
            payload = .imageData(data)
        case .video:
            payload = .file(entry.mediaURL)
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
        } else {
            image = NSImage(contentsOf: entry.mediaURL)
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

    private func autoSave() {
        guard let id = currentEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else { return }
        do {
            try LibraryManager.shared.saveAnnotations(annotationStore.annotations, cropRect: annotationStore.cropRect, magnification: annotationStore.magnification, for: entry)
        } catch {
            ErrorReporter.report(error, context: "Failed to save annotations")
        }
    }
}


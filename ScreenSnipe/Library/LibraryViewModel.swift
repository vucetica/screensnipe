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
        LibraryManager.shared.entries
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return f
    }()

    /// Returns the export filename (without extension) for the currently selected entry.
    var selectedExportName: String? {
        guard let id = selectedEntryID,
              let entry = LibraryManager.shared.entries.first(where: { $0.id == id }) else { return nil }
        if let name = entry.name { return name }
        let typePrefix = entry.mediaType == .image ? "Screenshot" : "Recording"
        let timestamp = Self.exportDateFormatter.string(from: entry.captureDate)
        return "\(typePrefix) \(timestamp)"
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

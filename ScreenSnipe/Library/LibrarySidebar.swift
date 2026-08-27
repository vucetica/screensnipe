import SwiftUI

struct LibrarySidebar: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var selection: Set<String> = []
    @State private var entriesToDelete: [LibraryEntry] = []
    @State private var entryToEdit: LibraryEntry?

    var body: some View {
        ScrollViewReader { proxy in
            List(viewModel.entries, selection: $selection) { entry in
                LibraryEntryRow(entry: entry)
                    .tag(entry.id)
                    .id(entry.id)
            }
            .contextMenu(forSelectionType: String.self) { selectedIDs in
                // A single series is already an ordered set of images, so it is
                // a valid stitch input on its own.
                let isSingleSeries = selectedIDs.count == 1
                    && viewModel.entries.first { $0.id == selectedIDs.first }?.mediaType == .series
                if selectedIDs.count >= 2 || isSingleSeries {
                    Button("Stitch Together...") {
                        viewModel.beginStitch()
                    }
                    Divider()
                }
                if selectedIDs.count == 1, let id = selectedIDs.first,
                   let entry = viewModel.entries.first(where: { $0.id == id }) {
                    Button("Edit...") {
                        entryToEdit = entry
                    }
                    Button("Show in Finder") {
                        // A series has no single media file; reveal its folder.
                        NSWorkspace.shared.activateFileViewerSelecting([entry.mediaURL ?? entry.folderURL])
                    }
                    Divider()
                    Button("Copy iCloud Link") {
                        viewModel.copyICloudLink(for: entry)
                    }
                    if entry.metadata.shareURL != nil {
                        Button("Stop Sharing") {
                            viewModel.stopSharing(entry)
                        }
                    }
                    Divider()
                }
                if !selectedIDs.isEmpty {
                    Button("Delete", role: .destructive) {
                        let entries = viewModel.entries.filter { selectedIDs.contains($0.id) }
                        if !entries.isEmpty {
                            entriesToDelete = entries
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .alert(
                entriesToDelete.count == 1 ? "Delete Capture" : "Delete \(entriesToDelete.count) Captures",
                isPresented: Binding(
                    get: { !entriesToDelete.isEmpty },
                    set: { if !$0 { entriesToDelete = [] } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    for entry in entriesToDelete {
                        viewModel.deleteEntry(entry)
                    }
                    entriesToDelete = []
                }
                Button("Cancel", role: .cancel) {
                    entriesToDelete = []
                }
            } message: {
                if entriesToDelete.count == 1 {
                    Text("Delete this capture? This cannot be undone.")
                } else {
                    Text("Delete \(entriesToDelete.count) captures? This cannot be undone.")
                }
            }
            .sheet(item: $entryToEdit) { entry in
                LibraryEntryEditView(entry: entry, viewModel: viewModel)
            }
            .onChange(of: selection) { _, newValue in
                viewModel.selectedEntryIDs = newValue
            }
            .onChange(of: viewModel.selectedEntryIDs) { _, newValue in
                if selection != newValue {
                    selection = newValue
                }
                // Scroll to the single selected item
                if newValue.count == 1, let id = newValue.first {
                    DispatchQueue.main.async {
                        withAnimation {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
        }
    }
}

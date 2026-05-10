import SwiftUI

struct LibrarySidebar: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var selection: Set<String> = []
    @State private var entriesToDelete: [LibraryEntry] = []
    @State private var entryToRename: LibraryEntry?
    @State private var entryToDescribe: LibraryEntry?
    @State private var renameText = ""
    @State private var descriptionText = ""

    var body: some View {
        ScrollViewReader { proxy in
            List(viewModel.entries, selection: $selection) { entry in
                LibraryEntryRow(entry: entry)
                    .tag(entry.id)
                    .id(entry.id)
            }
            .contextMenu(forSelectionType: String.self) { selectedIDs in
                if selectedIDs.count >= 2 {
                    Button("Stitch Together...") {
                        viewModel.beginStitch()
                    }
                    Divider()
                }
                if selectedIDs.count == 1, let id = selectedIDs.first,
                   let entry = viewModel.entries.first(where: { $0.id == id }) {
                    Button("Rename...") {
                        renameText = entry.metadata.name ?? ""
                        entryToRename = entry
                    }
                    Button("Set Description...") {
                        descriptionText = entry.metadata.description ?? ""
                        entryToDescribe = entry
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.mediaURL])
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
            .alert("Rename Capture", isPresented: Binding(
                get: { entryToRename != nil },
                set: { if !$0 { entryToRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let entry = entryToRename {
                        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.updateMetadata(for: entry, name: name.isEmpty ? nil : name, description: entry.metadata.description)
                        entryToRename = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    entryToRename = nil
                }
            } message: {
                Text("Enter a name for this capture.")
            }
            .alert("Set Description", isPresented: Binding(
                get: { entryToDescribe != nil },
                set: { if !$0 { entryToDescribe = nil } }
            )) {
                TextField("Description", text: $descriptionText)
                Button("Save") {
                    if let entry = entryToDescribe {
                        let desc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.updateMetadata(for: entry, name: entry.metadata.name, description: desc.isEmpty ? nil : desc)
                        entryToDescribe = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    entryToDescribe = nil
                }
            } message: {
                Text("Enter a description for this capture.")
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

import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(viewModel: viewModel)
        } detail: {
            LibraryDetailView(viewModel: viewModel, annotationStore: viewModel.annotationStore)
                .inspector(isPresented: $viewModel.showInspector) {
                    PropertyPanel(store: viewModel.annotationStore)
                        .inspectorColumnWidth(min: 200, ideal: 300, max: 300)
                }
        }
        .toolbar(removing: .sidebarToggle)
        .sheet(isPresented: $viewModel.showStitchDialog) {
            StitchDialogView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showStitchProgress) {
            StitchProgressView(viewModel: viewModel)
        }
        .alert("Stitch Failed", isPresented: Binding(
            get: { viewModel.stitchError != nil },
            set: { if !$0 { viewModel.stitchError = nil } }
        )) {
            Button("OK") { viewModel.stitchError = nil }
        } message: {
            Text(viewModel.stitchError ?? "")
        }
    }
}

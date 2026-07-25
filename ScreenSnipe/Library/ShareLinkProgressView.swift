import SwiftUI

struct ShareLinkProgressView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Preparing iCloud Link...")
                .font(.headline)

            ProgressView()
                .progressViewStyle(.linear)

            Text("Uploading to iCloud")
                .foregroundStyle(.secondary)

            Button("Cancel") {
                viewModel.cancelShareLink()
            }
        }
        .padding(30)
        .frame(width: 300)
    }
}

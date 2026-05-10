import SwiftUI

struct StitchProgressView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Stitching...")
                .font(.headline)

            ProgressView(value: viewModel.stitchProgress)
                .progressViewStyle(.linear)

            Text("\(Int(viewModel.stitchProgress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button("Cancel") {
                viewModel.cancelStitch()
            }
        }
        .padding(30)
        .frame(width: 300)
    }
}

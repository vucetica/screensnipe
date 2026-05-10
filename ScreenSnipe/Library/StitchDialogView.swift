import SwiftUI

struct StitchDialogView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @State private var items: [LibraryEntry]
    @State private var pauseDuration: Double = 2
    @State private var imageDuration: Double = 5
    @State private var draggingItem: LibraryEntry?

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
        _items = State(initialValue: viewModel.stitchEntries)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Stitch Together")
                .font(.headline)

            Text("Drag to reorder. Items will be combined left to right.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Draggable thumbnail strip
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                        StitchThumbnail(entry: entry, index: index + 1)
                            .onDrag {
                                draggingItem = entry
                                return NSItemProvider(object: entry.id as NSString)
                            }
                            .onDrop(of: [.text], delegate: StitchDropDelegate(
                                item: entry,
                                items: $items,
                                draggingItem: $draggingItem
                            ))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: 110)

            Divider()

            // Settings
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Pause between clips:")
                        .frame(width: 160, alignment: .leading)
                    Slider(value: $pauseDuration, in: 0...10, step: 0.5)
                    Text("\(pauseDuration, specifier: "%.1f")s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }

                HStack {
                    Text("Image display duration:")
                        .frame(width: 160, alignment: .leading)
                    Slider(value: $imageDuration, in: 1...30, step: 1)
                    Text("\(Int(imageDuration))s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .padding(.horizontal)

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    viewModel.showStitchDialog = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Stitch") {
                    let config = StitchConfiguration(
                        items: items,
                        pauseDurationSeconds: pauseDuration,
                        imageDurationSeconds: imageDuration
                    )
                    viewModel.showStitchDialog = false
                    viewModel.performStitch(config)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

// MARK: - Thumbnail

private struct StitchThumbnail: View {
    let entry: LibraryEntry
    let index: Int

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                AsyncThumbnailView(url: entry.thumbnailURL)
                    .frame(width: 80, height: 60)
                    .cornerRadius(6)

                Text("\(index)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }

            Text(entry.mediaType == .image ? "Screenshot" : "Recording")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(entry.name ?? Self.dateFormatter.string(from: entry.captureDate))
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 80)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}

// MARK: - Drop Delegate

private struct StitchDropDelegate: DropDelegate {
    let item: LibraryEntry
    @Binding var items: [LibraryEntry]
    @Binding var draggingItem: LibraryEntry?

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingItem,
              dragging.id != item.id,
              let fromIndex = items.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id }) else { return }

        withAnimation(.default) {
            items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

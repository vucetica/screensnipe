import SwiftUI

struct LibraryEntryRow: View {
    let entry: LibraryEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AsyncThumbnailView(url: entry.thumbnailURL)
                    .frame(width: 60, height: 45)
                    .cornerRadius(4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name ?? Self.dateFormatter.string(from: entry.captureDate))
                        .font(.caption)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: entry.mediaType == .image ? "photo" : "video")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.mediaType == .image ? "Screenshot" : "Recording")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !entry.metadata.tags.isEmpty {
                TagFlowLayout(spacing: 4) {
                    ForEach(entry.metadata.tags, id: \.self) { tag in
                        TagPill(text: tag, style: .sidebar)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

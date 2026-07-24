import SwiftUI

struct LibraryEntryRow: View {
    let entry: LibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AsyncThumbnailView(url: entry.thumbnailURL)
                    .frame(width: 60, height: 45)
                    .cornerRadius(4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name ?? LibraryViewModel.rowDisplayDate(for: entry))
                        .font(.caption)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: entry.mediaType == .image ? "photo" : "video")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.mediaType == .image ? "Screenshot" : "Recording")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if entry.metadata.shareURL != nil {
                            Image(systemName: "link.icloud")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Shared via iCloud link. Right-click to copy the link or stop sharing.")
                        }
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

import SwiftUI

struct LibraryEntryRow: View {
    let entry: LibraryEntry

    /// Frame count for series entries. Decoded off the render path, the way
    /// AsyncThumbnailView loads thumbnails, so reload() stays an existence check.
    @State private var frameCount: Int?

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
                        Image(systemName: entry.mediaType.iconName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(subtitle)
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
        .task(id: entry.id) {
            guard entry.mediaType == .series else {
                frameCount = nil
                return
            }
            let url = entry.seriesManifestURL
            frameCount = await Task.detached(priority: .utility) {
                (try? SeriesManifest.load(from: url))?.frames.count
            }.value
        }
    }

    private var subtitle: String {
        guard entry.mediaType == .series else { return entry.mediaType.displayName }
        guard let frameCount else { return "Series" }
        return frameCount == 1 ? "1 frame" : "\(frameCount) frames"
    }
}

import SwiftUI

struct LibraryEntryEditView: View {
    let entry: LibraryEntry
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject private var libraryManager = LibraryManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var tags: [String]

    init(entry: LibraryEntry, viewModel: LibraryViewModel) {
        self.entry = entry
        self.viewModel = viewModel
        _name = State(initialValue: entry.metadata.name ?? "")
        _description = State(initialValue: entry.metadata.description ?? "")
        _tags = State(initialValue: entry.metadata.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Capture")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Description", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Tags")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TagTokenField(tags: $tags, allTags: libraryManager.allTags)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        viewModel.updateMetadata(
            for: entry,
            name: trimmedName.isEmpty ? nil : trimmedName,
            description: trimmedDesc.isEmpty ? nil : trimmedDesc,
            tags: cleanedTags
        )
    }
}

// MARK: - Tag token field

struct TagTokenField: View {
    @Binding var tags: [String]
    let allTags: [String]

    @State private var input: String = ""
    @FocusState private var isFocused: Bool

    private var suggestions: [String] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let existing = Set(tags.map { $0.lowercased() })
        return allTags
            .filter { $0.lowercased().contains(query) && !existing.contains($0.lowercased()) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tags.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagPill(text: tag, onDelete: { remove(tag) })
                    }
                }
            }

            TextField("Type a new tag and press ↵, or choose from existing tags", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { commitInput() }
                .onKeyPress(.delete) {
                    if input.isEmpty && !tags.isEmpty {
                        tags.removeLast()
                        return .handled
                    }
                    return .ignored
                }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            add(suggestion)
                            input = ""
                        } label: {
                            Text(suggestion)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            }
        }
    }

    private func commitInput() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let firstSuggestion = suggestions.first,
           firstSuggestion.lowercased() == trimmed.lowercased() {
            add(firstSuggestion)
        } else {
            add(trimmed)
        }
        input = ""
    }

    private func add(_ tag: String) {
        let key = tag.lowercased()
        if !tags.contains(where: { $0.lowercased() == key }) {
            tags.append(tag)
        }
    }

    private func remove(_ tag: String) {
        tags.removeAll { $0 == tag }
    }
}

// MARK: - Tag pill

struct TagPill: View {
    enum Style {
        case accent
        case sidebar
    }

    let text: String
    var style: Style = .accent
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
                .lineLimit(1)
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background)
        .foregroundStyle(foreground)
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .accent:
            Capsule().fill(Color.accentColor.opacity(0.18))
        case .sidebar:
            Capsule().fill(.thinMaterial)
        }
    }

    private var foreground: Color {
        switch style {
        case .accent: Color.accentColor
        case .sidebar: Color.primary
        }
    }
}

// MARK: - Flow layout

struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return compute(maxWidth: maxWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = compute(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func compute(maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + lineHeight), frames)
    }
}

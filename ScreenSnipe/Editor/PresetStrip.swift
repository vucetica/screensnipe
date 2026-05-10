import SwiftUI

struct PresetStrip: View {
    let toolType: String
    let primaryColor: (ToolPreset) -> CGColor?
    let onSelect: (ToolPreset) -> Void
    let onSave: () -> Void

    @ObservedObject private var presetManager = PresetManager.shared
    @State private var editingID: UUID?
    @State private var editText = ""

    var body: some View {
        let toolPresets = presetManager.presets(for: toolType)

        VStack(spacing: 4) {
            ForEach(toolPresets) { preset in
                PresetChip(
                    preset: preset,
                    primaryColor: primaryColor(preset),
                    isEditing: editingID == preset.id,
                    editText: editingID == preset.id ? $editText : .constant(preset.name),
                    onTap: { onSelect(preset) },
                    onStartRename: {
                        editText = preset.name
                        editingID = preset.id
                    },
                    onCommitRename: {
                        if !editText.isEmpty {
                            presetManager.renamePreset(id: preset.id, toolType: toolType, newName: editText)
                        }
                        editingID = nil
                    },
                    onDelete: {
                        presetManager.removePreset(id: preset.id, toolType: toolType)
                    }
                )
            }

            if toolPresets.count < 6 {
                Button(action: onSave) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.caption)
                        Text("Save Preset")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PresetChip: View {
    let preset: ToolPreset
    let primaryColor: CGColor?
    let isEditing: Bool
    @Binding var editText: String
    let onTap: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let color = primaryColor {
                    Circle()
                        .fill(Color(cgColor: color) ?? .red)
                        .frame(width: 10, height: 10)
                }
                if isEditing {
                    TextField("Name", text: $editText, onCommit: onCommitRename)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(preset.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEditing ? Color(nsColor: .controlBackgroundColor) : Color(.quaternaryLabelColor).opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isEditing ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") { onStartRename() }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

import Foundation

@MainActor
final class PresetManager: ObservableObject {
    static let shared = PresetManager()

    private static let userDefaultsKey = "toolPresets"
    private static let maxPresetsPerTool = 6

    @Published private(set) var presets: [String: [ToolPreset]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [ToolPreset]].self, from: data) {
            self.presets = decoded
        } else {
            self.presets = [:]
        }
    }

    func presets(for toolType: String) -> [ToolPreset] {
        presets[toolType] ?? []
    }

    func addPreset(_ preset: ToolPreset) {
        var toolPresets = presets[preset.toolType] ?? []
        guard toolPresets.count < Self.maxPresetsPerTool else { return }
        toolPresets.append(preset)
        presets[preset.toolType] = toolPresets
        save()
    }

    func removePreset(id: UUID, toolType: String) {
        presets[toolType]?.removeAll { $0.id == id }
        save()
    }

    func renamePreset(id: UUID, toolType: String, newName: String) {
        guard let index = presets[toolType]?.firstIndex(where: { $0.id == id }) else { return }
        presets[toolType]?[index].name = newName
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

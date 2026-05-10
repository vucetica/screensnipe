import Foundation

struct ToolPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var toolType: String
    var properties: [String: PresetValue]

    init(id: UUID = UUID(), name: String, toolType: String, properties: [String: PresetValue]) {
        self.id = id
        self.name = name
        self.toolType = toolType
        self.properties = properties
    }
}

enum PresetValue: Codable, Equatable {
    case color(CodableColor)
    case number(CGFloat)
    case string(String)

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    private enum ValueType: String, Codable {
        case color, number, string
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .color(let c):
            try container.encode(ValueType.color, forKey: .type)
            try container.encode(c, forKey: .value)
        case .number(let n):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(n, forKey: .value)
        case .string(let s):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(s, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ValueType.self, forKey: .type)
        switch type {
        case .color:
            self = .color(try container.decode(CodableColor.self, forKey: .value))
        case .number:
            self = .number(try container.decode(CGFloat.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        }
    }
}

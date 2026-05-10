import Foundation

enum EditorTool: String, CaseIterable, Sendable, Identifiable {
    case selection
    case arrow
    case text
    case shape
    case line
    case highlighter
    case blur
    case crop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selection: "Select"
        case .arrow: "Arrow"
        case .text: "Text"
        case .shape: "Shape"
        case .line: "Line"
        case .highlighter: "Highlighter"
        case .blur: "Blur"
        case .crop: "Crop"
        }
    }

    var iconName: String {
        switch self {
        case .selection: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .shape: "rectangle"
        case .line: "line.diagonal"
        case .highlighter: "highlighter"
        case .blur: "aqi.medium"
        case .crop: "crop"
        }
    }

    var shortcutHint: String? {
        switch self {
        case .selection: "V"
        case .arrow: "A"
        case .text: "T"
        case .shape: "S"
        case .line: "L"
        case .highlighter: "H"
        case .blur: "B"
        case .crop: "C"
        }
    }
}

enum ShapeKind: String, CaseIterable, Sendable, Codable {
    case rectangle
    case ellipse
    case roundedRectangle
}

enum BlurStyle: String, CaseIterable, Sendable, Codable {
    case gaussian
    case pixelate
}

enum LineStyle: String, CaseIterable, Sendable, Codable {
    case solid
    case dashed
}

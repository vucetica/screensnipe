import Foundation
import AppKit

// MARK: - Codable Wrappers for Core Graphics Types

struct CodableColor: Codable, Sendable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ cgColor: CGColor) {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil) ?? cgColor
        let components = converted.components ?? [0, 0, 0, 1]
        if components.count >= 4 {
            red = components[0]
            green = components[1]
            blue = components[2]
            alpha = components[3]
        } else if components.count >= 2 {
            red = components[0]
            green = components[0]
            blue = components[0]
            alpha = components[1]
        } else {
            red = 0; green = 0; blue = 0; alpha = 1
        }
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

struct CodablePoint: Codable, Sendable {
    let x: CGFloat
    let y: CGFloat

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct CodableRect: Codable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

// MARK: - Annotation Type Discriminator

enum AnnotationType: String, Codable, Sendable {
    case arrow
    case text
    case shape
    case line
    case highlighter
    case blur
}

// MARK: - Codable Envelope

struct CodableAnnotationEnvelope: Codable, Sendable {
    let type: AnnotationType
    let id: UUID
    let data: Data
}

// MARK: - Editor State (wraps annotations + crop for persistence)

struct EditorState: Codable {
    /// Schema version for forward-compatible migration. Bump when the model changes.
    let version: Int?
    let annotations: [CodableAnnotationEnvelope]
    let cropRect: CodableRect?
    let magnification: CGFloat?

    static let currentVersion = 1

    init(annotations: [CodableAnnotationEnvelope], cropRect: CodableRect?, magnification: CGFloat?) {
        self.version = Self.currentVersion
        self.annotations = annotations
        self.cropRect = cropRect
        self.magnification = magnification
    }
}

// MARK: - Serializer

enum AnnotationSerializer {
    static func serialize(_ annotations: [AnyAnnotation], cropRect: CGRect? = nil, magnification: CGFloat? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelopes = try annotations.map { try $0.toEnvelope() }
        let state = EditorState(
            annotations: envelopes,
            cropRect: cropRect.map { CodableRect($0) },
            magnification: magnification
        )
        return try encoder.encode(state)
    }

    static func deserialize(_ data: Data) throws -> (annotations: [AnyAnnotation], cropRect: CGRect?, magnification: CGFloat?) {
        let decoder = JSONDecoder()

        // Try new EditorState format first
        if let state = try? decoder.decode(EditorState.self, from: data) {
            let annotations = try state.annotations.map { try AnyAnnotation.from(envelope: $0) }
            return (annotations, state.cropRect?.cgRect, state.magnification)
        }

        // Fall back to legacy bare array format
        let envelopes = try decoder.decode([CodableAnnotationEnvelope].self, from: data)
        let annotations = try envelopes.map { try AnyAnnotation.from(envelope: $0) }
        return (annotations, nil, nil)
    }
}

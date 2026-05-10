import Foundation
import AppKit

// MARK: - Annotation Protocol

protocol Annotation: Sendable {
    var id: UUID { get }
    var boundingRect: CGRect { get }

    func hitTest(point: CGPoint) -> Bool
    func moved(by delta: CGSize) -> Self
    func resized(to rect: CGRect) -> Self
    func draw(in context: CGContext, scale: CGFloat)
}

extension Annotation {
    func hitTest(point: CGPoint) -> Bool {
        boundingRect.insetBy(dx: -4, dy: -4).contains(point)
    }
}

// MARK: - Arrow Annotation

struct ArrowAnnotation: Annotation, Equatable, Codable {
    let id: UUID
    var start: CGPoint
    var end: CGPoint
    var color: CGColor
    var lineWidth: CGFloat
    var headLength: CGFloat

    enum CodingKeys: String, CodingKey {
        case id, start, end, color, lineWidth, headLength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(CodablePoint.self, forKey: .start).cgPoint
        end = try c.decode(CodablePoint.self, forKey: .end).cgPoint
        color = try c.decode(CodableColor.self, forKey: .color).cgColor
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        headLength = try c.decode(CGFloat.self, forKey: .headLength)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CodablePoint(start), forKey: .start)
        try c.encode(CodablePoint(end), forKey: .end)
        try c.encode(CodableColor(color), forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(headLength, forKey: .headLength)
    }

    var boundingRect: CGRect {
        CGRect(
            x: min(start.x, end.x) - headLength,
            y: min(start.y, end.y) - headLength,
            width: abs(end.x - start.x) + headLength * 2,
            height: abs(end.y - start.y) + headLength * 2
        )
    }

    init(id: UUID = UUID(), start: CGPoint, end: CGPoint, color: CGColor = NSColor.systemRed.cgColor, lineWidth: CGFloat = 3, headLength: CGFloat = 16) {
        self.id = id
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
        self.headLength = headLength
    }

    func hitTest(point: CGPoint) -> Bool {
        let threshold: CGFloat = 8
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else {
            return hypot(point.x - start.x, point.y - start.y) <= threshold
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSq))
        let projX = start.x + t * dx
        let projY = start.y + t * dy
        return hypot(point.x - projX, point.y - projY) <= threshold
    }

    func moved(by delta: CGSize) -> ArrowAnnotation {
        ArrowAnnotation(
            id: id,
            start: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
            end: CGPoint(x: end.x + delta.width, y: end.y + delta.height),
            color: color, lineWidth: lineWidth, headLength: headLength
        )
    }

    func resized(to rect: CGRect) -> ArrowAnnotation {
        let oldRect = boundingRect
        guard oldRect.width > 0, oldRect.height > 0 else { return self }
        let scaleX = rect.width / oldRect.width
        let scaleY = rect.height / oldRect.height
        func mapPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.origin.x + (p.x - oldRect.origin.x) * scaleX,
                y: rect.origin.y + (p.y - oldRect.origin.y) * scaleY
            )
        }
        return ArrowAnnotation(
            id: id, start: mapPoint(start), end: mapPoint(end),
            color: color, lineWidth: lineWidth, headLength: headLength
        )
    }

    func draw(in context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth / scale)
        context.setLineCap(.round)

        // Draw line
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        // Draw arrowhead
        let angle = atan2(end.y - start.y, end.x - start.x)
        let hl = headLength / scale
        let headAngle: CGFloat = .pi / 6
        let p1 = CGPoint(x: end.x - hl * cos(angle - headAngle), y: end.y - hl * sin(angle - headAngle))
        let p2 = CGPoint(x: end.x - hl * cos(angle + headAngle), y: end.y - hl * sin(angle + headAngle))

        context.setFillColor(color)
        context.move(to: end)
        context.addLine(to: p1)
        context.addLine(to: p2)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }
}

// MARK: - Text Annotation

struct TextAnnotation: Annotation, Equatable, Codable {
    let id: UUID
    var origin: CGPoint
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var color: CGColor
    var backgroundColor: CGColor?

    enum CodingKeys: String, CodingKey {
        case id, origin, text, fontName, fontSize, color, backgroundColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        origin = try c.decode(CodablePoint.self, forKey: .origin).cgPoint
        text = try c.decode(String.self, forKey: .text)
        fontName = try c.decode(String.self, forKey: .fontName)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        color = try c.decode(CodableColor.self, forKey: .color).cgColor
        backgroundColor = try c.decodeIfPresent(CodableColor.self, forKey: .backgroundColor)?.cgColor
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CodablePoint(origin), forKey: .origin)
        try c.encode(text, forKey: .text)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(CodableColor(color), forKey: .color)
        try c.encodeIfPresent(backgroundColor.map { CodableColor($0) }, forKey: .backgroundColor)
    }

    var boundingRect: CGRect {
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = (text as NSString).size(withAttributes: attrs)
        return CGRect(origin: origin, size: CGSize(width: max(size.width, 40), height: max(size.height, fontSize + 4)))
    }

    init(id: UUID = UUID(), origin: CGPoint, text: String = "", fontName: String = "Helvetica-Bold", fontSize: CGFloat = 18, color: CGColor = NSColor.systemRed.cgColor, backgroundColor: CGColor? = nil) {
        self.id = id
        self.origin = origin
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.backgroundColor = backgroundColor
    }

    func moved(by delta: CGSize) -> TextAnnotation {
        var copy = self
        copy.origin = CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
        return copy
    }

    func resized(to rect: CGRect) -> TextAnnotation {
        var copy = self
        copy.origin = rect.origin
        return copy
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard !text.isEmpty else { return }
        context.saveGState()

        if let bg = backgroundColor {
            context.setFillColor(bg)
            context.fill(boundingRect.insetBy(dx: -4, dy: -2))
        }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.red
        ]
        let nsStr = text as NSString
        let ctx = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        nsStr.draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

// MARK: - Shape Annotation

struct ShapeAnnotation: Annotation, Equatable, Codable {
    let id: UUID
    var rect: CGRect
    var kind: ShapeKind
    var strokeColor: CGColor
    var fillColor: CGColor?
    var lineWidth: CGFloat
    var cornerRadius: CGFloat

    enum CodingKeys: String, CodingKey {
        case id, rect, kind, strokeColor, fillColor, lineWidth, cornerRadius
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        rect = try c.decode(CodableRect.self, forKey: .rect).cgRect
        kind = try c.decode(ShapeKind.self, forKey: .kind)
        strokeColor = try c.decode(CodableColor.self, forKey: .strokeColor).cgColor
        fillColor = try c.decodeIfPresent(CodableColor.self, forKey: .fillColor)?.cgColor
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        cornerRadius = try c.decode(CGFloat.self, forKey: .cornerRadius)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CodableRect(rect), forKey: .rect)
        try c.encode(kind, forKey: .kind)
        try c.encode(CodableColor(strokeColor), forKey: .strokeColor)
        try c.encodeIfPresent(fillColor.map { CodableColor($0) }, forKey: .fillColor)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(cornerRadius, forKey: .cornerRadius)
    }

    var boundingRect: CGRect { rect }

    init(id: UUID = UUID(), rect: CGRect, kind: ShapeKind = .rectangle, strokeColor: CGColor = NSColor.systemRed.cgColor, fillColor: CGColor? = nil, lineWidth: CGFloat = 3, cornerRadius: CGFloat = 8) {
        self.id = id
        self.rect = rect
        self.kind = kind
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
    }

    func moved(by delta: CGSize) -> ShapeAnnotation {
        var copy = self
        copy.rect = rect.offsetBy(dx: delta.width, dy: delta.height)
        return copy
    }

    func resized(to rect: CGRect) -> ShapeAnnotation {
        var copy = self
        copy.rect = rect
        return copy
    }

    func draw(in context: CGContext, scale: CGFloat) {
        context.saveGState()
        let lw = lineWidth / scale
        context.setLineWidth(lw)
        context.setStrokeColor(strokeColor)

        let path: CGPath
        switch kind {
        case .rectangle:
            path = CGPath(rect: rect.insetBy(dx: lw / 2, dy: lw / 2), transform: nil)
        case .ellipse:
            path = CGPath(ellipseIn: rect.insetBy(dx: lw / 2, dy: lw / 2), transform: nil)
        case .roundedRectangle:
            path = CGPath(roundedRect: rect.insetBy(dx: lw / 2, dy: lw / 2), cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        }

        if let fill = fillColor {
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Line Annotation

struct LineAnnotation: Annotation, Equatable, Codable {
    let id: UUID
    var start: CGPoint
    var end: CGPoint
    var color: CGColor
    var lineWidth: CGFloat
    var style: LineStyle

    enum CodingKeys: String, CodingKey {
        case id, start, end, color, lineWidth, style
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(CodablePoint.self, forKey: .start).cgPoint
        end = try c.decode(CodablePoint.self, forKey: .end).cgPoint
        color = try c.decode(CodableColor.self, forKey: .color).cgColor
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        style = try c.decode(LineStyle.self, forKey: .style)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CodablePoint(start), forKey: .start)
        try c.encode(CodablePoint(end), forKey: .end)
        try c.encode(CodableColor(color), forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(style, forKey: .style)
    }

    var boundingRect: CGRect {
        CGRect(
            x: min(start.x, end.x) - lineWidth,
            y: min(start.y, end.y) - lineWidth,
            width: abs(end.x - start.x) + lineWidth * 2,
            height: abs(end.y - start.y) + lineWidth * 2
        )
    }

    init(id: UUID = UUID(), start: CGPoint, end: CGPoint, color: CGColor = NSColor.systemRed.cgColor, lineWidth: CGFloat = 3, style: LineStyle = .solid) {
        self.id = id
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
        self.style = style
    }

    func hitTest(point: CGPoint) -> Bool {
        let threshold: CGFloat = 8
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else {
            return hypot(point.x - start.x, point.y - start.y) <= threshold
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSq))
        let projX = start.x + t * dx
        let projY = start.y + t * dy
        return hypot(point.x - projX, point.y - projY) <= threshold
    }

    func moved(by delta: CGSize) -> LineAnnotation {
        LineAnnotation(
            id: id,
            start: CGPoint(x: start.x + delta.width, y: start.y + delta.height),
            end: CGPoint(x: end.x + delta.width, y: end.y + delta.height),
            color: color, lineWidth: lineWidth, style: style
        )
    }

    func resized(to rect: CGRect) -> LineAnnotation {
        let oldRect = boundingRect
        guard oldRect.width > 0, oldRect.height > 0 else { return self }
        let scaleX = rect.width / oldRect.width
        let scaleY = rect.height / oldRect.height
        func mapPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.origin.x + (p.x - oldRect.origin.x) * scaleX,
                y: rect.origin.y + (p.y - oldRect.origin.y) * scaleY
            )
        }
        return LineAnnotation(
            id: id, start: mapPoint(start), end: mapPoint(end),
            color: color, lineWidth: lineWidth, style: style
        )
    }

    func draw(in context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth / scale)
        context.setLineCap(.round)

        if style == .dashed {
            let dashLen = 8 / scale
            context.setLineDash(phase: 0, lengths: [dashLen, dashLen])
        }

        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Highlighter Annotation

struct HighlighterAnnotation: Annotation, Equatable, Codable {
    let id: UUID
    var points: [CGPoint]
    var color: CGColor
    var lineWidth: CGFloat

    enum CodingKeys: String, CodingKey {
        case id, points, color, lineWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        points = try c.decode([CodablePoint].self, forKey: .points).map(\.cgPoint)
        color = try c.decode(CodableColor.self, forKey: .color).cgColor
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(points.map { CodablePoint($0) }, forKey: .points)
        try c.encode(CodableColor(color), forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
    }

    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX - lineWidth, y: minY - lineWidth,
                       width: maxX - minX + lineWidth * 2,
                       height: maxY - minY + lineWidth * 2)
    }

    init(id: UUID = UUID(), points: [CGPoint] = [], color: CGColor = NSColor.systemYellow.withAlphaComponent(0.4).cgColor, lineWidth: CGFloat = 20) {
        self.id = id
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
    }

    func hitTest(point: CGPoint) -> Bool {
        let threshold = lineWidth / 2 + 4
        guard points.count >= 2 else {
            if let p = points.first {
                return hypot(point.x - p.x, point.y - p.y) <= threshold
            }
            return false
        }
        for i in 0..<points.count - 1 {
            let a = points[i]
            let b = points[i + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSq = dx * dx + dy * dy
            if lengthSq == 0 {
                if hypot(point.x - a.x, point.y - a.y) <= threshold { return true }
                continue
            }
            let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSq))
            let projX = a.x + t * dx
            let projY = a.y + t * dy
            if hypot(point.x - projX, point.y - projY) <= threshold { return true }
        }
        return false
    }

    func moved(by delta: CGSize) -> HighlighterAnnotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    func resized(to rect: CGRect) -> HighlighterAnnotation {
        let oldRect = boundingRect
        guard oldRect.width > 0, oldRect.height > 0 else { return self }
        let scaleX = rect.width / oldRect.width
        let scaleY = rect.height / oldRect.height
        var copy = self
        copy.points = points.map {
            CGPoint(
                x: rect.origin.x + ($0.x - oldRect.origin.x) * scaleX,
                y: rect.origin.y + ($0.y - oldRect.origin.y) * scaleY
            )
        }
        return copy
    }

    func draw(in context: CGContext, scale: CGFloat) {
        guard points.count >= 2 else { return }
        context.saveGState()
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth / scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setBlendMode(.normal)

        context.beginPath()
        context.move(to: points[0])
        for i in 1..<points.count {
            context.addLine(to: points[i])
        }
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Blur Annotation

struct BlurAnnotation: Annotation, Equatable, Codable {
    let id: UUID
    var rect: CGRect
    var style: BlurStyle
    var intensity: CGFloat

    enum CodingKeys: String, CodingKey {
        case id, rect, style, intensity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        rect = try c.decode(CodableRect.self, forKey: .rect).cgRect
        style = try c.decode(BlurStyle.self, forKey: .style)
        intensity = try c.decode(CGFloat.self, forKey: .intensity)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CodableRect(rect), forKey: .rect)
        try c.encode(style, forKey: .style)
        try c.encode(intensity, forKey: .intensity)
    }

    var boundingRect: CGRect { rect }

    init(id: UUID = UUID(), rect: CGRect, style: BlurStyle = .gaussian, intensity: CGFloat = 10) {
        self.id = id
        self.rect = rect
        self.style = style
        self.intensity = intensity
    }

    func moved(by delta: CGSize) -> BlurAnnotation {
        var copy = self
        copy.rect = rect.offsetBy(dx: delta.width, dy: delta.height)
        return copy
    }

    func resized(to rect: CGRect) -> BlurAnnotation {
        var copy = self
        copy.rect = rect
        return copy
    }

    func draw(in context: CGContext, scale: CGFloat) {
        // Blur drawing is handled specially by CanvasView since it needs access to the base image.
        // Here we just draw a subtle indicator outline.
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 0.5, alpha: 0.3))
        context.setLineWidth(1 / scale)
        context.setLineDash(phase: 0, lengths: [4 / scale, 4 / scale])
        context.stroke(rect)
        context.restoreGState()
    }
}

// MARK: - AnyAnnotation (Type-Erased Wrapper)

struct AnyAnnotation: Equatable, Sendable, Identifiable {
    private let _annotation: any Annotation
    private let _equals: @Sendable (any Annotation) -> Bool
    private let _moveBy: @Sendable (CGSize) -> AnyAnnotation
    private let _resizeTo: @Sendable (CGRect) -> AnyAnnotation

    var id: UUID { _annotation.id }
    var boundingRect: CGRect { _annotation.boundingRect }

    init<A: Annotation & Equatable>(_ annotation: A) {
        self._annotation = annotation
        self._equals = { other in
            guard let otherTyped = other as? A else { return false }
            return annotation == otherTyped
        }
        self._moveBy = { delta in AnyAnnotation(annotation.moved(by: delta)) }
        self._resizeTo = { rect in AnyAnnotation(annotation.resized(to: rect)) }
    }

    func unwrap<A: Annotation>(as type: A.Type) -> A? {
        _annotation as? A
    }

    func hitTest(point: CGPoint) -> Bool {
        _annotation.hitTest(point: point)
    }

    func moved(by delta: CGSize) -> AnyAnnotation {
        _moveBy(delta)
    }

    func resized(to rect: CGRect) -> AnyAnnotation {
        _resizeTo(rect)
    }

    func draw(in context: CGContext, scale: CGFloat) {
        _annotation.draw(in: context, scale: scale)
    }

    static func == (lhs: AnyAnnotation, rhs: AnyAnnotation) -> Bool {
        lhs.id == rhs.id && lhs._equals(rhs._annotation)
    }

    // MARK: - Serialization

    func toEnvelope() throws -> CodableAnnotationEnvelope {
        let encoder = JSONEncoder()
        if let a = _annotation as? ArrowAnnotation {
            return CodableAnnotationEnvelope(type: .arrow, id: id, data: try encoder.encode(a))
        } else if let a = _annotation as? TextAnnotation {
            return CodableAnnotationEnvelope(type: .text, id: id, data: try encoder.encode(a))
        } else if let a = _annotation as? ShapeAnnotation {
            return CodableAnnotationEnvelope(type: .shape, id: id, data: try encoder.encode(a))
        } else if let a = _annotation as? LineAnnotation {
            return CodableAnnotationEnvelope(type: .line, id: id, data: try encoder.encode(a))
        } else if let a = _annotation as? HighlighterAnnotation {
            return CodableAnnotationEnvelope(type: .highlighter, id: id, data: try encoder.encode(a))
        } else if let a = _annotation as? BlurAnnotation {
            return CodableAnnotationEnvelope(type: .blur, id: id, data: try encoder.encode(a))
        }
        throw NSError(domain: "AnyAnnotation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown annotation type"])
    }

    static func from(envelope: CodableAnnotationEnvelope) throws -> AnyAnnotation {
        let decoder = JSONDecoder()
        switch envelope.type {
        case .arrow:
            return AnyAnnotation(try decoder.decode(ArrowAnnotation.self, from: envelope.data))
        case .text:
            return AnyAnnotation(try decoder.decode(TextAnnotation.self, from: envelope.data))
        case .shape:
            return AnyAnnotation(try decoder.decode(ShapeAnnotation.self, from: envelope.data))
        case .line:
            return AnyAnnotation(try decoder.decode(LineAnnotation.self, from: envelope.data))
        case .highlighter:
            return AnyAnnotation(try decoder.decode(HighlighterAnnotation.self, from: envelope.data))
        case .blur:
            return AnyAnnotation(try decoder.decode(BlurAnnotation.self, from: envelope.data))
        }
    }
}

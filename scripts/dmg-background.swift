#!/usr/bin/env swift

// Renders the DMG installer window background.
//
// The design treats the install window as a screenshot that has been annotated
// with ScreenSnipe's own tools: capture brackets frame the window, a blue arrow
// annotation arcs from the app to the Applications folder, and a handwritten
// note sits under the drop target.
//
// Run via scripts/build-dmg-background.sh, which also packs the 1x and 2x
// renders into distribution/dmg/background.tiff. The .tiff is committed so CI
// never has to depend on fonts or rendering being identical on the runner.

import AppKit

// MARK: - Canvas
//
// How much of this artwork Finder actually shows varies per user: "Show Path
// Bar" and "Show Status Bar" are *global* View-menu preferences, not per-window
// ones, so writing ShowStatusBar=False into the .DS_Store does not turn them
// off. With both on they take ~52pt off the bottom of the content view.
//
// So the canvas is split. Every design element lives inside the top
// designHeight points, which is the height guaranteed visible even with both
// bars showing. Below that is plain gradient bleed: users with the bars hidden
// simply see more empty margin, which reads as intentional, and no one ever
// loses part of the composition.

let canvasWidth: CGFloat = 640
let designHeight: CGFloat = 400
let bleedHeight: CGFloat = 60
let canvasHeight: CGFloat = designHeight + bleedHeight

// Icon centers must match icon_locations in distribution/dmg/dmgbuild-settings.py.
let appIconCenter = CGPoint(x: 168, y: 170)
let applicationsIconCenter = CGPoint(x: 472, y: 170)

// MARK: - Palette (matches the website in docs/)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let paperTop = color(0xFDFBF7)
let paperBottom = color(0xF1EAE0)
let bracketColor = color(0xD9D2C5)
let inkBlue = color(0x2563EB)
let handwritingColor = color(0x3B7AED)

// MARK: - Drawing

/// The four corner brackets from the app icon, framing the whole window like a
/// capture region.
func drawCaptureBrackets(in ctx: CGContext) {
    let inset: CGFloat = 22
    let arm: CGFloat = 30
    let radius: CGFloat = 10

    ctx.saveGState()
    ctx.setStrokeColor(bracketColor.cgColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let left = inset, right = canvasWidth - inset
    let top = inset, bottom = designHeight - inset

    // Each bracket is an L with a rounded elbow, drawn as an arc between arms.
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: left, y: top), 1, 1),        // top-left
        (CGPoint(x: right, y: top), -1, 1),      // top-right
        (CGPoint(x: right, y: bottom), -1, -1),  // bottom-right
        (CGPoint(x: left, y: bottom), 1, -1),    // bottom-left
    ]

    for (corner, sx, sy) in corners {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: corner.x, y: corner.y + sy * arm))
        path.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * radius))
        path.addQuadCurve(
            to: CGPoint(x: corner.x + sx * radius, y: corner.y),
            control: corner
        )
        path.addLine(to: CGPoint(x: corner.x + sx * arm, y: corner.y))
        ctx.addPath(path)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

/// The arrow annotation arcing from the app icon over to the Applications alias.
func drawArrowAnnotation(in ctx: CGContext) {
    let start = CGPoint(x: 248, y: 156)
    let control1 = CGPoint(x: 296, y: 88)
    let control2 = CGPoint(x: 348, y: 116)
    let end = CGPoint(x: 404, y: 144)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                  color: inkBlue.withAlphaComponent(0.22).cgColor)

    let shaft = CGMutablePath()
    shaft.move(to: start)
    shaft.addCurve(to: end, control1: control1, control2: control2)
    ctx.addPath(shaft)
    ctx.setStrokeColor(inkBlue.cgColor)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Arrowhead, aligned to the curve's tangent at the end point.
    let tangent = CGVector(dx: end.x - control2.x, dy: end.y - control2.y)
    let angle = atan2(tangent.dy, tangent.dx)
    let headLength: CGFloat = 22
    let headHalfWidth: CGFloat = 11
    let tip = CGPoint(x: end.x + cos(angle) * 7, y: end.y + sin(angle) * 7)

    ctx.translateBy(x: tip.x, y: tip.y)
    ctx.rotate(by: angle)
    let head = CGMutablePath()
    head.move(to: .zero)
    head.addLine(to: CGPoint(x: -headLength, y: -headHalfWidth))
    head.addQuadCurve(to: CGPoint(x: -headLength, y: headHalfWidth),
                      control: CGPoint(x: -headLength + 7, y: 0))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.setFillColor(inkBlue.cgColor)
    ctx.fillPath()

    ctx.restoreGState()
}

/// The handwritten note under the Applications folder.
func drawHandwrittenNote(in ctx: CGContext) {
    let text = "drop me here"
    let font = NSFont(name: "BradleyHandITCTT-Bold", size: 27)
        ?? NSFont(name: "Noteworthy-Bold", size: 24)
        ?? NSFont.systemFont(ofSize: 24, weight: .medium)

    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: handwritingColor,
    ])
    let size = attributed.size()

    ctx.saveGState()
    ctx.translateBy(x: applicationsIconCenter.x, y: 312)
    ctx.rotate(by: -4 * .pi / 180)

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    attributed.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
    NSGraphicsContext.current = previous

    ctx.restoreGState()
}

func render(scale: CGFloat) -> Data {
    let pixelWidth = Int(canvasWidth * scale)
    let pixelHeight = Int(canvasHeight * scale)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        fatalError("could not create bitmap context")
    }

    // Flip to a top-left origin so the layout math matches Finder's coordinates.
    ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Paper.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [paperTop.cgColor, paperBottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: canvasHeight),
        options: []
    )

    drawCaptureBrackets(in: ctx)
    drawArrowAnnotation(in: ctx)
    drawHandwrittenNote(in: ctx)

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG")
    }
    return data
}

// MARK: - Entry point

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(name)
    try! render(scale: scale).write(to: url)
    print("wrote \(url.path) (\(Int(canvasWidth * scale))x\(Int(canvasHeight * scale)))")
}

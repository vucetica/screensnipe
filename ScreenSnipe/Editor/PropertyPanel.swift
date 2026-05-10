import SwiftUI

struct PropertyPanel: View {
    @ObservedObject var store: AnnotationStore
    @ObservedObject private var presetManager = PresetManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let annotation = store.selectedAnnotation {
                    Text("Properties")
                        .font(.headline)
                        .padding(.bottom, 4)

                    propertyFields(for: annotation)
                } else {
                    Text("No Selection")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func propertyFields(for annotation: AnyAnnotation) -> some View {
        if let arrow = annotation.unwrap(as: ArrowAnnotation.self) {
            arrowProperties(arrow)
        } else if let text = annotation.unwrap(as: TextAnnotation.self) {
            textProperties(text)
        } else if let shape = annotation.unwrap(as: ShapeAnnotation.self) {
            shapeProperties(shape)
        } else if let line = annotation.unwrap(as: LineAnnotation.self) {
            lineProperties(line)
        } else if let highlighter = annotation.unwrap(as: HighlighterAnnotation.self) {
            highlighterProperties(highlighter)
        } else if let blur = annotation.unwrap(as: BlurAnnotation.self) {
            blurProperties(blur)
        }
    }

    // MARK: - Arrow

    @ViewBuilder
    private func arrowProperties(_ arrow: ArrowAnnotation) -> some View {
        Label("Arrow", systemImage: "arrow.up.right")
            .foregroundStyle(.secondary)

        colorRow(label: "Color", color: arrow.color) { newColor in
            var updated = arrow
            updated.color = newColor
            store.update(AnyAnnotation(updated))
        }

        sliderRow(label: "Width", value: arrow.lineWidth, range: 1...10) { newValue in
            var updated = arrow
            updated.lineWidth = newValue
            store.update(AnyAnnotation(updated))
        }

        sliderRow(label: "Head Size", value: arrow.headLength, range: 8...32) { newValue in
            var updated = arrow
            updated.headLength = newValue
            store.update(AnyAnnotation(updated))
        }

        Divider()

        PresetStrip(
            toolType: EditorTool.arrow.rawValue,
            primaryColor: { preset in
                if case .color(let c) = preset.properties["color"] { return c.cgColor }
                return nil
            },
            onSelect: { preset in
                applyPresetToArrow(preset, arrow: arrow)
            },
            onSave: {
                let preset = ArrowTool.extractPreset(from: arrow, name: nextPresetName(for: EditorTool.arrow.rawValue))
                presetManager.addPreset(preset)
            }
        )
    }

    // MARK: - Text

    @ViewBuilder
    private func textProperties(_ text: TextAnnotation) -> some View {
        Label("Text", systemImage: "textformat")
            .foregroundStyle(.secondary)

        colorRow(label: "Color", color: text.color) { newColor in
            var updated = text
            updated.color = newColor
            store.update(AnyAnnotation(updated))
        }

        sliderRow(label: "Font Size", value: text.fontSize, range: 10...72) { newValue in
            var updated = text
            updated.fontSize = newValue
            store.update(AnyAnnotation(updated))
        }

        Divider()

        PresetStrip(
            toolType: EditorTool.text.rawValue,
            primaryColor: { preset in
                if case .color(let c) = preset.properties["color"] { return c.cgColor }
                return nil
            },
            onSelect: { preset in
                applyPresetToText(preset, text: text)
            },
            onSave: {
                let preset = TextTool.extractPreset(from: text, name: nextPresetName(for: EditorTool.text.rawValue))
                presetManager.addPreset(preset)
            }
        )
    }

    // MARK: - Shape

    @ViewBuilder
    private func shapeProperties(_ shape: ShapeAnnotation) -> some View {
        Label("Shape", systemImage: "rectangle")
            .foregroundStyle(.secondary)

        Picker("Kind", selection: Binding(get: { shape.kind }, set: { newKind in
            var updated = shape
            updated.kind = newKind
            store.update(AnyAnnotation(updated))
        })) {
            Text("Rectangle").tag(ShapeKind.rectangle)
            Text("Ellipse").tag(ShapeKind.ellipse)
            Text("Rounded Rect").tag(ShapeKind.roundedRectangle)
        }
        .pickerStyle(.menu)

        colorRow(label: "Stroke", color: shape.strokeColor) { newColor in
            var updated = shape
            updated.strokeColor = newColor
            store.update(AnyAnnotation(updated))
        }

        sliderRow(label: "Width", value: shape.lineWidth, range: 1...10) { newValue in
            var updated = shape
            updated.lineWidth = newValue
            store.update(AnyAnnotation(updated))
        }

        Divider()

        PresetStrip(
            toolType: EditorTool.shape.rawValue,
            primaryColor: { preset in
                if case .color(let c) = preset.properties["strokeColor"] { return c.cgColor }
                return nil
            },
            onSelect: { preset in
                applyPresetToShape(preset, shape: shape)
            },
            onSave: {
                let preset = ShapeTool.extractPreset(from: shape, name: nextPresetName(for: EditorTool.shape.rawValue))
                presetManager.addPreset(preset)
            }
        )
    }

    // MARK: - Line

    @ViewBuilder
    private func lineProperties(_ line: LineAnnotation) -> some View {
        Label("Line", systemImage: "line.diagonal")
            .foregroundStyle(.secondary)

        colorRow(label: "Color", color: line.color) { newColor in
            var updated = line
            updated.color = newColor
            store.update(AnyAnnotation(updated))
        }

        sliderRow(label: "Width", value: line.lineWidth, range: 1...10) { newValue in
            var updated = line
            updated.lineWidth = newValue
            store.update(AnyAnnotation(updated))
        }

        Picker("Style", selection: Binding(get: { line.style }, set: { newStyle in
            var updated = line
            updated.style = newStyle
            store.update(AnyAnnotation(updated))
        })) {
            Text("Solid").tag(LineStyle.solid)
            Text("Dashed").tag(LineStyle.dashed)
        }
        .pickerStyle(.segmented)

        Divider()

        PresetStrip(
            toolType: EditorTool.line.rawValue,
            primaryColor: { preset in
                if case .color(let c) = preset.properties["color"] { return c.cgColor }
                return nil
            },
            onSelect: { preset in
                applyPresetToLine(preset, line: line)
            },
            onSave: {
                let preset = LineTool.extractPreset(from: line, name: nextPresetName(for: EditorTool.line.rawValue))
                presetManager.addPreset(preset)
            }
        )
    }

    // MARK: - Highlighter

    @ViewBuilder
    private func highlighterProperties(_ highlighter: HighlighterAnnotation) -> some View {
        Label("Highlighter", systemImage: "highlighter")
            .foregroundStyle(.secondary)

        colorRow(label: "Color", color: highlighter.color) { newColor in
            var updated = highlighter
            updated.color = newColor
            store.update(AnyAnnotation(updated))
        }

        sliderRow(label: "Width", value: highlighter.lineWidth, range: 5...40) { newValue in
            var updated = highlighter
            updated.lineWidth = newValue
            store.update(AnyAnnotation(updated))
        }

        Divider()

        PresetStrip(
            toolType: EditorTool.highlighter.rawValue,
            primaryColor: { preset in
                if case .color(let c) = preset.properties["color"] { return c.cgColor }
                return nil
            },
            onSelect: { preset in
                applyPresetToHighlighter(preset, highlighter: highlighter)
            },
            onSave: {
                let preset = HighlighterTool.extractPreset(from: highlighter, name: nextPresetName(for: EditorTool.highlighter.rawValue))
                presetManager.addPreset(preset)
            }
        )
    }

    // MARK: - Blur

    @ViewBuilder
    private func blurProperties(_ blur: BlurAnnotation) -> some View {
        Label("Blur", systemImage: "aqi.medium")
            .foregroundStyle(.secondary)

        Picker("Style", selection: Binding(get: { blur.style }, set: { newStyle in
            var updated = blur
            updated.style = newStyle
            store.update(AnyAnnotation(updated))
        })) {
            Text("Gaussian").tag(BlurStyle.gaussian)
            Text("Pixelate").tag(BlurStyle.pixelate)
        }
        .pickerStyle(.segmented)

        sliderRow(label: "Intensity", value: blur.intensity, range: 2...30) { newValue in
            var updated = blur
            updated.intensity = newValue
            store.update(AnyAnnotation(updated))
        }

        Divider()

        PresetStrip(
            toolType: EditorTool.blur.rawValue,
            primaryColor: { _ in nil },
            onSelect: { preset in
                applyPresetToBlur(preset, blur: blur)
            },
            onSave: {
                let preset = BlurTool.extractPreset(from: blur, name: nextPresetName(for: EditorTool.blur.rawValue))
                presetManager.addPreset(preset)
            }
        )
    }

    // MARK: - Preset Application

    private func applyPresetToArrow(_ preset: ToolPreset, arrow: ArrowAnnotation) {
        var updated = arrow
        if case .color(let c) = preset.properties["color"] { updated.color = c.cgColor }
        if case .number(let v) = preset.properties["lineWidth"] { updated.lineWidth = v }
        if case .number(let v) = preset.properties["headLength"] { updated.headLength = v }
        store.update(AnyAnnotation(updated))
        (LibraryViewModel.shared.currentToolHandler as? ArrowTool)?.applyPreset(preset)
    }

    private func applyPresetToText(_ preset: ToolPreset, text: TextAnnotation) {
        var updated = text
        if case .color(let c) = preset.properties["color"] { updated.color = c.cgColor }
        if case .number(let v) = preset.properties["fontSize"] { updated.fontSize = v }
        store.update(AnyAnnotation(updated))
        (LibraryViewModel.shared.currentToolHandler as? TextTool)?.applyPreset(preset)
    }

    private func applyPresetToShape(_ preset: ToolPreset, shape: ShapeAnnotation) {
        var updated = shape
        if case .string(let k) = preset.properties["kind"], let parsed = ShapeKind(rawValue: k) { updated.kind = parsed }
        if case .color(let c) = preset.properties["strokeColor"] { updated.strokeColor = c.cgColor }
        if case .number(let v) = preset.properties["lineWidth"] { updated.lineWidth = v }
        store.update(AnyAnnotation(updated))
        (LibraryViewModel.shared.currentToolHandler as? ShapeTool)?.applyPreset(preset)
    }

    private func applyPresetToLine(_ preset: ToolPreset, line: LineAnnotation) {
        var updated = line
        if case .color(let c) = preset.properties["color"] { updated.color = c.cgColor }
        if case .number(let v) = preset.properties["lineWidth"] { updated.lineWidth = v }
        if case .string(let s) = preset.properties["style"], let parsed = LineStyle(rawValue: s) { updated.style = parsed }
        store.update(AnyAnnotation(updated))
        (LibraryViewModel.shared.currentToolHandler as? LineTool)?.applyPreset(preset)
    }

    private func applyPresetToHighlighter(_ preset: ToolPreset, highlighter: HighlighterAnnotation) {
        var updated = highlighter
        if case .color(let c) = preset.properties["color"] { updated.color = c.cgColor }
        if case .number(let v) = preset.properties["lineWidth"] { updated.lineWidth = v }
        store.update(AnyAnnotation(updated))
        (LibraryViewModel.shared.currentToolHandler as? HighlighterTool)?.applyPreset(preset)
    }

    private func applyPresetToBlur(_ preset: ToolPreset, blur: BlurAnnotation) {
        var updated = blur
        if case .string(let s) = preset.properties["style"], let parsed = BlurStyle(rawValue: s) { updated.style = parsed }
        if case .number(let v) = preset.properties["intensity"] { updated.intensity = v }
        store.update(AnyAnnotation(updated))
        (LibraryViewModel.shared.currentToolHandler as? BlurTool)?.applyPreset(preset)
    }

    // MARK: - Helpers

    private func nextPresetName(for toolType: String) -> String {
        let existing = presetManager.presets(for: toolType)
        return "Preset \(existing.count + 1)"
    }

    @ViewBuilder
    private func colorRow(label: String, color: CGColor, onChange: @escaping (CGColor) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(cgColor: color) ?? .red },
                set: { onChange(NSColor($0).cgColor) }
            ))
            .labelsHidden()
        }
    }

    @ViewBuilder
    private func sliderRow(label: String, value: CGFloat, range: ClosedRange<CGFloat>, onChange: @escaping (CGFloat) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f", value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range)
        }
    }
}

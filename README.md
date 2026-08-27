# ScreenSnipe

A lightweight, native macOS app for capturing screenshots, recording your screen, and annotating with precision. All captures are organized in a local library.

> Heads up: this app is mostly vibe-coded — built with heavy help from AI coding agents. I made it for my own use and figured others might find it useful too. Even with AI, getting a native macOS app to feel right takes real effort, so I'm sharing the result.

Free on the [Mac App Store](https://apps.apple.com/app/screen-snipe/id6759236400). Open source under the [MIT License](LICENSE). Website: [screensnipe.app](https://screensnipe.app).

## Features

### Capture
- **Screenshots**: Full screen, region selection, or window picker
- **Screen recording**: Full screen, region, or window with pause/resume, 3-2-1 countdown, and recording border indicator
- **Series capture**: Pick a region, window, or full screen once, then snap as many stills of that target as you need from a floating control panel or with a shortcut (⌃⇧Space). All frames land in a single library entry
- **Audio recording**: System audio capture and microphone input with device selection
- **Post-capture behavior**: Open in editor, copy to clipboard, or both (configurable)

### Annotation & Editing
- **Tools**: Arrow, text, shape (rectangle/ellipse/rounded rect), line, highlighter, blur, and non-destructive crop
- **Property inspector**: Side panel to customize color, line width, arrow head size, blur style/intensity, font, fill, and line style
- **Tool presets**: Save up to 6 presets per tool for quick access
- **Text editing**: Double-click any text annotation to re-edit; live font size updates from the property panel
- **Undo/Redo**: Full undo/redo support for all annotations
- **Text recognition (OCR)**: Extract text from captures using the Vision framework; AI-powered text cleanup on macOS 26+
- **Tool shortcuts**: V (Select), A (Arrow), T (Text), S (Shape), L (Line), H (Highlighter), B (Blur), C (Crop)
- **Series frame navigation**: Annotate every frame of a series independently; jump between frames with the filmstrip under the canvas, the toolbar chevrons, or ⌥← / ⌥→. Click the filmstrip to focus it and plain ← / → step through frames (the canvas keeps plain arrows for nudging a selected annotation)

### Library
- **Persistent library**: All captures auto-saved to `~/Pictures/ScreenSnipe/` (configurable location)
- **Library browser**: NavigationSplitView sidebar with embedded editor and video player
- **Multi-selection**: Cmd/Shift+Click to select multiple items in the sidebar
- **Search**: Toolbar search field filters the sidebar by name, description, or tag (case-insensitive substring match); `is:shared`, `is:image`, `is:video`, and `is:series` narrow results to shared captures, screenshots, recordings, or series (also available from the search field's magnifier menu)
- **Stitch Together**: Combine multiple screenshots, recordings, and series into a single video with configurable pauses and image durations, drag-to-reorder, and automatic letterboxing. A series expands to one clip per frame, so a single series can be stitched on its own
- **Auto-save**: Annotations persist automatically on edit (300ms debounce)

### Export
- **Save**: Export flattened image as PNG/JPEG, or a whole series as a single multi-page TIFF or PDF
- **Copy to clipboard**: One-click copy with toast confirmation
- **Share**: System share sheet integration
- **Copy iCloud Link**: Publish a capture as a public iCloud download link anyone can open in a browser; revoke via Stop Sharing (requires iCloud provisioning, see [developer/ICLOUD-SHARING.md](developer/ICLOUD-SHARING.md))

### Preferences
- **Configurable shortcuts**: All capture and recording shortcuts customizable with conflict detection
- **Library location**: Choose a custom folder for capture storage
- **Zoom controls**: Fit-to-window, actual size, zoom in/out (Cmd+0/1/+/-)

### UI
- **Menu bar app**: Quick access from the status bar
- **Dark mode**: Full dark mode support
- **Liquid glass**: macOS 26 liquid glass sidebar with transparency

## Requirements

- macOS 14.0+
- Xcode 16.0+
- Screen Recording permission (prompted on first use)

## Building

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`.

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate and build
xcodegen generate
xcodebuild -project ScreenSnipe.xcodeproj -scheme ScreenSnipe build
```

## Running Tests

```bash
xcodebuild -project ScreenSnipe.xcodeproj -scheme ScreenSnipeTests test
```

## Usage

ScreenSnipe runs as a menu bar app. Click the camera icon in the menu bar to access:

- **Capture > Region** (Cmd+Shift+5) — Select a screen region to capture
- **Capture > Full Screen** (Cmd+Shift+6) — Capture the entire screen
- **Capture > Window** (Cmd+Shift+7) — Pick a window to capture
- **Record > Full Screen** (Cmd+Shift+8) — Record the full screen
- **Record > Region** — Record a selected screen region
- **Record > Window** — Record a specific window
- **Stop Recording** (Cmd+Shift+9) — Stop an active recording
- **Series > Region / Full Screen / Window** — Start a series of stills of one target
- **Snap Series Frame** (Ctrl+Shift+Space) — Capture the next frame; **Ctrl+Shift+Return** finishes, **Ctrl+Shift+Esc** cancels
- **Library** (Cmd+L) — Open the capture library
- **Preferences** (Cmd+,) — Configure shortcuts and library storage location

All shortcuts are configurable in Preferences with conflict detection.

## Architecture

```
ScreenSnipe/
  App/              # App entry point, AppDelegate with menu bar
  Capture/          # CaptureCoordinator, region/window selection, countdown, recording border
  Editor/           # CanvasView, CanvasRepresentable, property panel
    Tools/          # Individual annotation tools (arrow, text, shape, line, etc.)
  Library/          # Library window, sidebar, detail view, preferences
  Models/           # Annotation types, annotation store, codable serialization
  Services/         # Screen capture, image export, video recording, shortcuts, library manager
  Resources/        # Info.plist, asset catalog
docs/               # Landing page served via GitHub Pages at screensnipe.app
```

## Library Storage

Captures are stored in `~/Pictures/ScreenSnipe/` (configurable in Preferences). Each capture gets a timestamped folder:

```
~/Pictures/ScreenSnipe/
  2024-01-15-10-30-45-123/
    screenshot.png          # Original capture
    annotations.json        # Serialized annotations
    thumbnail.png           # 200px thumbnail for sidebar
  2024-01-15-11-00-12-456/
    recording.mp4           # Video recording
    annotations.json
    thumbnail.png
  2024-01-15-11-42-08-901/
    series.json             # Frame order, count, and capture target
    frames/
      frame-001.png         # One file per frame
      frame-001.json        # Annotations for that frame
      frame-002.png
      frame-002.json
    thumbnail.png
```

Series frames are stored as individual PNGs rather than a multi-page TIFF: appending a frame to a TIFF means rewriting the whole file with every frame held in memory, and per-frame annotations need a sidecar either way. Multi-page TIFF is offered as an export format instead. Frame indices in `series.json` are never renumbered, so deleting a frame leaves the remaining files untouched.

## Website

The `docs/` folder contains a single-page landing page (plain HTML/CSS, no dependencies) served via GitHub Pages at [screensnipe.app](https://screensnipe.app). Includes SEO meta tags, Open Graph image, favicon, and structured data.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the build and PR flow, and [SECURITY.md](SECURITY.md) for vulnerability reporting.

## License

[MIT](LICENSE) — © 2026 Aleksandar Vucetic. The "Screen Snipe" name, logo, and app icon are excluded from the license; please don't reuse them to identify forks or derivatives.

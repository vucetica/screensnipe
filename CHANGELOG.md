# Changelog

All notable changes to ScreenSnipe will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.1] - 2026-05-11

Maintenance release — no user-facing app changes. Establishes the open-source project scaffolding for the public GitHub repository: Code of Conduct, support documentation, issue and pull request templates, GitHub Actions build check, and Dependabot.

## [1.6.0] - 2026-05-09

Initial public release on the Mac App Store and GitHub.

### Added
- Screenshots: full screen, region selection, and window picker
- Screen recording: full screen, region, and window with pause/resume, 3-2-1 countdown, and a red border indicator
- Audio recording: system audio and microphone input with device selection
- Configurable post-capture behavior: open in editor, copy to clipboard, or both
- Annotation tools: arrow, text, shape (rectangle/ellipse/rounded rect), line, highlighter, blur, non-destructive crop
- Property inspector with per-tool customization (color, line width, arrow head size, blur style/intensity, font, fill, line style)
- Tool presets (up to 6 per tool)
- Double-click to re-edit any text annotation; live font size updates from the property panel
- Undo/redo for all annotations
- Text recognition (OCR) via the Vision framework; AI-powered text cleanup on macOS 26+
- Single-key tool shortcuts: V, A, T, S, L, H, B, C
- Persistent library at `~/Pictures/ScreenSnipe/` with configurable location
- NavigationSplitView library browser with embedded editor and video player
- Multi-selection in the library sidebar (Cmd/Shift+Click)
- Stitch Together: combine multiple captures into a single video with configurable pauses, drag-to-reorder, and automatic letterboxing
- Auto-save annotations (300ms debounce)
- Export as PNG/JPEG, copy to clipboard with toast confirmation, system share sheet
- Configurable shortcuts with conflict detection
- Zoom controls (Cmd+0/1/+/-)
- Menu bar app with full dark mode and macOS 26 liquid glass sidebar

[Unreleased]: https://github.com/vucetica/screensnipe/compare/v1.6.1...HEAD
[1.6.1]: https://github.com/vucetica/screensnipe/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/vucetica/screensnipe/releases/tag/v1.6.0

# Changelog

All notable changes to ScreenSnipe will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.8.0] - 2026-07-24

### Added
- Search filters: `is:shared`, `is:image`, and `is:video` narrow the library search to shared captures, screenshots, or recordings, and combine with free text. The filters are also available from the search field's magnifier dropdown.
- Copy iCloud Link: publish a capture (annotated screenshot or recording) as a public iCloud download link that anyone can open in a browser, via the library toolbar or the sidebar context menu. Shared captures show a link badge in the sidebar, a toast confirms each copy (with a one-time explainer after the first share), and Stop Sharing revokes the link. Requires iCloud provisioning before it can be enabled; see developer/ICLOUD-SHARING.md.

### Changed
- The downloadable DMG now opens with the standard drag-to-install layout: the app next to an Applications folder shortcut.

### Fixed
- The app can no longer be launched multiple times; a second launch hands off to the already running instance and exits.

## [1.7.2] - 2026-07-23

### Added
- GitHub Releases now include a signed, notarized DMG (and ZIP) of the app for direct download outside the App Store.

### Fixed
- Starting a capture while another capture is already in progress no longer causes issues.

## [1.7.1] - 2026-07-23

Maintenance release — build and release automation only, no user-facing changes.

## [1.7.0] - 2026-05-13

### Added
- Per-entry tags: tag captures from a unified Edit dialog with name, description, and tag-token input. Tags render as pills on each sidebar row.
- Library search: toolbar search field filters the sidebar by name, description, tag, or capture date (case-insensitive substring match).

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

[Unreleased]: https://github.com/vucetica/screensnipe/compare/v1.8.0...HEAD
[1.8.0]: https://github.com/vucetica/screensnipe/compare/v1.7.2...v1.8.0
[1.7.2]: https://github.com/vucetica/screensnipe/compare/v1.7.1...v1.7.2
[1.7.1]: https://github.com/vucetica/screensnipe/compare/v1.7.0...v1.7.1
[1.7.0]: https://github.com/vucetica/screensnipe/compare/v1.6.1...v1.7.0
[1.6.1]: https://github.com/vucetica/screensnipe/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/vucetica/screensnipe/releases/tag/v1.6.0

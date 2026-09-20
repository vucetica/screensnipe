# Architecture

A map of the Screen Snipe codebase for contributors. For build commands see
[CLAUDE.md](../CLAUDE.md); for CI/CD and releasing see [RELEASE.md](RELEASE.md).

## Overview

Screen Snipe is a **menu-bar-only macOS app** (no Dock icon, `LSUIElement`)
written in **SwiftUI + AppKit**, targeting **macOS 14+** with **Swift 6 strict
concurrency**. The project is generated with **XcodeGen** (`project.yml`) —
never edit `ScreenSnipe.xcodeproj` directly.

State management is the classic **`ObservableObject` + `@Published` + Combine**
pattern (no `@Observable` macro). Shared services are `.shared` singletons;
SwiftUI views observe them via `@StateObject` / `@ObservedObject`.

## Folder map (`ScreenSnipe/`)

| Folder | Responsibility |
|---|---|
| `App/` | Entry point and menu bar. `ScreenSnipeApp` (`@main`, only a `Settings` scene) and `AppDelegate` (owns the `NSStatusItem`, builds the menu, blinks the record indicator, registers global hotkeys). |
| `Capture/` | Capture orchestration and overlay windows. |
| `Editor/` | Annotation canvas and drawing tools. |
| `Library/` | Library window, preferences, stitch UI. |
| `Models/` | Pure value types: annotations, tool enums, settings models. |
| `Services/` | Singleton/stateless services (capture, recording, storage, export, OCR…). |
| `UI/` | `TextCapturePanel` (OCR results). |
| `Views/` | Small shared views (`CopiedToast`, `ShortcutRecorderView`). |
| `Resources/` | Info.plist, asset catalog, entitlements. |

## Capture pipeline

Orchestrated by **`CaptureCoordinator`** (`Capture/`), a state machine
(`idle → selectingRegion / selectingWindow → capturing → editing / recording`).
It checks screen-recording permission
(`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`), runs the
capture, then routes the result per `CaptureSettings.postCaptureBehavior`
(copy to clipboard and/or save via `LibraryManager` and open the editor).

- **Still images** — `ScreenCaptureService` uses `CGWindowListCreateImage` for
  full-screen, region, and window captures. ScreenCaptureKit
  (`SCShareableContent`) is used only to enumerate windows and to trigger the
  permission prompt. Region capture freezes a full-screen image first, then
  shows `RegionSelectionWindow` (a full-screen `NSPanel`) for the rubber-band
  selection and crops.
- **Video** — `VideoRecordingService` uses ScreenCaptureKit `SCStream`
  (content filters for full screen / region / window) feeding an
  `AVAssetWriter` (HEVC .mp4) with inputs for video, system audio, and mic
  (`AVCaptureSession`). Pause/resume works by adjusting CMTime offsets on a
  dedicated serial `videoQueue`.
- Supporting UI: `WindowPickerView`, `CountdownOverlay` (3-2-1),
  `RecordingBorderWindow` (red border while recording).

## Editor

- **Annotations** are value types conforming to the `Annotation` protocol
  (`Models/Annotation.swift`): `ArrowAnnotation`, `TextAnnotation`,
  `ShapeAnnotation`, `LineAnnotation`, `HighlighterAnnotation`,
  `BlurAnnotation` — wrapped in the type-erased `AnyAnnotation`. They draw
  themselves with CoreGraphics.
- **Tools** are classes conforming to `ToolHandler` (mouse/keyboard events),
  one per tool in `Editor/Tools/` (`SelectionTool`, `ArrowTool`, `TextTool`,
  `ShapeTool`, `LineTool`, `HighlighterTool`, `BlurTool`, `CropTool`). The
  `EditorTool` enum lists them with their single-key shortcuts
  (V, A, T, S, L, H, B, C).
- **Canvas**: `CanvasView` is an AppKit `NSView` doing all drawing, bridged
  into SwiftUI via `CanvasRepresentable` and hosted in
  `LibraryDetailView.imageEditor`.
- **State/undo**: `AnnotationStore` holds `[AnyAnnotation]`, the crop rect,
  and the selection; undo/redo are snapshot stacks pushed before every
  mutation.
- **Persistence**: `CodableAnnotation` / `AnnotationSerializer` serialize
  edits to `annotations.json` next to the capture.
- Style presets: `ToolPreset` / `PresetManager` / `PresetStrip` (up to 6 per
  tool). `PropertyPanel` edits the selected annotation's attributes.

### Video trim

The video counterpart of the image crop: a stored time range that is applied at
export time and never written back to `recording.mp4`.

- `VideoTrimRange` / `CodableCMTime` (`Models/`) persist the range as CMTime
  parts, so a handle dropped on a frame boundary stays on it across a save.
- It lives in `CaptureMetadata.trim` in `metadata.json`, **not** in
  `annotations.json`. `LibraryManager.reload()` already reads `metadata.json`
  for every entry, so the trim is in memory when the sidebar draws a row and
  when `StitchConfiguration.resolvedSources()` builds its sources; from the
  annotation sidecar, which is only read for the selected entry, both would
  need a per-entry disk read.
- `VideoTrimStore` (`Models/`) holds the live selection. Separate from
  `AnnotationStore` because toolbar Undo is gated on `selectedImage != nil`, so
  a trim on its undo stack would be unreachable. "Reset Trim" is the escape
  hatch instead. `LibraryViewModel` gives it its own 300 ms debounce
  (`scheduleTrimSave` / `flushPendingTrimSave` / `cancelPendingTrimSave`),
  parallel to the annotation one.
- `VideoTrimBarView` + `VideoFilmstripGenerator` (`Library/`) draw the strip
  under the player, modeled on `SeriesFilmstripView`. No toolbar item and no
  mode: the bar exists whenever a video entry is selected.
- `VideoPlayerView` keeps the full asset and bounds playback with
  `AVPlayerItem.forwardPlaybackEndTime`, rather than handing the player a
  trimmed composition, so dragging a handle can still seek outside the range
  for preview. Its `Coordinator` owns the player, a 10 Hz playhead observer,
  and `VideoPlaybackController`, which is how the trim bar scrubs.
- `VideoTrimExporter` (`Services/`) is the single trimmed-export engine, used by
  save, share and the iCloud publish (via `VideoTrimStaging`). It re-encodes the
  video: a compressed passthrough cut can only begin on a sync sample, and
  recordings carry one per second, so a copy-based trim would miss the handle by
  up to a second. Untrimmed exports never reach it and stay lossless.
- `StitchService.appendVideo` sets `timeRange` on its readers and swaps
  `startTime` for `offset = startTime - trimStart` in every output-time
  expression, seeding its source-time trackers from the trim start.

## Library & persistence

**No SwiftData/CoreData — plain filesystem.** `LibraryManager.shared` stores
each capture as a timestamped folder (`yyyy-MM-dd-HH-mm-ss-SSS`) containing:

```
screenshot.png | recording.mp4
annotations.json     # editor state
metadata.json        # CaptureMetadata: name, description, tags, share link, video trim
thumbnail.png
```

The library location is user-chosen and persisted as a **security-scoped
bookmark** in UserDefaults. `LibraryViewModel` drives browsing, multi-select,
search/tags, and the stitch flow (`StitchService` composites multiple captures
into one MP4 via AVFoundation + Metal-backed CIContext).

## Services (`Services/`)

- `ScreenCaptureService` / `VideoRecordingService` — capture (see above)
- `LibraryManager` — library storage singleton
- `GlobalHotkeyManager` — Carbon `RegisterEventHotKey` global shortcuts
- `ShortcutManager` — user-remappable shortcuts with conflict detection
- `AudioSettings` — system-audio toggle, microphone selection
- `CaptureSettings` — post-capture behavior
- `PresetManager` — tool style presets
- `ImageExportService` / `VideoExportService` — stateless exporters
- `VideoTrimExporter` / `VideoTrimStaging` — time-bounded video export, shared by
  save, share and iCloud publishing
- `StitchService` — multi-capture video compositing
- `TextRecognitionService` — Vision OCR; optional FoundationModels cleanup on
  macOS 26+ (`#if canImport(FoundationModels)`)
- `ErrorReporter` — error-reporting helper

## Permissions & signing

- Sandboxed + hardened runtime; entitlements in `ScreenSnipe.entitlements`
  (Debug uses `ScreenSnipeDebug.entitlements` and a separate bundle ID
  `app.screensnipe.app.debug`).
- Runtime permissions: screen capture (`NSScreenCaptureUsageDescription`),
  microphone, camera. Screen-capture access is requested at runtime; mic via
  `AVCaptureDevice.requestAccess(for: .audio)`.

## Concurrency notes

Strict concurrency is on (`SWIFT_STRICT_CONCURRENCY: complete`). Most
coordinators/stores are `@MainActor`. `VideoRecordingService` deliberately
uses `nonisolated(unsafe)` state confined to its serial `videoQueue`;
`AppDelegate.menuNeedsUpdate` uses `MainActor.assumeIsolated`. Keep new code
actor-correct rather than adding `nonisolated(unsafe)`.

## Known workarounds

- `VideoPlayerView` wraps `AVPlayerView` directly (instead of SwiftUI
  `VideoPlayer`) to avoid an `_AVKit_SwiftUI` crash on macOS 26.3
  (`Library/LibraryDetailView.swift`).
- More gotchas are documented in the "Gotchas" section of
  [CLAUDE.md](../CLAUDE.md) — check there before changing capture, editor, or
  windowing code.

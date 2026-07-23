# Project Guidelines

## Build & Test

```bash
xcodegen generate && xcodebuild -project ScreenSnipe.xcodeproj -scheme ScreenSnipe -destination 'platform=macOS' build
```
We are building just to check for syntax errors. User will run the software manually.
The `-destination 'platform=macOS'` flag is required — without it xcodebuild tries to resolve simulator runtimes and fails. This command also needs `dangerouslyDisableSandbox: true` to write to DerivedData.

## Project Setup

- macOS 14+ app, Swift 6 with strict concurrency, XcodeGen (`project.yml`)
- Signed with manual identity + DEVELOPMENT_TEAM for stable TCC matching
- Test target needs `GENERATE_INFOPLIST_FILE: YES` in project.yml

## Versioning

- Bump the **minor** version (second number) for releases: 1.1.0 → 1.2.0 → 1.3.0
- `CURRENT_PROJECT_VERSION` (build number) is managed automatically — do not change it manually

## Releasing

`main` is a protected branch — all changes go through PRs, including releases. Tags are `vX.Y.Z` (annotated).

1. **Bump `MARKETING_VERSION`** in `project.yml` (minor bump per Versioning above)
2. **Update `CHANGELOG.md`**:
   - Rename `## [Unreleased]` → `## [X.Y.0] - YYYY-MM-DD`
   - Add a fresh empty `## [Unreleased]` section above it
   - Update bottom comparison links: change `[Unreleased]: …/compare/vX.Y.0...HEAD` and add `[X.Y.0]: …/compare/vPREV...vX.Y.0`
3. **Branch from `main`**, push, open a PR. The `build.yml` CI must pass before merge.
4. **After merge**, tag against the actual merge commit (not the local branch HEAD — the SHA may differ if GitHub squashes/rebases):
   ```bash
   git checkout main && git pull
   git tag -a vX.Y.0 -m "vX.Y.0 — <one-line summary>"
   git push origin vX.Y.0
   ```
5. **CI builds automatically**: pushing the tag runs `release.yml` — the `app-store` job exports the signed `.pkg` and uploads it to App Store Connect, and the `notarized-app` job produces a notarized `.app` packed as both a `.zip` and a signed/notarized `.dmg`. Both are workflow artifacts on every run, and on tags they're also attached to the GitHub Release. Submit for review manually in App Store Connect; Apple review typically takes ~24h.
6. **CI/CD setup, secrets, and certificate renewal** are documented in [RELEASE.md](RELEASE.md).

## Design Philosophy

- **Native look is paramount**: Always match native macOS appearance. Use system-provided components (NavigationSplitView, List with .sidebar style) over custom implementations.
- **Liquid glass (macOS 26)**: Sidebars must extend behind traffic light buttons. Requires `.fullSizeContentView` style mask, `titlebarAppearsTransparent = true`, and `titleVisibility = .hidden` on NSWindow.
- **Avoid custom toolbars when possible**: SwiftUI `.toolbar` items shift when hosted in NSHostingView windows. Use NSToolbar only when stable positioning is critical.
- **Prefer system controls**: Use NavigationSplitView (not custom HStack splits) for sidebars. Let the system handle sidebar toggle, resize, and vibrancy.

## Architecture

- **Menu-bar driven**: No default WindowGroup, uses `Settings { PreferencesView() }`
- **CaptureCoordinator**: State machine orchestrating capture flow (idle -> selecting -> capturing -> editing)
- **Library system**: Captures auto-saved to `~/Pictures/ScreenSnipe/` (configurable), annotations serialized to JSON
- **LibraryWindow**: Singleton NSWindow with fullSizeContentView, hosts NavigationSplitView (sidebar + detail)
- **LibraryViewModel**: Shared singleton, auto-saves annotations with 300ms debounce via Combine
- **CanvasView**: NSView (`isFlipped=true`) wrapped in NSViewRepresentable, handles drawing + mouse events
- **ToolHandler protocol**: `mouseDown`/`mouseDragged`/`mouseUp`/`keyDown`/`cursor` per tool
- **AnyAnnotation**: Type-erased wrapper for heterogeneous annotation storage
- **AnnotationStore**: `@MainActor ObservableObject` with undo/redo via array snapshots
- **CodableAnnotation**: Wrappers (`CodableColor`, `CodablePoint`, `CodableRect`) + envelope-based serialization
- **RecordingBorderWindow**: Transparent click-through NSPanel drawing a red border around recorded region/window during recording
- **Preferences**: Tabbed PreferencesView (Shortcuts, Library) with configurable keyboard shortcuts and library location

## Key Patterns

- CGWindowListCreateImage for capture (not SCScreenshotManager) — more reliable with TCC
- ScreenCaptureKit only used for `availableWindows()` metadata
- TextTool must inherit NSObject for NSTextFieldDelegate conformance
- NSTextFieldDelegate `controlTextDidEndEditing` must be `nonisolated` with `Task { @MainActor in }` wrapper
- Region capture: hide overlay, sleep 100ms, then capture to avoid self-capture
- NSSplitView `autosaveName` persists sidebar width (find it in view hierarchy after window setup)
- **SwiftUI + NSHostingView gotcha**: Modifying `@Published` properties in `didSet` of another `@Published` property causes "publishing changes within view updates". Fix: use Combine `$property.receive(on: DispatchQueue.main).sink` to defer updates to next run loop.
- **Recording border z-ordering**: Use `panel.order(.above, relativeTo: Int(windowID))` at `.normal` level instead of `.floating` — floating level shows the border above unrelated windows
- **Recording border coordinate conversion**: CG coordinates (Y-down from top-left) → NS coordinates (Y-up from bottom-left): `nsY = primaryScreenHeight - cgY - cgHeight`. Use `NSScreen.screens.first` (primary), not `.main` (key window's screen)
- **Double-click text editing from any tool**: CanvasView creates an ad-hoc `inlineEditTool` (TextTool) for editing existing text annotations regardless of which tool is active. Committed via `commitActiveText()` on next non-double-click mouseDown.
- **TextTool Combine observation**: Subscribes to `store.$annotations` to detect external changes (e.g., font size from property panel) and update the live text field
- **CanvasRepresentable store tracking**: Coordinator must track `currentStore` and recreate tool handlers when the store changes (happens when switching library entries)
- **selectAll in text edit mode**: Must defer `currentEditor()?.selectAll(nil)` via `DispatchQueue.main.async` — calling it synchronously triggers `controlTextDidEndEditing` which tears down the edit session

## Website

- `docs/` folder contains a single-page landing page (plain HTML/CSS, zero dependencies), served via GitHub Pages at https://screensnipe.app
- The folder name `docs/` is required by GitHub Pages (only `/` and `/docs` are valid Pages sources on `main`)
- `docs/CNAME` holds the custom domain; `docs/.nojekyll` disables Jekyll processing
- Mac App Store product page style with blue accent matching app icon
- SEO: Open Graph, Twitter Card, structured data (JSON-LD), favicon, apple-touch-icon
- Images generated from existing app icon in Assets.xcassets using `sips` for resizing

## Documentation

- Always use Markdown (.md) format when writing specifications or documentation
- README.md file with the most important decisions, new features etc.
- When implementing a new user-facing feature, update the Features section in README.md to include it

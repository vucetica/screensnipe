# App Store Screenshots

## Requirements

- **Size**: 2880 x 1800 pixels (16" Retina) — required for Mac App Store
- **Format**: PNG or JPEG
- **Count**: Minimum 1, maximum 10 (aim for 5)
- **No alpha channel**: Screenshots must not have transparency

## Suggested Scenes

Take these on a clean desktop with a nice wallpaper. Hide other menu bar icons if possible.

### 1. `screenshot-region-capture.png`
**Region capture selection overlay**
- Trigger a region capture (menu bar → Capture → Region)
- Draw a selection around an interesting area
- Screenshot the full screen while the selection overlay is active

### 2. `screenshot-annotation-editor.png`
**Annotation editor with tools in use**
- Open a capture in the editor
- Add an arrow pointing to something, a text annotation, and a blur region
- Show the toolbar with tool options visible

### 3. `screenshot-library.png`
**Library view with sidebar**
- Open the library (menu bar → Library)
- Have 5-10 captures in the library
- Select one so the detail view shows the capture with annotations

### 4. `screenshot-recording.png`
**Screen recording with red border indicator**
- Start a region or window recording
- Screenshot the screen while the red border is visible
- The menu bar should show the red recording indicator

### 5. `screenshot-preferences.png`
**Preferences with keyboard shortcuts**
- Open Preferences
- Show the Shortcuts tab with configured hotkeys

## How to Take Screenshots

```bash
# Full screen capture at Retina resolution
screencapture -x screenshot-name.png

# Timed (5 second delay, useful for capturing menus/overlays)
screencapture -x -T 5 screenshot-name.png

# Verify dimensions
sips -g pixelWidth -g pixelHeight screenshot-name.png
```

The screenshots must be exactly 2880 x 1800. If your display is different, resize:
```bash
sips -z 1800 2880 screenshot-name.png
```

## Placeholder Files

Place your final screenshots in this folder:
- `distribution/screenshots/screenshot-region-capture.png`
- `distribution/screenshots/screenshot-annotation-editor.png`
- `distribution/screenshots/screenshot-library.png`
- `distribution/screenshots/screenshot-recording.png`
- `distribution/screenshots/screenshot-preferences.png`

# App Review Notes

Paste this into the "Notes for Review" field in App Store Connect.

---

```
Screen Snipe is a menu bar utility - it does not appear in the Dock.
After launch, look for the camera viewfinder icon (⌘) in the menu bar (top-right of screen).

To test:
1. Click the menu bar icon → Capture → Region (or press the configured hotkey)
2. Grant Screen Recording permission when prompted (System Settings → Privacy & Security → Screen Recording)
3. Draw a selection rectangle on screen to capture
4. The capture opens in the annotation editor
5. Use the toolbar to add arrows, text, shapes, or blur

Screen Recording permission is required for all capture and recording features.

Pricing: Screen Snipe is free. There are no in-app purchases or subscriptions in this version. (A previous version offered a yearly subscription; that product has been removed from sale and existing subscribers retain access until their term ends.)

Screen Recording Usage:
- Screenshots use CGWindowListCreateImage (CoreGraphics) to capture still images.
- Screen recordings use ScreenCaptureKit (SCStream) to record video.
- All captures and recordings are saved locally to ~/Pictures/ScreenSnipe/ (configurable).
- No data is transmitted, collected, or shared. No third-party SDKs are used.
- Privacy policy: https://screensnipe.app/privacy

In more detail
==========

1. All app features which use screen recording:

Screen Snipe uses macOS screen recording permission for two features:

- Screenshots: Captures still images using CGWindowListCreateImage (CoreGraphics). Three modes: full screen, user-drawn region, and individual window.

- Screen Recording: Records video using ScreenCaptureKit (SCStream), saved as .mp4 via AVFoundation. Supports full screen, region, or window recording with optional system audio and microphone.

Both features are user-initiated only. The app never captures the screen in the background.

2. What data is collected via screen recording:

No data is "collected" in the traditional sense. Screen recording permission is used solely to create screenshot images (PNG) and screen recording videos (MP4) that the user explicitly requests. After capture, users can annotate images with arrows, text, shapes, highlights, and blur. Annotations are saved as JSON metadata alongside the files. No personal data, analytics, identifiers, or telemetry are collected.

3. Purpose of collecting this information:

The sole purpose is the app's core functionality: letting users capture, annotate, and organize screenshots and screen recordings. Screen recording permission is required to perform the app's primary function.

4. Will the data be shared with any third parties?

No. Screen Snipe contains zero third-party SDKs, zero analytics frameworks, zero advertising libraries, and makes zero network requests.

5. Where is the data stored?

All screenshots, recordings, and annotations are stored locally on the user's Mac in a user-configurable folder (default: ~/Pictures/ScreenSnipe/). Files never leave the device. App preferences are stored in standard macOS UserDefaults.

6. Relevant privacy policy sections:

Our privacy policy at https://screensnipe.app/privacy covers this:

- "Overview": "The app operates entirely on your Mac with no data collection, no analytics, no tracking, and no network connections."

- "Data collection": "Screen Snipe does not collect, transmit, or store any personal data." Lists no analytics, no crash reporting, no advertising, no accounts, no cookies.

- "Local data": "All screenshots, screen recordings, and annotations are saved locally on your Mac in a folder you choose (default: ~/Pictures/ScreenSnipe/). This data never leaves your device."

- "Permissions": "Screen Recording — required to capture screenshots and record your screen. Microphone — optional, used only when you choose to record audio with screen recordings."

- "Third-party services": "Screen Snipe does not integrate with any third-party services, SDKs, or APIs."
```

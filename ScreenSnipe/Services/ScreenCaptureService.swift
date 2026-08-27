import AppKit
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class ScreenCaptureService {

    enum CaptureError: Error, LocalizedError {
        case noDisplayFound
        case windowNotFound
        case windowNotVisible
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplayFound: "No display found for capture."
            case .windowNotFound: "The selected window is no longer available."
            case .windowNotVisible: "The window is minimized or hidden. Bring it to the front and try again."
            case .captureFailed(let msg): "Capture failed: \(msg)"
            }
        }
    }

    // MARK: - Available Windows (uses ScreenCaptureKit for metadata)

    func availableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter {
            $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0
                && $0.owningApplication?.processID != ownPID
        }
    }

    // MARK: - Full Screen Capture

    func captureFullScreen() throws -> NSImage {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming]
        ) else {
            throw CaptureError.captureFailed("CGWindowListCreateImage returned nil.")
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        return makeStableImage(from: cgImage, size: screen.frame.size)
    }

    // MARK: - Region Capture

    func captureRegion(_ region: CGRect) throws -> NSImage {
        guard region.width > 0, region.height > 0 else {
            throw CaptureError.captureFailed("Invalid region size.")
        }

        guard let cgImage = CGWindowListCreateImage(
            region,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming]
        ) else {
            throw CaptureError.captureFailed("CGWindowListCreateImage returned nil.")
        }

        return makeStableImage(from: cgImage, size: NSSize(width: region.width, height: region.height))
    }

    // MARK: - Window Capture

    func captureWindow(_ window: SCWindow) throws -> NSImage {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowID),
            [.boundsIgnoreFraming]
        ) else {
            throw CaptureError.captureFailed("Failed to capture window. It may have been closed.")
        }

        return makeStableImage(from: cgImage, size: NSSize(width: window.frame.width, height: window.frame.height))
    }

    // MARK: - Frozen Screen Capture

    /// Captures the full screen as a raw CGImage (for frozen overlay + crop workflow).
    func captureFullScreenCGImage() throws -> CGImage {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.boundsIgnoreFraming]
        ) else {
            throw CaptureError.captureFailed("CGWindowListCreateImage returned nil.")
        }
        return cgImage
    }

    /// Crops a region from a previously captured full-screen CGImage.
    /// Derives the scale factor from CGImage pixel dimensions vs screen point dimensions.
    func cropRegion(from screenshot: CGImage, region: CGRect, screenSize: NSSize) throws -> NSImage {
        let scale = CGFloat(screenshot.width) / screenSize.width
        let pixelRect = CGRect(
            x: region.origin.x * scale,
            y: region.origin.y * scale,
            width: region.width * scale,
            height: region.height * scale
        )
        guard let cropped = screenshot.cropping(to: pixelRect) else {
            throw CaptureError.captureFailed("Failed to crop region from frozen screenshot.")
        }
        return makeStableImage(from: cropped, size: NSSize(width: region.width, height: region.height))
    }

    // MARK: - Series Capture

    /// Captures `bounds` compositing every on-screen window except this app's own.
    ///
    /// Series frames go through this so the floating HUD and the target border
    /// never appear in a frame, without hiding and re-showing them on every
    /// snap. `bounds` is in CG display coordinates; pass `.null` for the union
    /// of all listed windows.
    func captureExcludingOwnWindows(bounds: CGRect) throws -> CGImage {
        let ids = WindowInfo.onScreenIDsExcludingCurrentProcess()
        guard !ids.isEmpty else {
            throw CaptureError.captureFailed("No capturable windows on screen.")
        }
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let cfArray = CFArrayCreate(nil, &pointers, pointers.count, nil),
              let cgImage = CGImage(
                  windowListFromArrayScreenBounds: bounds,
                  windowArray: cfArray,
                  imageOption: [.boundsIgnoreFraming]
              ) else {
            throw CaptureError.captureFailed("Window list capture returned no image.")
        }
        return cgImage
    }

    /// Captures a live window by ID, re-reading its bounds on every call.
    ///
    /// The `SCWindow` overload uses the frame captured at pick time, which goes
    /// wrong in a series: resize the window between snaps and the point size no
    /// longer matches the pixel size, so the PNG carries a wrong DPI and every
    /// annotation on that frame lands in the wrong place.
    ///
    /// A minimized window is the dangerous case. `CGWindowListCreateImage` does
    /// not reliably return nil for one, it returns a blank or 1x1 image, so the
    /// visibility and size checks here are what stop an empty frame from being
    /// appended with no error.
    func captureWindow(id windowID: CGWindowID) throws -> NSImage {
        guard let bounds = WindowInfo.bounds(for: windowID) else {
            throw CaptureError.windowNotFound
        }
        guard WindowInfo.isOnScreen(windowID) else {
            throw CaptureError.windowNotVisible
        }
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming]
        ), cgImage.width > 1, cgImage.height > 1 else {
            throw CaptureError.captureFailed("The window produced no image.")
        }
        return makeStableImage(from: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
    }

    // MARK: - Helpers

    /// Creates an NSImage from a CGImage, using NSBitmapImageRep to ensure
    /// a stable pixel data copy (avoids IOSurface-backed lifetime issues).
    func makeStableImage(from cgImage: CGImage, size: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size // Set point size so correct DPI is preserved in PNG
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

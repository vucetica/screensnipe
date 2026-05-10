import AppKit
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class ScreenCaptureService {

    enum CaptureError: Error, LocalizedError {
        case noDisplayFound
        case windowNotFound
        case captureFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplayFound: "No display found for capture."
            case .windowNotFound: "The selected window is no longer available."
            case .captureFailed(let msg): "Capture failed: \(msg)"
            }
        }
    }

    // MARK: - Available Windows (uses ScreenCaptureKit for metadata)

    func availableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter { $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 }
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

    // MARK: - Helpers

    /// Creates an NSImage from a CGImage, using NSBitmapImageRep to ensure
    /// a stable pixel data copy (avoids IOSurface-backed lifetime issues).
    private func makeStableImage(from cgImage: CGImage, size: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size // Set point size so correct DPI is preserved in PNG
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

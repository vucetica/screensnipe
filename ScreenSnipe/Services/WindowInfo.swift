import CoreGraphics
import Foundation

/// Live queries against the window server, shared by the recording border and
/// series capture. Both need to follow a window that can move, resize, or
/// disappear while a session is running.
enum WindowInfo {
    /// Current bounds in CG display coordinates, or nil if the window is gone.
    static func bounds(for windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect) else { return nil }
        return rect
    }

    static func isOnScreen(_ windowID: CGWindowID) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = infoList.first else {
            return false
        }
        // kCGWindowIsOnscreen is absent for off-screen (e.g. minimized) windows.
        return (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    /// On-screen window IDs, front to back, excluding windows owned by this
    /// process.
    ///
    /// Used so the series HUD and the target border never composite into a
    /// captured frame. Filtering by owning process handles every window this app
    /// puts on screen at once, which `.optionOnScreenBelowWindow` cannot: that
    /// option excludes exactly one window plus everything above it, which would
    /// also drop the menu bar and Dock from a full-screen grab.
    static func onScreenIDsExcludingCurrentProcess() -> [CGWindowID] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Desktop elements are deliberately kept: excluding them would drop the
        // wallpaper and desktop icons, leaving holes wherever no window covers
        // the captured area.
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        // The list is front-to-back and CGWindowListCreateImageFromArray
        // composites in array order, so the order must be preserved verbatim.
        return info.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return id
        }
    }
}

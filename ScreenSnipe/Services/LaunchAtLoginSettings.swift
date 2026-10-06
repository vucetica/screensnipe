import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp`. The system owns the real state (the user can
/// also turn the login item off in System Settings > General > Login Items),
/// so `isEnabled` is read back from the service instead of UserDefaults.
@MainActor
final class LaunchAtLoginSettings: ObservableObject {
    static let shared = LaunchAtLoginSettings()

    @Published private(set) var isEnabled: Bool = false

    private init() {
        refresh()
    }

    /// Called from the Settings toggle, so failures are shown to the user.
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            ErrorReporter.report(error, context: "Could not change launch at login")
        }
        refresh()
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

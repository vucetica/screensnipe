import SwiftUI

@main
struct ScreenSnipeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No default window — the app is menu-bar driven.
        Settings {
            PreferencesView()
        }
    }
}

import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            ShortcutsPreferencesTab()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
            LibraryPreferencesTab()
                .tabItem {
                    Label("Library", systemImage: "folder")
                }
        }
        .frame(width: 500)
    }
}

struct GeneralPreferencesTab: View {
    @ObservedObject private var captureSettings = CaptureSettings.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginSettings.shared

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Screen Snipe at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
            }
            Section("After Capture") {
                Picker("Action:", selection: $captureSettings.postCaptureBehavior) {
                    ForEach(PostCaptureBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The user can change the login item in System Settings while this
        // window is closed, so read the current state each time it appears.
        .onAppear { launchAtLogin.refresh() }
    }
}

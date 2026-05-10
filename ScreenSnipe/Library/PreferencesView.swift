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

    var body: some View {
        Form {
            Section("After Capture") {
                Picker("Action:", selection: $captureSettings.postCaptureBehavior) {
                    ForEach(PostCaptureBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

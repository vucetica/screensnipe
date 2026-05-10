import SwiftUI
import AppKit

struct LibraryPreferencesTab: View {
    @ObservedObject private var libraryManager = LibraryManager.shared

    var body: some View {
        Form {
            Section("Library") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Location:")
                        Spacer()
                        Button("Change...") {
                            chooseFolder()
                        }
                    }
                    if let url = libraryManager.libraryURL {
                        Text(url.path)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .contextMenu {
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.path, forType: .string)
                                }
                            }
                    } else {
                        Text("No location selected")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        libraryManager.promptForLibraryLocation()
    }
}

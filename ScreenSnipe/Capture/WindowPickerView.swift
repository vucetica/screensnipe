import SwiftUI
import ScreenCaptureKit

struct WindowPickerView: View {
    let windows: [SCWindow]
    let onSelect: (SCWindow) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Select a Window")
                .font(.headline)
                .padding()

            Divider()

            List(windows, id: \.windowID) { window in
                Button {
                    onSelect(window)
                } label: {
                    HStack {
                        if let appName = window.owningApplication?.applicationName {
                            Text(appName)
                                .fontWeight(.medium)
                        }
                        if let title = window.title, !title.isEmpty {
                            Text("— \(title)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(Int(window.frame.width))×\(Int(window.frame.height))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 400, height: 400)
    }
}

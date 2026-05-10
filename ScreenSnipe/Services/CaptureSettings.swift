import Foundation

enum PostCaptureBehavior: String, CaseIterable, Sendable {
    case openInEditor = "openInEditor"
    case copyToClipboard = "copyToClipboard"
    case both = "both"

    var displayName: String {
        switch self {
        case .openInEditor: "Open in Editor"
        case .copyToClipboard: "Copy to Clipboard Only"
        case .both: "Copy to Clipboard & Open in Editor"
        }
    }
}

@MainActor
final class CaptureSettings: ObservableObject {
    static let shared = CaptureSettings()

    private static let postCaptureBehaviorKey = "captureSettings.postCaptureBehavior"

    @Published var postCaptureBehavior: PostCaptureBehavior {
        didSet { UserDefaults.standard.set(postCaptureBehavior.rawValue, forKey: Self.postCaptureBehaviorKey) }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.postCaptureBehaviorKey),
           let value = PostCaptureBehavior(rawValue: raw) {
            self.postCaptureBehavior = value
        } else {
            self.postCaptureBehavior = .both
        }
    }
}

import AVFoundation

@MainActor
final class AudioSettings: ObservableObject {
    static let shared = AudioSettings()

    private static let systemAudioKey = "audioSettings.systemAudioEnabled"
    private static let micDeviceUIDKey = "audioSettings.selectedMicDeviceUID"

    @Published var systemAudioEnabled: Bool {
        didSet { UserDefaults.standard.set(systemAudioEnabled, forKey: Self.systemAudioKey) }
    }

    @Published var selectedMicDeviceUID: String? {
        didSet { UserDefaults.standard.set(selectedMicDeviceUID, forKey: Self.micDeviceUIDKey) }
    }

    var selectedMicDevice: AVCaptureDevice? {
        guard let uid = selectedMicDeviceUID else { return nil }
        return AVCaptureDevice(uniqueID: uid)
    }

    private init() {
        let defaults = UserDefaults.standard
        // Default to true if key has never been set
        if defaults.object(forKey: Self.systemAudioKey) == nil {
            self.systemAudioEnabled = true
        } else {
            self.systemAudioEnabled = defaults.bool(forKey: Self.systemAudioKey)
        }
        self.selectedMicDeviceUID = defaults.string(forKey: Self.micDeviceUIDKey)
    }

    static func availableMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

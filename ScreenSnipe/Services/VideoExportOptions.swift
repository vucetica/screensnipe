import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// How a re-encoded video export is written: codec, size, bit rate, and timing.
struct VideoEncoding: Sendable, Equatable {

    enum Codec: String, CaseIterable, Sendable {
        case h264, hevc

        var title: String {
            switch self {
            case .h264: "H.264 (most compatible)"
            case .hevc: "HEVC (smaller files)"
            }
        }
    }

    /// The box the output has to fit inside. The long edge of the video is
    /// matched against the long edge of the box, so portrait recordings are
    /// limited the same way as landscape ones. Videos are never scaled up.
    enum Resolution: String, CaseIterable, Sendable {
        case original, uhd2160, qhd1440, fhd1080, hd720, sd480

        var title: String {
            switch self {
            case .original: "Original"
            case .uhd2160: "2160p (4K)"
            case .qhd1440: "1440p"
            case .fhd1080: "1080p"
            case .hd720: "720p"
            case .sd480: "480p"
            }
        }

        var boundingBox: CGSize? {
            switch self {
            case .original: nil
            case .uhd2160: CGSize(width: 3840, height: 2160)
            case .qhd1440: CGSize(width: 2560, height: 1440)
            case .fhd1080: CGSize(width: 1920, height: 1080)
            case .hd720: CGSize(width: 1280, height: 720)
            case .sd480: CGSize(width: 854, height: 480)
            }
        }
    }

    enum Quality: String, CaseIterable, Sendable {
        case high, standard, small

        var title: String {
            switch self {
            case .high: "High (larger file)"
            case .standard: "Standard"
            case .small: "Small file"
            }
        }

        /// Average bit rate per output pixel. Standard matches what recordings
        /// are captured at, which is about 8 Mbps at 1080p.
        var bitRateFactor: Int {
            switch self {
            case .high: 8
            case .standard: 4
            case .small: 2
            }
        }
    }

    var codec: Codec
    var resolution: Resolution
    var quality: Quality
    /// Frames per second for a constant frame rate, or nil to keep the
    /// recording's own frame timing. Recordings only get a new frame when the
    /// screen changes, so their frame rate is variable.
    var frameRate: Int?

    /// The settings trims and shares have always used: HEVC at full size with
    /// the original frame timing.
    static let original = VideoEncoding(codec: .hevc, resolution: .original, quality: .standard, frameRate: nil)

    /// H.264 is what Google Drive, Meet, and Vids process fastest. Drive plays
    /// video back at 1080p at most, so a larger file only adds upload and
    /// processing time. A constant frame rate keeps Google's transcoder from
    /// stalling on long gaps where the screen did not change.
    static let googleWorkspace = VideoEncoding(codec: .h264, resolution: .fhd1080, quality: .standard, frameRate: 30)

    /// Recordings are captured at up to 30 fps, so nothing higher is offered.
    static let frameRateChoices: [Int?] = [nil, 30, 24, 15]

    static func frameRateTitle(_ rate: Int?) -> String {
        rate.map { "\($0) fps" } ?? "Original (variable)"
    }

    /// The pixel size to encode at for a source of `source` pixels.
    func outputSize(for source: CGSize) -> (width: Int, height: Int) {
        var scale = 1.0
        if let box = resolution.boundingBox {
            scale = min(scale, Self.scale(fitting: source, in: box))
        }
        // The H.264 hardware encoder tops out at 4096 × 2304, and a 5K Retina
        // recording is larger than that.
        if codec == .h264 {
            scale = min(scale, Self.scale(fitting: source, in: CGSize(width: 4096, height: 2304)))
        }
        // Encoders require even dimensions.
        let width = max(Int(source.width * scale) & ~1, 2)
        let height = max(Int(source.height * scale) & ~1, 2)
        return (width, height)
    }

    private static func scale(fitting size: CGSize, in box: CGSize) -> Double {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        guard long > 0, short > 0 else { return 1 }
        return min(box.width / long, box.height / short, 1)
    }
}

/// The presets in the video save panel.
enum VideoExportPreset: String, CaseIterable {
    case googleWorkspace, original, custom

    var title: String {
        switch self {
        case .googleWorkspace: "Google Workspace"
        case .original: "Original Quality"
        case .custom: "Custom"
        }
    }
}

/// What the video save panel decided.
struct VideoExportChoice {
    let preset: VideoExportPreset
    /// Nil for Original Quality, which keeps the existing copy and trim paths.
    let encoding: VideoEncoding?
    let mergeAudio: Bool
}

/// The controls under the video save panel: a Preset popup, the encoding
/// popups it fills in, and the audio track popup. The encoding and audio
/// popups are disabled for Google Workspace and Original Quality, so you can
/// see what those presets do, and editable for Custom. The preset and the custom
/// values are remembered for the next export.
@MainActor
final class VideoExportAccessory: NSObject {
    private static let presetKey = "videoExportPreset"
    private static let codecKey = "videoExportCodec"
    private static let resolutionKey = "videoExportResolution"
    private static let qualityKey = "videoExportQuality"
    private static let frameRateKey = "videoExportFrameRate"
    private static let audioKey = "videoExportMergeAudio"

    private weak var panel: NSSavePanel?
    private let audioTrackCount: Int
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolutionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let codecPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let frameRatePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let audioPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// The custom values, kept separately so switching to Google Workspace and
    /// back to Custom does not lose them.
    private var customEncoding: VideoEncoding

    private var preset: VideoExportPreset {
        VideoExportPreset.allCases[presetPopup.indexOfSelectedItem]
    }

    private var selectedEncoding: VideoEncoding {
        VideoEncoding(
            codec: VideoEncoding.Codec.allCases[codecPopup.indexOfSelectedItem],
            resolution: VideoEncoding.Resolution.allCases[resolutionPopup.indexOfSelectedItem],
            quality: VideoEncoding.Quality.allCases[qualityPopup.indexOfSelectedItem],
            frameRate: VideoEncoding.frameRateChoices[frameRatePopup.indexOfSelectedItem]
        )
    }

    /// - Parameter sourceSize: the recording's pixel size, shown next to the
    ///   Original resolution so you know what it means.
    init(panel: NSSavePanel, audioTrackCount: Int, sourceSize: CGSize?) {
        self.panel = panel
        self.audioTrackCount = audioTrackCount

        let defaults = UserDefaults.standard
        let savedPreset = defaults.string(forKey: Self.presetKey).flatMap(VideoExportPreset.init) ?? .googleWorkspace
        let fallback = VideoEncoding.googleWorkspace
        let savedRate = defaults.object(forKey: Self.frameRateKey) as? Int
        customEncoding = VideoEncoding(
            codec: defaults.string(forKey: Self.codecKey).flatMap(VideoEncoding.Codec.init) ?? fallback.codec,
            resolution: defaults.string(forKey: Self.resolutionKey).flatMap(VideoEncoding.Resolution.init) ?? fallback.resolution,
            quality: defaults.string(forKey: Self.qualityKey).flatMap(VideoEncoding.Quality.init) ?? fallback.quality,
            // 0 is stored for "Original (variable)", since UserDefaults cannot hold nil.
            frameRate: savedRate.map { $0 == 0 ? nil : $0 } ?? fallback.frameRate
        )

        presetPopup.addItems(withTitles: VideoExportPreset.allCases.map(\.title))
        presetPopup.selectItem(at: VideoExportPreset.allCases.firstIndex(of: savedPreset) ?? 0)

        resolutionPopup.addItems(withTitles: VideoEncoding.Resolution.allCases.map { resolution in
            guard resolution == .original, let sourceSize else { return resolution.title }
            return "Original (\(Int(sourceSize.width)) × \(Int(sourceSize.height)))"
        })
        codecPopup.addItems(withTitles: VideoEncoding.Codec.allCases.map(\.title))
        qualityPopup.addItems(withTitles: VideoEncoding.Quality.allCases.map(\.title))
        frameRatePopup.addItems(withTitles: VideoEncoding.frameRateChoices.map(VideoEncoding.frameRateTitle))

        audioPopup.addItems(withTitles: ["Merge into one track", "Independent tracks"])
        audioPopup.selectItem(at: defaults.object(forKey: Self.audioKey) as? Bool == false ? 1 : 0)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Preset:"), presetPopup],
            [NSTextField(labelWithString: "Resolution:"), resolutionPopup],
            [NSTextField(labelWithString: "Video codec:"), codecPopup],
            [NSTextField(labelWithString: "Quality:"), qualityPopup],
            [NSTextField(labelWithString: "Frame rate:"), frameRatePopup],
            [NSTextField(labelWithString: "Audio tracks:"), audioPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let stack = NSStackView(views: [grid])
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)

        // The rows never hide and each popup is as wide as its widest item, so
        // the controls always need the same space. Sizing the accessory to
        // exactly that space once leaves no spare room for them to move in.
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        panel.accessoryView = stack

        super.init()

        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        for popup in [resolutionPopup, codecPopup, qualityPopup, frameRatePopup] {
            popup.target = self
            popup.action = #selector(encodingChanged(_:))
        }

        panel.allowedContentTypes = [.mpeg4Movie]
        applyPreset()
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        applyPreset()
    }

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        if preset == .custom {
            customEncoding = selectedEncoding
        }
    }

    /// Fills in the encoding popups for the selected preset, and enables them
    /// only for Custom.
    private func applyPreset() {
        let preset = self.preset
        // Original Quality shows the settings recordings are captured with,
        // which are also what a trimmed Original Quality export uses.
        let encoding: VideoEncoding = switch preset {
        case .googleWorkspace: .googleWorkspace
        case .original: .original
        case .custom: customEncoding
        }
        select(encoding)

        let editable = preset == .custom
        for popup in [resolutionPopup, codecPopup, qualityPopup, frameRatePopup] {
            popup.isEnabled = editable
        }

        // Google Workspace always merges, since Google's players only play the
        // first audio track and would leave out the microphone. Original
        // Quality keeps the tracks as they were recorded. Only Custom lets you
        // choose, and only when there is more than one track to merge.
        switch preset {
        case .googleWorkspace:
            audioPopup.selectItem(at: 0)
        case .original:
            audioPopup.selectItem(at: 1)
        case .custom:
            let saved = UserDefaults.standard.object(forKey: Self.audioKey) as? Bool
            audioPopup.selectItem(at: saved == false ? 1 : 0)
        }
        audioPopup.isEnabled = audioTrackCount > 1 && preset == .custom
    }

    private func select(_ encoding: VideoEncoding) {
        resolutionPopup.selectItem(at: VideoEncoding.Resolution.allCases.firstIndex(of: encoding.resolution) ?? 0)
        codecPopup.selectItem(at: VideoEncoding.Codec.allCases.firstIndex(of: encoding.codec) ?? 0)
        qualityPopup.selectItem(at: VideoEncoding.Quality.allCases.firstIndex(of: encoding.quality) ?? 0)
        frameRatePopup.selectItem(at: VideoEncoding.frameRateChoices.firstIndex(of: encoding.frameRate) ?? 0)
    }

    /// Remembers the preset and custom values for next time and returns what
    /// to export.
    func commit() -> VideoExportChoice {
        let defaults = UserDefaults.standard
        let preset = self.preset
        defaults.set(preset.rawValue, forKey: Self.presetKey)
        if preset == .custom {
            let encoding = selectedEncoding
            defaults.set(encoding.codec.rawValue, forKey: Self.codecKey)
            defaults.set(encoding.resolution.rawValue, forKey: Self.resolutionKey)
            defaults.set(encoding.quality.rawValue, forKey: Self.qualityKey)
            defaults.set(encoding.frameRate ?? 0, forKey: Self.frameRateKey)
        }

        // With one audio track or none there is nothing to merge, which lets
        // Original Quality stay a plain file copy.
        let mergeAudio = audioTrackCount > 1 && audioPopup.indexOfSelectedItem == 0
        if audioPopup.isEnabled {
            defaults.set(mergeAudio, forKey: Self.audioKey)
        }

        let encoding: VideoEncoding? = switch preset {
        case .googleWorkspace: .googleWorkspace
        case .original: nil
        case .custom: selectedEncoding
        }
        return VideoExportChoice(preset: preset, encoding: encoding, mergeAudio: mergeAudio)
    }
}

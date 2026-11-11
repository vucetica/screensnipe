import CoreGraphics
import Foundation

/// One captured viewport, redrawn into a fixed 32-bit BGRA layout so rows can
/// be hashed and copied without caring how the window server laid out the
/// source image. Row 0 is the top of the viewport.
struct ScrollFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]
    let colorSpace: CGColorSpace

    static let bitmapInfo: UInt32 =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(width: Int, height: Int, pixels: [UInt32], colorSpace: CGColorSpace) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.colorSpace = colorSpace
    }

    /// Redraws `image` into the stitcher's pixel layout. The image's own RGB
    /// color space is kept, so the stitched result shows the same colors as a
    /// normal screenshot of the same area.
    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let space: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            space = own
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            space = srgb
        } else {
            return nil
        }
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: Self.bitmapInfo
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels, colorSpace: space)
    }
}

/// Builds one tall image from viewport frames captured while the user scrolls.
///
/// Every frame is compared with the last frame that was added to the image
/// (the anchor). The comparison works on row fingerprints: each pixel row is
/// split into a few vertical bands and each band gets a hash. Splitting into
/// bands means a small change in one place, such as a scroll bar knob or a
/// spinner, only spoils one band of a row instead of the whole row.
///
/// For each new frame the stitcher:
/// 1. Finds the rows at the top and bottom that did not move (a sticky header
///    or footer, or a browser toolbar in a window capture).
/// 2. Drops bands that stayed in place inside the moving area (a sidebar next
///    to the scrolling content).
/// 3. Lets matching band hashes vote on how far the content moved, then checks
///    the best few distances row by row and keeps the one that fits best.
/// 4. Appends only the rows that scrolled into view.
///
/// The output is kept as a content stream that always ends at the anchor's
/// last moving row. The footer is added once, from the last anchor, when the
/// image is built.
struct ScrollStitcher {

    enum Outcome: Equatable, Sendable {
        /// The first frame was stored.
        case started
        /// Nothing scrolled since the last frame.
        case unchanged
        /// New rows were added. `height` is the current image height in pixels.
        case appended(height: Int)
        /// The frame could not be lined up with the image. Usually the user
        /// scrolled up, or scrolled so fast that two frames share no rows.
        case noMatch
        /// The frame has a different size from the first frame.
        case sizeChanged
        /// The image reached `maxHeight` and stopped growing.
        case limitReached
    }

    /// Image height limit in pixels.
    let maxHeight: Int

    /// Height of the image `makeImage()` would return right now, in pixels.
    private(set) var pixelHeight = 0

    private var width = 0
    private var height = 0
    private var bandCount = 1
    private var colorSpace: CGColorSpace?

    private var anchor: ScrollFrame?
    private var anchorSignature: RowSignature?
    private var lastSeenHashes: [UInt64] = []

    /// Rows at the bottom of every frame treated as a sticky footer. Only grows.
    private var fixedBottom = 0
    /// Content stream: anchor-aligned rows, ending at anchor row `height - fixedBottom - 1`.
    private var body: [UInt32] = []
    private var bodyRows = 0
    private var hasScrolled = false
    private var isFull = false
    private var lastShift = 0

    // Matching thresholds. A band-row is one band of one pixel row.
    private static let sameRowBandFraction = 0.75
    private static let staticBandFraction = 0.9
    private static let acceptRatio = 0.85
    private static let minComparedBandRows = 16
    private static let maxRowsPerHash = 8
    private static let candidateCount = 6

    init(maxHeight: Int = 30_000) {
        self.maxHeight = maxHeight
    }

    // MARK: - Adding frames

    mutating func add(_ frame: ScrollFrame) -> Outcome {
        guard let anchor, let anchorSignature else {
            width = frame.width
            height = frame.height
            colorSpace = frame.colorSpace
            bandCount = max(1, min(8, frame.width / 48))
            let signature = RowSignature(frame: frame, bandCount: bandCount)
            self.anchor = frame
            self.anchorSignature = signature
            lastSeenHashes = signature.hashes
            pixelHeight = frame.height
            return .started
        }
        guard frame.width == width, frame.height == height else { return .sizeChanged }
        guard !isFull else { return .limitReached }

        let signature = RowSignature(frame: frame, bandCount: bandCount)
        // Most frames arrive while nothing moves. Skip them before any matching.
        if signature.hashes == lastSeenHashes { return .unchanged }
        lastSeenHashes = signature.hashes

        switch match(old: anchorSignature, new: signature) {
        case .stationary:
            return .unchanged
        case .none:
            return .noMatch
        case .shifted(let shift, let top, let bottom):
            append(frame, signature: signature, anchor: anchor, shift: shift, top: top, bottom: bottom)
            return isFull ? .limitReached : .appended(height: pixelHeight)
        }
    }

    private mutating func append(
        _ frame: ScrollFrame,
        signature: RowSignature,
        anchor: ScrollFrame,
        shift: Int,
        top: Int,
        bottom: Int
    ) {
        if !hasScrolled {
            hasScrolled = true
            fixedBottom = bottom
            bodyRows = height - fixedBottom
            body = Array(anchor.pixels[0..<(bodyRows * width)])
        } else if bottom > fixedBottom {
            // A footer appeared (or blank rows happened to line up). Rewind the
            // stream so it ends above the larger footer again. The rows taken
            // off come back later as they scroll up out of the footer area.
            let rewind = min(bottom - fixedBottom, bodyRows)
            body.removeLast(rewind * width)
            bodyRows -= rewind
            fixedBottom = bottom
        }

        // The stream ends at anchor row (height - fixedBottom - 1), which is
        // frame row (height - fixedBottom - 1 - shift). Everything below that
        // and above the footer is new.
        let end = height - fixedBottom
        let start = max(top, end - shift)
        var newRows = max(0, end - start)
        let room = maxHeight - fixedBottom - bodyRows
        if newRows >= room {
            newRows = max(0, room)
            isFull = true
        }
        if newRows > 0 {
            body.append(contentsOf: frame.pixels[(start * width)..<((start + newRows) * width)])
            bodyRows += newRows
        }

        self.anchor = frame
        self.anchorSignature = signature
        lastShift = shift
        pixelHeight = bodyRows + fixedBottom
    }

    // MARK: - Building the image

    func makeImage() -> CGImage? {
        guard let anchor, let colorSpace else { return nil }
        var pixels: [UInt32]
        let rows: Int
        if hasScrolled {
            pixels = body
            pixels.append(contentsOf: anchor.pixels[((height - fixedBottom) * width)...])
            rows = bodyRows + fixedBottom
        } else {
            pixels = anchor.pixels
            rows = height
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: rows,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: ScrollFrame.bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Matching

    private enum Match {
        case stationary
        case none
        /// Content moved up by `shift` rows. `top` and `bottom` are the rows
        /// that stayed in place at each edge.
        case shifted(Int, top: Int, bottom: Int)
    }

    private func match(old: RowSignature, new: RowSignature) -> Match {
        let bands = bandCount
        let h = height

        // A row stayed in place when most of its bands that have content are
        // unchanged. Plain single-color bands are left out of the count:
        // white margins look the same after any scroll, and counting them
        // would make a moving text row next to a still sidebar look sticky.
        func sameRow(_ row: Int) -> Bool {
            var informative = 0
            var equal = 0
            for band in 0..<bands {
                let i = row * bands + band
                let same = old.hashes[i] == new.hashes[i]
                if same, old.uniform[i] { continue }
                informative += 1
                if same { equal += 1 }
            }
            return Double(equal) >= Double(informative) * Self.sameRowBandFraction
        }

        var top = 0
        while top < h, sameRow(top) { top += 1 }
        if top == h { return .stationary }
        var bottom = 0
        while bottom < h - top, sameRow(h - 1 - bottom) { bottom += 1 }

        let movingEnd = h - bottom
        let moving = movingEnd - top
        let minOverlap = max(8, moving / 20)
        guard moving > minOverlap else { return .none }

        // Bands that did not move inside the moving area are a sidebar or
        // other still column. They say nothing about the scroll distance.
        var usable = [Bool](repeating: true, count: bands)
        for band in 0..<bands {
            var informative = 0
            var equal = 0
            for row in top..<movingEnd {
                let i = row * bands + band
                let same = old.hashes[i] == new.hashes[i]
                if same, old.uniform[i] { continue }
                informative += 1
                if same { equal += 1 }
            }
            if informative == 0 || Double(equal) >= Double(informative) * Self.staticBandFraction {
                usable[band] = false
            }
        }
        guard usable.contains(true) else { return .stationary }

        // Vote: every band-row in the new frame that has a matching hash in
        // the old frame suggests a distance. Plain single-color band-rows
        // match everywhere, and hashes that repeat many times (a striped
        // list) match too many places, so both are left out.
        var index: [UInt64: [Int]] = [:]
        for row in top..<movingEnd {
            for band in 0..<bands where usable[band] {
                let i = row * bands + band
                if old.uniform[i] { continue }
                index[Self.key(old.hashes[i], band), default: []].append(row)
            }
        }
        let maxShift = moving - minOverlap
        var votes = [Int](repeating: 0, count: maxShift + 1)
        for row in top..<movingEnd {
            for band in 0..<bands where usable[band] {
                let i = row * bands + band
                if new.uniform[i] { continue }
                guard let oldRows = index[Self.key(new.hashes[i], band)],
                      oldRows.count <= Self.maxRowsPerHash else { continue }
                for oldRow in oldRows {
                    let shift = oldRow - row
                    if shift >= 1, shift <= maxShift { votes[shift] += 1 }
                }
            }
        }

        let candidates = votes.indices
            .filter { votes[$0] > 0 }
            .sorted { votes[$0] > votes[$1] }
            .prefix(Self.candidateCount)

        // Check each candidate row by row. Bands are scored on their own: a
        // band that straddles the edge of a still sidebar mixes still and
        // moving pixels, so it never matches at any distance. Such bands are
        // set aside, as long as the bands that do agree carry at least a
        // third of the compared band-rows.
        var best: (shift: Int, ratio: Double)?
        for shift in candidates {
            var compared = [Int](repeating: 0, count: bands)
            var matched = [Int](repeating: 0, count: bands)
            for row in top..<(movingEnd - shift) {
                let oldRow = row + shift
                for band in 0..<bands where usable[band] {
                    let n = row * bands + band
                    let o = oldRow * bands + band
                    let same = new.hashes[n] == old.hashes[o]
                    if same, new.uniform[n] { continue }
                    compared[band] += 1
                    if same { matched[band] += 1 }
                }
            }
            var allCompared = 0
            var agreeCompared = 0
            var agreeMatched = 0
            for band in 0..<bands where compared[band] > 0 {
                allCompared += compared[band]
                if Double(matched[band]) >= Double(compared[band]) * Self.acceptRatio {
                    agreeCompared += compared[band]
                    agreeMatched += matched[band]
                }
            }
            guard agreeCompared >= Self.minComparedBandRows,
                  agreeCompared * 3 >= allCompared else { continue }
            // Ranked by how much of the frame agrees, so a distance that only
            // fits one narrow band loses to one that fits most of the width.
            let ratio = Double(agreeMatched) / Double(allCompared)
            if let current = best {
                if ratio > current.ratio + 0.02 {
                    best = (shift, ratio)
                } else if ratio >= current.ratio - 0.02,
                          abs(shift - lastShift) < abs(current.shift - lastShift) {
                    // Near tie, as with repeating content: prefer the distance
                    // closest to the previous one, since scrolling speed
                    // changes gradually between frames.
                    best = (shift, ratio)
                }
            } else {
                best = (shift, ratio)
            }
        }

        guard let best else { return .none }
        return .shifted(best.shift, top: top, bottom: bottom)
    }

    private static func key(_ hash: UInt64, _ band: Int) -> UInt64 {
        hash &+ UInt64(band) &* 0x9E37_79B9_7F4A_7C15
    }
}

/// Per-row, per-band fingerprints of one frame.
private struct RowSignature {
    let bandCount: Int
    /// Row-major: `row * bandCount + band`.
    let hashes: [UInt64]
    /// True when every pixel in that band-row has the same color.
    let uniform: [Bool]

    init(frame: ScrollFrame, bandCount: Int) {
        self.bandCount = bandCount
        let width = frame.width
        let count = frame.height * bandCount
        let edges = (0...bandCount).map { $0 * width / bandCount }
        var hashes = [UInt64](repeating: 0, count: count)
        var uniform = [Bool](repeating: false, count: count)

        frame.pixels.withUnsafeBufferPointer { pixels in
            hashes.withUnsafeMutableBufferPointer { hashOut in
                uniform.withUnsafeMutableBufferPointer { uniformOut in
                    for row in 0..<frame.height {
                        let rowStart = row * width
                        for band in 0..<bandCount {
                            var i = rowStart + edges[band]
                            let end = rowStart + edges[band + 1]
                            let first = pixels[i]
                            var differs: UInt32 = 0
                            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
                            while i < end {
                                let value = pixels[i]
                                hash = (hash ^ UInt64(value)) &* 0x0000_0100_0000_01B3
                                differs |= value ^ first
                                i += 1
                            }
                            hashOut[row * bandCount + band] = hash
                            uniformOut[row * bandCount + band] = differs == 0
                        }
                    }
                }
            }
        }
        self.hashes = hashes
        self.uniform = uniform
    }
}

/// Runs the stitcher off the main actor. Frames go in one at a time, so the
/// capture loop waits for each one to finish before grabbing the next.
actor ScrollStitchEngine {
    private var stitcher: ScrollStitcher

    init(maxHeight: Int = 30_000) {
        stitcher = ScrollStitcher(maxHeight: maxHeight)
    }

    func add(_ image: SendableCGImage) -> ScrollStitcher.Outcome {
        guard let frame = ScrollFrame(image: image.image) else { return .noMatch }
        return stitcher.add(frame)
    }

    func makeImage() -> SendableCGImage? {
        stitcher.makeImage().map(SendableCGImage.init)
    }
}

/// Hands a CGImage across actor boundaries. CGImage is immutable.
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

import Testing
import CoreGraphics
import Foundation
@testable import ScreenSnipe

/// Scrolls a synthetic page through a viewport and checks that the stitched
/// image equals the page itself, pixel for pixel.
@Suite("Scroll Stitcher Tests")
struct ScrollStitcherTests {

    private static let width = 480
    private static let white: UInt32 = 0xFFFF_FFFF
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Deterministic generator so failures reproduce.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// White page with lines of noisy "text" separated by blank gaps.
    private static func makePage(height: Int, using g: inout SeededGenerator) -> [UInt32] {
        var page = [UInt32](repeating: white, count: width * height)
        var y = 0
        while y < height {
            let lineHeight = Int.random(in: 10...16, using: &g)
            let x0 = Int.random(in: 10...40, using: &g)
            let x1 = Int.random(in: 200...470, using: &g)
            for row in y..<min(height, y + lineHeight) {
                for x in x0..<x1 where UInt8.random(in: 0...3, using: &g) == 0 {
                    page[row * width + x] = 0xFF00_0000 | UInt32.random(in: 0...0xFF_FFFF, using: &g)
                }
            }
            y += lineHeight + Int.random(in: 4...24, using: &g)
        }
        return page
    }

    private static func makeBand(rows: Int, using g: inout SeededGenerator) -> [UInt32] {
        (0..<(width * rows)).map { _ in 0xFF00_0000 | UInt32.random(in: 0...0xFF_FFFF, using: &g) }
    }

    private static func pixels(of image: CGImage) -> [UInt32] {
        let data = image.dataProvider!.data! as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }

    /// Scrolls through `offsets`, returning the stitched pixels, the expected
    /// pixels, and the outcome for each offset.
    private static func scroll(
        offsets: [Int],
        header: Int,
        footer: Int,
        sidebar: Int = 0,
        viewHeight: Int = 420
    ) -> (got: CGImage, expected: [UInt32], outcomes: [ScrollStitcher.Outcome]) {
        var g = SeededGenerator(state: 42)
        let contentHeight = viewHeight - header - footer
        let page = makePage(height: 6000, using: &g)
        let head = makeBand(rows: header, using: &g)
        let foot = makeBand(rows: footer, using: &g)
        let side = makeBand(rows: viewHeight, using: &g)

        var stitcher = ScrollStitcher()
        var outcomes: [ScrollStitcher.Outcome] = []
        var lastAccepted = 0
        for offset in offsets {
            var frame = head
            frame += page[(offset * width)..<((offset + contentHeight) * width)]
            frame += foot
            for row in 0..<viewHeight {
                for x in 0..<sidebar { frame[row * width + x] = side[row * width + x] }
            }
            let outcome = stitcher.add(ScrollFrame(width: width, height: viewHeight, pixels: frame, colorSpace: space))
            switch outcome {
            case .started, .appended: lastAccepted = offset
            default: break
            }
            outcomes.append(outcome)
        }

        var expected = head
        expected += page[0..<((lastAccepted + contentHeight) * width)]
        expected += foot
        return (stitcher.makeImage()!, expected, outcomes)
    }

    /// Uneven steps, a pause, a small scroll up, a jump too far to match,
    /// then a recovery and a long run down the page.
    private static let realisticOffsets: [Int] = {
        var g = SeededGenerator(state: 7)
        var offsets = [0, 0, 3, 10, 40, 40, 100, 180, 179, 600, 400]
        var offset = 400
        while offset < 5500 {
            offset = min(5500, offset + Int.random(in: 5...150, using: &g))
            offsets.append(offset)
        }
        return offsets
    }()

    @Test func stitchesPlainPage() {
        let result = Self.scroll(offsets: Self.realisticOffsets, header: 0, footer: 0)
        #expect(result.got.height * Self.width == result.expected.count)
        #expect(Self.pixels(of: result.got) == result.expected)
    }

    @Test func keepsStickyHeaderAndFooterOnce() {
        let result = Self.scroll(offsets: Self.realisticOffsets, header: 50, footer: 30)
        #expect(Self.pixels(of: result.got) == result.expected)
    }

    @Test func reportsScrollUpAndTooFastJumpAsNoMatch() {
        let result = Self.scroll(offsets: Self.realisticOffsets, header: 50, footer: 30)
        // Offset 179 (scrolled up) and 600 (no overlap with 180).
        #expect(result.outcomes[8] == .noMatch)
        #expect(result.outcomes[9] == .noMatch)
        // 400 overlaps 180 again, so the capture picks up from there.
        if case .appended = result.outcomes[10] {} else {
            Issue.record("Expected the capture to recover at offset 400, got \(result.outcomes[10])")
        }
    }

    @Test func ignoresStillSidebar() {
        let sidebar = 70
        let result = Self.scroll(offsets: Self.realisticOffsets, header: 50, footer: 30, sidebar: sidebar)
        let got = Self.pixels(of: result.got)
        #expect(got.count == result.expected.count)
        guard got.count == result.expected.count else { return }
        // The sidebar column itself is a strip of slices by nature; the
        // scrolling content next to it must be exact.
        var mismatches = 0
        for row in 0..<result.got.height {
            for x in sidebar..<Self.width where got[row * Self.width + x] != result.expected[row * Self.width + x] {
                mismatches += 1
            }
        }
        #expect(mismatches == 0)
    }

    @Test func handlesTinySteps() {
        let offsets = Array(stride(from: 0, through: 900, by: 2))
        let result = Self.scroll(offsets: offsets, header: 50, footer: 30)
        #expect(Self.pixels(of: result.got) == result.expected)
    }

    @Test func singleFrameIsReturnedAsIs() {
        let result = Self.scroll(offsets: [0, 0], header: 50, footer: 30)
        #expect(result.got.height == 420)
        #expect(result.outcomes == [.started, .unchanged])
    }

    @Test func stopsAtHeightLimit() {
        var g = SeededGenerator(state: 99)
        let page = Self.makePage(height: 4000, using: &g)
        var stitcher = ScrollStitcher(maxHeight: 1000)
        var sawLimit = false
        for offset in stride(from: 0, through: 3000, by: 100) {
            let frame = Array(page[(offset * Self.width)..<((offset + 400) * Self.width)])
            if stitcher.add(ScrollFrame(width: Self.width, height: 400, pixels: frame, colorSpace: Self.space)) == .limitReached {
                sawLimit = true
            }
        }
        #expect(sawLimit)
        #expect(stitcher.makeImage()?.height == 1000)
    }

    @Test func rejectsFrameOfDifferentSize() {
        var stitcher = ScrollStitcher()
        let first = [UInt32](repeating: Self.white, count: Self.width * 100)
        let second = [UInt32](repeating: Self.white, count: Self.width * 120)
        _ = stitcher.add(ScrollFrame(width: Self.width, height: 100, pixels: first, colorSpace: Self.space))
        #expect(stitcher.add(ScrollFrame(width: Self.width, height: 120, pixels: second, colorSpace: Self.space)) == .sizeChanged)
    }
}

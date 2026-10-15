import XCTest
@testable import Strata

final class ClipRemapTests: XCTestCase {
    private var sample: Sample!
    private var project: Project!

    override func setUp() {
        // Each frame's value is its original index, so we can tell which audio a clip plays.
        let buf = SampleBuffer(frameCount: 300_000)
        for i in 0..<300_000 { buf.left[i] = Float(i); buf.right[i] = Float(i) }
        sample = Sample(name: "s", buffer: buf)
        project = Project()
        project.samples = [sample]
        project.tracks = [Track(name: "t", colorIndex: 0, clips: [
            Clip(sampleID: sample.id, name: "c", start: 10, sourceStart: 100_000, sourceLength: 50_000)
        ])]
    }

    func testDeleteBeforeClipKeepsSameAudio() {
        var p = project!
        p.samples[0].buffer = sample.buffer.deleting(range: 0..<50_000)
        p.remapClips(forSample: sample.id, removed: [0..<50_000])
        let c = p.tracks[0].clips[0]
        XCTAssertEqual(c.sourceStart, 50_000)
        XCTAssertEqual(c.sourceLength, 50_000)
        XCTAssertEqual(c.start, 10)
        XCTAssertEqual(p.samples[0].buffer.left[c.sourceStart], 100_000)
    }

    func testDeleteOverlappingHeadShiftsTimelineStart() {
        var p = project!
        p.remapClips(forSample: sample.id, removed: [90_000..<120_000])
        let c = p.tracks[0].clips[0]
        XCTAssertEqual(c.sourceStart, 90_000)
        XCTAssertEqual(c.sourceLength, 30_000)
        XCTAssertEqual(c.start, 10 + 20_000 / AudioSpec.sampleRate, accuracy: 1e-9)
    }

    func testTrimKeepsSurvivingPart() {
        var p = project!
        p.remapClips(forSample: sample.id, removed: [0..<120_000, 200_000..<300_000])
        let c = p.tracks[0].clips[0]
        XCTAssertEqual(c.sourceStart, 0)
        XCTAssertEqual(c.sourceLength, 30_000)
    }

    func testFullyDeletedClipIsRemoved() {
        var p = project!
        p.remapClips(forSample: sample.id, removed: [80_000..<200_000])
        XCTAssertTrue(p.tracks[0].clips.isEmpty)
    }
}

final class SplitTests: XCTestCase {
    func testMultiSplitProducesContiguousPieces() {
        let clip = Clip(sampleID: UUID(), name: "c", start: 0, sourceStart: 0, sourceLength: 96_000)
        let pieces = Studio.splitClip(clip, at: [1.5, 0.5, 1.0])
        XCTAssertEqual(pieces.count, 4)
        XCTAssertEqual(pieces.map(\.sourceLength).reduce(0, +), 96_000)
        XCTAssertEqual(pieces[1].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(Set(pieces.map(\.id)).count, 4)
    }

    func testSplitTooCloseToEdgeIsRejected() {
        let clip = Clip(sampleID: UUID(), name: "c", start: 0, sourceStart: 0, sourceLength: 48_000)
        XCTAssertNil(Studio.splitClip(clip, at: 0.001))
    }
}

final class StretchTests: XCTestCase {
    func testWSOLALengthsAndBoundsAtExtremeRatios() {
        let src = DemoSession.drumBreak(bpm: 124, bars: 2)
        for ratio in [1.0 / 16, 0.25, 0.3, 1.5, 8.0] {
            let out = WSOLAStretcher.render(buffer: src, range: 0..<src.frameCount, stretch: ratio)
            XCTAssertEqual(out?.frameCount, Int((Double(src.frameCount) * ratio).rounded()), "ratio \(ratio)")
        }
    }

    func testWSOLAKeepsTransientsOnGrid() throws {
        // Clicks every 0.5 s; stretched ×2 they must land every 1.0 s (±6 ms).
        let n = 48_000 * 2
        let b = SampleBuffer(frameCount: n)
        for k in 0..<4 { for i in 0..<200 { let v = Float(sin(Double(i) * 0.3)) * Float(1 - Double(i) / 200); b.left[k * 24_000 + i] = v; b.right[k * 24_000 + i] = v } }
        let out = try XCTUnwrap(WSOLAStretcher.render(buffer: b, range: 0..<n, stretch: 2))
        for k in 1..<4 {
            let c = k * 48_000
            var best = c, bestV: Float = 0
            for i in (c - 16_000)..<(c + 16_000) where abs(out.left[i]) > bestV { bestV = abs(out.left[i]); best = i }
            XCTAssertLessThan(abs(best - c), 300, "click \(k) off by \(best - c) frames")
        }
    }
}

final class TransientTests: XCTestCase {
    func testDetectsSnaresAccurately() {
        let buf = DemoSession.drumBreak(bpm: 124, bars: 2)
        let onsets = TransientDetector.detect(in: buf, sensitivity: 0.55).map { Double($0) / AudioSpec.sampleRate }
        let step = 60.0 / 124 / 4
        for s in [4, 12] {
            let expected = Double(s) * step
            XCTAssertTrue(onsets.contains { abs($0 - expected) < 0.008 }, "missing hit at \(expected)")
        }
    }
}

final class RendererTests: XCTestCase {
    func testSoftClipIsTransparentBelowThresholdAndBounded() {
        XCTAssertEqual(ArrangementRenderer.softClip(0.5), 0.5)
        XCTAssertLessThanOrEqual(ArrangementRenderer.softClip(4), 1.0)
        XCTAssertGreaterThanOrEqual(ArrangementRenderer.softClip(-4), -1.0)
        XCTAssertLessThan(ArrangementRenderer.softClip(1.0), 1.0)
    }

    func testBounceRendersClipAtItsPosition() {
        let buf = SampleBuffer(frameCount: 4800)
        for i in 0..<4800 { buf.left[i] = 0.5; buf.right[i] = 0.5 }
        let s = Sample(name: "s", buffer: buf)
        var p = Project()
        p.masterVolume = 1
        p.samples = [s]
        p.tracks = [Track(name: "t", colorIndex: 0, volume: 1, clips: [Clip(sampleID: s.id, name: "c", start: 0.5, sourceStart: 0, sourceLength: 4800)])]
        let out = PlaybackEngine.bounce(graph: RenderGraph(project: p, stretchCache: { _ in nil }), from: 0, to: 1)
        XCTAssertEqual(out.left[1000], 0)                       // before the clip
        XCTAssertEqual(out.left[24_000 + 2400], 0.5, accuracy: 1e-4)  // middle of the clip
    }
}

final class AudioFileTests: XCTestCase {
    func testEncodeDecodeIsLosslessIncludingOvers() throws {
        let b = SampleBuffer(frameCount: 1000)
        for i in 0..<1000 { b.left[i] = Float(i) / 300 - 1.2; b.right[i] = -b.left[i] }   // peaks above ±1
        let data = try AudioFileIO.encode(b)
        let back = try AudioFileIO.decode(data, id: b.id)
        XCTAssertEqual(back.frameCount, 1000)
        for i in stride(from: 0, to: 1000, by: 37) {
            XCTAssertEqual(back.left[i], b.left[i])
            XCTAssertEqual(back.right[i], b.right[i])
        }
    }
}

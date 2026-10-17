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

    /// Inserts `count` frames of -1 at `at` and remaps, as Paste / Insert Silence do.
    private func inserting(_ count: Int, at: Int) -> Project {
        var p = project!
        let filler = SampleBuffer(frameCount: count)
        for i in 0..<count { filler.left[i] = -1; filler.right[i] = -1 }
        p.samples[0].buffer = sample.buffer.inserting(filler, at: at)
        p.remapClips(forSample: sample.id, inserted: count, at: at)
        return p
    }

    func testInsertBeforeClipShiftsSourceNotTimeline() {
        let p = inserting(20_000, at: 50_000)
        let c = p.tracks[0].clips[0]
        XCTAssertEqual(c.sourceStart, 120_000)
        XCTAssertEqual(c.sourceLength, 50_000)
        XCTAssertEqual(c.start, 10)
        XCTAssertEqual(p.samples[0].buffer.left[c.sourceStart + 1000], 101_000)
    }

    func testInsertAfterClipLeavesItAlone() {
        let p = inserting(20_000, at: 150_000)
        XCTAssertEqual(p.tracks[0].clips.map(\.sourceStart), [100_000])
        XCTAssertEqual(p.tracks[0].clips[0].sourceLength, 50_000)
    }

    func testInsertInsideClipSplitsAroundNewAudio() {
        var base = project!
        base.updateClip(base.tracks[0].clips[0].id) { $0.fadeIn = 0.05; $0.fadeOut = 0.1; $0.stretch = 2 }
        project = base
        let p = inserting(10_000, at: 124_000)
        let clips = p.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        let (head, tail) = (clips[0], clips[1])
        XCTAssertEqual(head.sourceStart, 100_000)
        XCTAssertEqual(head.sourceLength, 24_000)
        XCTAssertEqual(tail.sourceStart, 134_000)
        XCTAssertEqual(tail.sourceLength, 26_000)
        // The tail keeps its timeline position (24 000 source frames × stretch 2 later).
        XCTAssertEqual(tail.start, 10 + 48_000 / AudioSpec.sampleRate, accuracy: 1e-9)
        XCTAssertEqual(head.end, tail.start, accuracy: 1e-9)
        // Both halves play the original audio, not the inserted frames (away from the de-click seams).
        let buf = p.samples[0].buffer
        XCTAssertEqual(buf.left[head.sourceStart + 10_000], 110_000)
        XCTAssertEqual(buf.left[tail.sourceStart + 10_000], 134_000)
        // Outer fades survive; the split edges get none.
        XCTAssertEqual(head.fadeIn, 0.05)
        XCTAssertEqual(head.fadeOut, 0)
        XCTAssertEqual(tail.fadeIn, 0)
        XCTAssertEqual(tail.fadeOut, 0.1)
        XCTAssertNotEqual(head.id, tail.id)
    }

    func testInsertAtVeryStartOfClipDoesNotLeaveSliver() {
        let p = inserting(5_000, at: 100_008)
        XCTAssertEqual(p.tracks[0].clips.count, 1)
        XCTAssertEqual(p.tracks[0].clips[0].sourceStart, 105_008)
    }

    func testReplaceThenRemapMatchesPaste() {
        // Paste over 110 000..<120 000 with 4 000 frames: remove, then insert at the same point.
        var p = project!
        let filler = SampleBuffer(frameCount: 4_000)
        p.samples[0].buffer = sample.buffer.replacing(range: 110_000..<120_000, with: filler)
        p.remapClips(forSample: sample.id, removed: [110_000..<120_000])
        p.remapClips(forSample: sample.id, inserted: 4_000, at: 110_000)
        let clips = p.tracks[0].clips
        XCTAssertEqual(clips.map(\.sourceLength), [10_000, 30_000])
        XCTAssertEqual(p.samples[0].buffer.frameCount, 294_000)
        XCTAssertEqual(p.samples[0].buffer.left[clips[1].sourceStart + 5_000], 125_000)
    }
}

final class SpliceTests: XCTestCase {
    private func ramp(_ n: Int) -> SampleBuffer {
        let b = SampleBuffer(frameCount: n)
        for i in 0..<n { b.left[i] = Float(i); b.right[i] = Float(-i) }
        return b
    }

    func testReplacingSplicesBothSides() {
        let other = SampleBuffer(frameCount: 500)
        let out = ramp(10_000).replacing(range: 2_000..<3_000, with: other)
        XCTAssertEqual(out.frameCount, 9_500)
        XCTAssertEqual(out.left[1_000], 1_000)
        XCTAssertEqual(out.left[2_250], 0)
        XCTAssertEqual(out.left[5_000], 5_500)
        XCTAssertEqual(out.right[5_000], -5_500)
    }

    func testInsertingAtEndAppends() {
        let out = ramp(1_000).inserting(ramp(300), at: 5_000)
        XCTAssertEqual(out.frameCount, 1_300)
        XCTAssertEqual(out.left[1_200], 200, accuracy: 1e-3)
    }

    func testDirectionalZeroCrossings() {
        // Sign flips every 100 frames: crossings at 100, 200, 300 …
        let b = SampleBuffer(frameCount: 1_000)
        for i in 0..<1_000 { let v: Float = (i / 100) % 2 == 0 ? 0.5 : -0.5; b.left[i] = v; b.right[i] = v }
        XCTAssertEqual(b.zeroCrossing(from: 250, forward: true), 300)
        XCTAssertEqual(b.zeroCrossing(from: 300, forward: true), 400)
        XCTAssertEqual(b.zeroCrossing(from: 250, forward: false), 200)
        XCTAssertEqual(b.zeroCrossing(from: 200, forward: false), 100)
        XCTAssertNil(b.zeroCrossing(from: 50, forward: false))
        XCTAssertNil(b.zeroCrossing(from: 950, forward: true))
        XCTAssertNil(SampleBuffer(frameCount: 1_000).zeroCrossing(from: 500, forward: true), "silence has no crossings")
    }
}

final class EditorNavigationTests: XCTestCase {
    func testMarkStepsStrictlyPastFrame() {
        let marks = [0, 100, 200, 300]
        XCTAssertEqual(Studio.mark(after: 100, direction: 1, in: marks), 200)
        XCTAssertEqual(Studio.mark(after: 150, direction: -1, in: marks), 100)
        XCTAssertEqual(Studio.mark(after: 100, direction: -1, in: marks), 0)
        XCTAssertNil(Studio.mark(after: 300, direction: 1, in: marks))
        XCTAssertNil(Studio.mark(after: 0, direction: -1, in: marks))
    }

    func testExtendMovesActiveEdgeAndCanCrossAnchor() {
        // Cursor at 100 grows left, anchored at 100.
        var (sel, anchor) = Studio.extend(100..<100, activeIsStart: false, to: 40)
        XCTAssertEqual(sel, 40..<100)
        XCTAssertEqual(anchor, 100)
        // The start is now active; moving it past the anchor flips the range around it.
        (sel, anchor) = Studio.extend(sel, activeIsStart: true, to: 160)
        XCTAssertEqual(sel, 100..<160)
        XCTAssertEqual(anchor, 100)
    }

    func testActiveEdgeFollowsAnchor() {
        let ed = EditorState()
        ed.selection = 10..<50
        XCTAssertFalse(ed.activeEdgeIsStart, "end by default")
        ed.anchor = 50
        XCTAssertTrue(ed.activeEdgeIsStart)
        ed.anchor = 10
        XCTAssertFalse(ed.activeEdgeIsStart)
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

final class TempoTests: XCTestCase {
    func testDetectsDemoLoopTempoAndBarCount() throws {
        // 124: the kick repeats every 1.5 beats, which a single-lag estimate reads as 82.7.
        for (bpm, bars) in [(124.0, 2), (97.0, 2), (140.0, 4), (86.0, 1), (150.0, 2)] {
            let buf = DemoSession.drumBreak(bpm: bpm, bars: bars)
            let est = try XCTUnwrap(TransientDetector.estimateTempo(buffer: buf), "bpm \(bpm)")
            XCTAssertEqual(est.bpm, bpm, accuracy: 0.05, "\(est) for \(bpm)")
            XCTAssertEqual(est.bars, bars, "\(est) for \(bpm)")
        }
        let groove = DemoSession.bassLine(bpm: 110, bars: 2)
        let est = try XCTUnwrap(TransientDetector.estimateTempo(buffer: groove))
        XCTAssertEqual(est.bpm, 110, accuracy: 0.05)
        XCTAssertEqual(est.bars, 2)
    }

    func testFastLoopsMayResolveToHalfTime() throws {
        // 4 bars at 172 is also 2 bars at 86; either reading is musically valid (the UI
        // offers ½× / 2×), but the tempo and bar count must agree.
        let buf = DemoSession.drumBreak(bpm: 172, bars: 4)
        let est = try XCTUnwrap(TransientDetector.estimateTempo(buffer: buf))
        let octave = log2(est.bpm / 172)
        XCTAssertEqual(octave, octave.rounded(), accuracy: 0.001)
        XCTAssertEqual(Double(est.bars ?? 0), 4 * pow(2, octave.rounded()), accuracy: 1e-9)
    }

    func testRaggedRegionGetsFreeEstimateWithoutBars() throws {
        let buf = DemoSession.drumBreak(bpm: 124, bars: 2)
        let est = try XCTUnwrap(TransientDetector.estimateTempo(buffer: buf, range: 0..<Int(Double(buf.frameCount) * 0.83)))
        XCTAssertNil(est.bars)
        XCTAssertEqual(est.bpm, 124, accuracy: 1.5)
    }

    func testHalvingAndDoublingKeepsBarsConsistent() {
        let est = TempoEstimate(bpm: 86, bars: 2)
        XCTAssertEqual(est.scaled(by: 2), TempoEstimate(bpm: 172, bars: 4))
        XCTAssertEqual(est.scaled(by: 0.5), TempoEstimate(bpm: 43, bars: 1))
        XCTAssertEqual(TempoEstimate(bpm: 120, bars: 1).scaled(by: 0.5), TempoEstimate(bpm: 60, bars: nil))
    }

    func testResolveFoldsHalfAndDoubleTimeErrors() {
        let duration = 4 * 60.0 / 120 * 2   // 2 bars of 4/4 at 120
        XCTAssertEqual(TransientDetector.resolveTempo(raw: 61, duration: duration, beatsPerBar: 4, beatUnit: 4),
                       TempoEstimate(bpm: 60, bars: 1))
        XCTAssertEqual(TransientDetector.resolveTempo(raw: 118.5, duration: duration, beatsPerBar: 4, beatUnit: 4),
                       TempoEstimate(bpm: 120, bars: 2))
    }

    func testResolveKeepsRawTempoForNonLoops() {
        let est = TransientDetector.resolveTempo(raw: 103.27, duration: 3.0, beatsPerBar: 4, beatUnit: 4)
        XCTAssertNil(est.bars)
        XCTAssertEqual(est.bpm, 103.3, accuracy: 1e-9)
    }

    func testResolveRespectsTimeSignature() {
        // 2 bars of 3/4 at 90 BPM.
        let duration = 2 * 3 * 60.0 / 90
        XCTAssertEqual(TransientDetector.resolveTempo(raw: 91, duration: duration, beatsPerBar: 3, beatUnit: 4),
                       TempoEstimate(bpm: 90, bars: 2))
    }
}

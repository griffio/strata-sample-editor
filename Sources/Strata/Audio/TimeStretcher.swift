import Foundation
import AVFoundation
import Accelerate

/// Pitch-preserving time-stretch rendered offline with AVAudioUnitTimePitch, cached per
/// (buffer, region, ratio). Clips play varispeed until their render is ready.
final class StretchCache {
    struct Key: Hashable {
        let bufferID: UUID
        let start: Int
        let length: Int
        let ratioMilli: Int   // stretch × 10 000, rounded
        let mode: StretchMode

        init(clip: Clip, bufferID: UUID) {
            mode = clip.stretchMode
            self.bufferID = bufferID
            start = clip.sourceStart
            length = clip.sourceLength
            ratioMilli = Int((clip.stretch * 10_000).rounded())
        }
    }

    private var ready: [Key: SampleBuffer] = [:]
    private var pending: Set<Key> = []
    private var lastUsed: [Key: Date] = [:]
    /// Keys referenced by the most recent graph build; never evicted.
    private var inUse: Set<Key> = []
    private let queue = DispatchQueue(label: "strata.stretch", qos: .userInitiated, attributes: .concurrent)
    private let semaphore = DispatchSemaphore(value: 2)
    /// Called on the main thread whenever a render finishes.
    var onReady: (() -> Void)?

    /// Call before each graph build so eviction knows which renders are live.
    func beginPass() { inUse.removeAll(keepingCapacity: true) }

    /// Main thread. Returns the cached render, scheduling one when missing.
    func lookup(_ clip: Clip, sample: Sample) -> SampleBuffer? {
        let key = Key(clip: clip, bufferID: sample.buffer.id)
        lastUsed[key] = Date()
        inUse.insert(key)
        if let b = ready[key] { return b }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        let buffer = sample.buffer
        let ratio = Double(key.ratioMilli) / 10_000
        queue.async { [weak self] in
            self?.semaphore.wait()
            let range = key.start..<(key.start + key.length)
            let result = key.mode == .beats
                ? WSOLAStretcher.render(buffer: buffer, range: range, stretch: ratio)
                : TimeStretcher.render(buffer: buffer, range: range, stretch: ratio)
            self?.semaphore.signal()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pending.remove(key)
                if let r = result {
                    self.ready[key] = r
                    self.evict()
                    self.onReady?()
                }
            }
        }
        return nil
    }

    /// Returns a finished render without scheduling one (used mid-gesture).
    func cached(_ clip: Clip, sample: Sample) -> SampleBuffer? {
        let key = Key(clip: clip, bufferID: sample.buffer.id)
        inUse.insert(key)
        return ready[key]
    }

    /// Renders synchronously (any thread) for offline bounces.
    static func renderNow(_ clip: Clip, sample: Sample) -> SampleBuffer? {
        let range = clip.sourceStart..<(clip.sourceStart + clip.sourceLength)
        return clip.stretchMode == .beats
            ? WSOLAStretcher.render(buffer: sample.buffer, range: range, stretch: clip.stretch)
            : TimeStretcher.render(buffer: sample.buffer, range: range, stretch: clip.stretch)
    }

    func isPending(_ clip: Clip, sample: Sample) -> Bool {
        pending.contains(Key(clip: clip, bufferID: sample.buffer.id))
    }

    /// Drops least-recently-used renders that the arrangement no longer references.
    private func evict() {
        let limit = 48
        guard ready.count > limit else { return }
        let victims = lastUsed
            .filter { ready[$0.key] != nil && !inUse.contains($0.key) }
            .sorted { $0.value < $1.value }
            .prefix(ready.count - limit)
        for v in victims { ready[v.key] = nil; lastUsed[v.key] = nil }
    }
}

enum TimeStretcher {
    static func render(buffer: SampleBuffer, range: Range<Int>, stretch: Double) -> SampleBuffer? {
        let r = range.clamped(to: 0..<buffer.frameCount)
        guard r.count > 64, stretch > 0.03, stretch < 32 else { return nil }
        let format = AudioFileIO.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(1 / stretch)
        timePitch.overlap = 24   // higher overlap = smoother, at more CPU (offline, so fine)
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            try engine.start()
        } catch {
            return nil
        }

        // Source with a silent tail so the stretcher flushes completely.
        let tail = 16_384
        guard let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(r.count + tail)) else { return nil }
        src.frameLength = AVAudioFrameCount(r.count + tail)
        for ch in 0..<2 {
            let dst = src.floatChannelData![ch]
            dst.assign(from: buffer.channel(ch) + r.lowerBound, count: r.count)
            (dst + r.count).assign(repeating: 0, count: tail)
        }
        player.scheduleBuffer(src, at: nil)
        player.play()

        let target = Int((Double(r.count) * stretch).rounded())
        let latency = Int((timePitch.latency + engine.mainMixerNode.latency) * AudioSpec.sampleRate)
        let needed = target + latency
        let out = SampleBuffer(frameCount: target)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else { return nil }
        var produced = 0
        while produced < needed {
            let want = AVAudioFrameCount(min(Int(maxFrames), needed - produced))
            guard let status = try? engine.renderOffline(want, to: chunk), status == .success else { break }
            let got = Int(chunk.frameLength)
            if got == 0 { break }
            for i in 0..<got {
                let outIndex = produced + i - latency
                if outIndex >= 0 && outIndex < target {
                    out.left[outIndex] = chunk.floatChannelData![0][i]
                    out.right[outIndex] = chunk.floatChannelData![1][i]
                }
            }
            produced += got
        }
        engine.stop()
        // Gentle edge ramps hide stretcher onset/offset artefacts.
        let ramp = min(64, target / 2)
        for i in 0..<ramp {
            let g = Float(i) / Float(ramp)
            out.left[i] *= g; out.right[i] *= g
            out.left[target - 1 - i] *= g; out.right[target - 1 - i] *= g
        }
        return out
    }
}

/// Waveform-similarity overlap-add (WSOLA) time-stretch. Deterministic and grid-tight:
/// every output frame comes from its nominal input position ± a small search window,
/// so transients never drift — ideal for drums and rhythmic loops.
enum WSOLAStretcher {
    static func render(buffer: SampleBuffer, range: Range<Int>, stretch: Double) -> SampleBuffer? {
        let r = range.clamped(to: 0..<buffer.frameCount)
        guard r.count > 256, stretch > 0.03, stretch < 32 else { return nil }
        let n = r.count
        let outLen = Int((Double(n) * stretch).rounded())
        let frame = 1536
        let hs = frame / 2                       // synthesis hop (50% overlap, Hann sums to 1)
        let ha = Double(hs) / stretch            // analysis hop
        let tolerance = 256                      // ±5 ms alignment search
        let overlapLen = frame / 2

        // Padded copies so reads past either end are silent.
        let pad = frame + tolerance * 2
        var inL = [Float](repeating: 0, count: n + pad * 2)
        var inR = [Float](repeating: 0, count: n + pad * 2)
        var mono = [Float](repeating: 0, count: n + pad * 2)
        for i in 0..<n {
            let l = buffer.left[r.lowerBound + i], rr = buffer.right[r.lowerBound + i]
            inL[pad + i] = l; inR[pad + i] = rr; mono[pad + i] = (l + rr) * 0.5
        }
        var window = [Float](repeating: 0, count: frame)
        vDSP_hann_window(&window, vDSP_Length(frame), Int32(vDSP_HANN_DENORM))

        let out = SampleBuffer(frameCount: outLen)
        var accL = [Float](repeating: 0, count: outLen + frame * 2)
        var accR = [Float](repeating: 0, count: outLen + frame * 2)
        var norm = [Float](repeating: 0, count: outLen + frame * 2)
        var prevPos = 0
        var k = 0
        var tmp = [Float](repeating: 0, count: frame)

        mono.withUnsafeBufferPointer { m in
            while k * hs < outLen + hs {
                // Frame centre ↔ k·ha, clamped so the ±tolerance search stays inside the padding.
                let nominal = min(max(Int((Double(k) * ha).rounded()) - frame / 2, -pad + tolerance),
                                  n + pad - frame - tolerance - 1)
                var pos = nominal
                if k > 0 {
                    // Natural continuation of the previous frame, compared over the overlap.
                    let target = prevPos + hs
                    var best = -Float.greatestFiniteMagnitude
                    var bestD = 0
                    var d = -tolerance
                    while d <= tolerance {
                        var dot: Float = 0
                        vDSP_dotpr(m.baseAddress! + pad + nominal + d, 1, m.baseAddress! + pad + target, 1, &dot, vDSP_Length(overlapLen))
                        if dot > best { best = dot; bestD = d }
                        d += 4
                    }
                    var lo = bestD - 3
                    let hi = bestD + 3
                    while lo <= hi {
                        var dot: Float = 0
                        vDSP_dotpr(m.baseAddress! + pad + nominal + lo, 1, m.baseAddress! + pad + target, 1, &dot, vDSP_Length(overlapLen))
                        if dot > best { best = dot; bestD = lo }
                        lo += 1
                    }
                    pos = nominal + bestD
                }
                pos = min(max(pos, -pad + 1), n + pad - frame - 1)
                let o = k * hs
                for (src, acc) in [(inL, 0), (inR, 1)] {
                    src.withUnsafeBufferPointer { s in
                        vDSP_vmul(s.baseAddress! + pad + pos, 1, window, 1, &tmp, 1, vDSP_Length(frame))
                    }
                    if acc == 0 {
                        accL.withUnsafeMutableBufferPointer { a in vDSP_vadd(a.baseAddress! + o, 1, tmp, 1, a.baseAddress! + o, 1, vDSP_Length(frame)) }
                    } else {
                        accR.withUnsafeMutableBufferPointer { a in vDSP_vadd(a.baseAddress! + o, 1, tmp, 1, a.baseAddress! + o, 1, vDSP_Length(frame)) }
                    }
                }
                norm.withUnsafeMutableBufferPointer { a in vDSP_vadd(a.baseAddress! + o, 1, window, 1, a.baseAddress! + o, 1, vDSP_Length(frame)) }
                prevPos = pos
                k += 1
            }
        }
        // Output frame k is centred at k*hs; shift by half a frame so input 0 ↔ output 0.
        let shift = frame / 2
        for i in 0..<outLen {
            let j = i + shift
            let w = max(norm[j], 1e-3)
            out.left[i] = accL[j] / w
            out.right[i] = accR[j] / w
        }
        return out
    }
}

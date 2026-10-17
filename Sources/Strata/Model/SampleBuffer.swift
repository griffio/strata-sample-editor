import Foundation
import Accelerate

/// Global audio constants. Every sample in a project is stored at this rate,
/// converted on import/record, so the mixer never needs to resample between sources.
enum AudioSpec {
    static let sampleRate: Double = 48_000
    static let maxTracks = 64
}

/// Immutable stereo audio held in unmanaged memory so the real-time thread can read
/// it through raw pointers with no ARC traffic. Edits always produce a new buffer,
/// which makes undo snapshots free and lets the audio thread keep using old data safely.
final class SampleBuffer: Identifiable {
    let id: UUID
    let frameCount: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    private var cachedPeaks: WaveformPeaks?
    private let peaksLock = NSLock()

    /// Peak pyramid, built on first use (thread-safe).
    var peaks: WaveformPeaks {
        peaksLock.lock(); defer { peaksLock.unlock() }
        if let p = cachedPeaks { return p }
        let p = WaveformPeaks(buffer: self)
        cachedPeaks = p
        return p
    }

    /// Guard frames past the end so interpolators can read `frameCount + 3` safely.
    static let padding = 8

    init(id: UUID = UUID(), frameCount: Int) {
        self.id = id
        self.frameCount = max(0, frameCount)
        let n = self.frameCount + SampleBuffer.padding
        left = .allocate(capacity: n)
        right = .allocate(capacity: n)
        left.initialize(repeating: 0, count: n)
        right.initialize(repeating: 0, count: n)
    }

    convenience init(id: UUID = UUID(), left l: [Float], right r: [Float]) {
        self.init(id: id, frameCount: min(l.count, r.count))
        l.withUnsafeBufferPointer { left.assign(from: $0.baseAddress!, count: frameCount) }
        r.withUnsafeBufferPointer { right.assign(from: $0.baseAddress!, count: frameCount) }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var duration: Double { Double(frameCount) / AudioSpec.sampleRate }

    func channel(_ index: Int) -> UnsafeMutablePointer<Float> { index == 0 ? left : right }

    /// Builds the peak pyramid eagerly (call off the main thread for long buffers).
    @discardableResult
    func preparePeaks() -> WaveformPeaks { peaks }

    // MARK: - Non-destructive edit operations (each returns a new buffer)

    func copy(range: Range<Int>) -> SampleBuffer {
        let r = range.clamped(to: 0..<frameCount)
        let out = SampleBuffer(frameCount: r.count)
        if r.count > 0 {
            out.left.assign(from: left + r.lowerBound, count: r.count)
            out.right.assign(from: right + r.lowerBound, count: r.count)
        }
        return out
    }

    func deleting(range: Range<Int>) -> SampleBuffer {
        let r = range.clamped(to: 0..<frameCount)
        let out = SampleBuffer(frameCount: frameCount - r.count)
        for ch in 0..<2 {
            let src = channel(ch), dst = out.channel(ch)
            dst.assign(from: src, count: r.lowerBound)
            (dst + r.lowerBound).assign(from: src + r.upperBound, count: frameCount - r.upperBound)
        }
        out.declick(at: r.lowerBound)
        return out
    }

    func inserting(_ other: SampleBuffer, at position: Int) -> SampleBuffer {
        let p = min(max(0, position), frameCount)
        return replacing(range: p..<p, with: other)
    }

    /// Replaces `range` with `other` in one splice (an empty range inserts), de-clicking
    /// both seams.
    func replacing(range: Range<Int>, with other: SampleBuffer) -> SampleBuffer {
        let r = range.clamped(to: 0..<frameCount)
        let out = SampleBuffer(frameCount: frameCount - r.count + other.frameCount)
        for ch in 0..<2 {
            let src = channel(ch), dst = out.channel(ch)
            dst.assign(from: src, count: r.lowerBound)
            (dst + r.lowerBound).assign(from: other.channel(ch), count: other.frameCount)
            (dst + r.lowerBound + other.frameCount).assign(from: src + r.upperBound, count: frameCount - r.upperBound)
        }
        out.declick(at: r.lowerBound)
        out.declick(at: r.lowerBound + other.frameCount)
        return out
    }

    /// Applies a per-channel transform to `range` (whole buffer when nil) on a copy.
    func transforming(range: Range<Int>?, _ body: (UnsafeMutablePointer<Float>, Int) -> Void) -> SampleBuffer {
        let r = (range ?? 0..<frameCount).clamped(to: 0..<frameCount)
        let out = SampleBuffer(frameCount: frameCount)
        out.left.assign(from: left, count: frameCount)
        out.right.assign(from: right, count: frameCount)
        if r.count > 0 {
            body(out.left + r.lowerBound, r.count)
            body(out.right + r.lowerBound, r.count)
        }
        return out
    }

    func reversed(range: Range<Int>?) -> SampleBuffer {
        transforming(range: range) { p, n in
            var i = 0, j = n - 1
            while i < j { let t = p[i]; p[i] = p[j]; p[j] = t; i += 1; j -= 1 }
        }
    }

    func silenced(range: Range<Int>?) -> SampleBuffer {
        transforming(range: range) { p, n in p.assign(repeating: 0, count: n) }
    }

    func gained(_ gain: Float, range: Range<Int>?) -> SampleBuffer {
        transforming(range: range) { p, n in
            var g = gain
            vDSP_vsmul(p, 1, &g, p, 1, vDSP_Length(n))
        }
    }

    func normalized(range: Range<Int>?, targetDB: Float = -0.3) -> SampleBuffer {
        let r = (range ?? 0..<frameCount).clamped(to: 0..<frameCount)
        guard r.count > 0 else { return self }
        var peakL: Float = 0, peakR: Float = 0
        vDSP_maxmgv(left + r.lowerBound, 1, &peakL, vDSP_Length(r.count))
        vDSP_maxmgv(right + r.lowerBound, 1, &peakR, vDSP_Length(r.count))
        let peak = max(peakL, peakR)
        guard peak > 1e-6 else { return self }
        return gained(powf(10, targetDB / 20) / peak, range: r)
    }

    enum FadeShape { case linear, equalPower, exponential }

    func faded(in fadeIn: Bool, range: Range<Int>?, shape: FadeShape = .equalPower) -> SampleBuffer {
        transforming(range: range) { p, n in
            guard n > 1 else { return }
            for i in 0..<n {
                var t = Float(i) / Float(n - 1)
                if !fadeIn { t = 1 - t }
                let g: Float
                switch shape {
                case .linear: g = t
                case .equalPower: g = sinf(t * .pi / 2)
                case .exponential: g = t * t
                }
                p[i] *= g
            }
        }
    }

    /// 2 ms raised-cosine crossfade around a splice point to avoid clicks.
    private func declick(at frame: Int) {
        let n = min(96, frame, frameCount - frame)
        guard n > 2 else { return }
        for ch in 0..<2 {
            let p = channel(ch)
            for i in 0..<n {
                let g = 0.5 - 0.5 * cosf(Float(i) / Float(n) * .pi)
                p[frame - n + i] *= 1 - g * 0.5
                p[frame + i] *= 0.5 + g * 0.5
            }
        }
    }

    /// Mono mixdown used by analysis (transient detection, zero crossings).
    func monoSamples(range: Range<Int>? = nil) -> [Float] {
        let r = (range ?? 0..<frameCount).clamped(to: 0..<frameCount)
        var out = [Float](repeating: 0, count: r.count)
        guard r.count > 0 else { return out }
        var half: Float = 0.5
        out.withUnsafeMutableBufferPointer { dst in
            vDSP_vadd(left + r.lowerBound, 1, right + r.lowerBound, 1, dst.baseAddress!, 1, vDSP_Length(r.count))
            vDSP_vsmul(dst.baseAddress!, 1, &half, dst.baseAddress!, 1, vDSP_Length(r.count))
        }
        return out
    }

    /// Nearest zero crossing (on the mono sum) within `radius` frames.
    func nearestZeroCrossing(to frame: Int, radius: Int = 1200) -> Int {
        let f = min(max(0, frame), frameCount)
        guard frameCount > 2 else { return f }
        let lo = max(1, f - radius), hi = min(frameCount - 1, f + radius)
        guard lo < hi else { return f }
        var best = f, bestDist = Int.max
        for i in lo...hi {
            let a = left[i - 1] + right[i - 1], b = left[i] + right[i]
            if (a <= 0 && b > 0) || (a >= 0 && b < 0) {
                let d = abs(i - f)
                if d < bestDist { bestDist = d; best = i }
            }
        }
        return best
    }

    /// The next zero crossing strictly after (or before) `frame`, within `limit` frames.
    /// Crossings are reported as in `nearestZeroCrossing`: the first frame of the new sign.
    func zeroCrossing(from frame: Int, forward: Bool, limit: Int = 48_000) -> Int? {
        func crosses(_ i: Int) -> Bool {
            let a = left[i - 1] + right[i - 1], b = left[i] + right[i]
            return (a <= 0 && b > 0) || (a >= 0 && b < 0)
        }
        if forward {
            var i = max(1, frame + 1)
            let end = min(frameCount - 1, frame + limit)
            while i <= end { if crosses(i) { return i }; i += 1 }
        } else {
            var i = min(frameCount - 1, frame - 1)
            let end = max(1, frame - limit)
            while i >= end { if crosses(i) { return i }; i -= 1 }
        }
        return nil
    }

    static func concatenate(_ buffers: [SampleBuffer]) -> SampleBuffer {
        let total = buffers.reduce(0) { $0 + $1.frameCount }
        let out = SampleBuffer(frameCount: total)
        var pos = 0
        for b in buffers {
            out.left.advanced(by: pos).assign(from: b.left, count: b.frameCount)
            out.right.advanced(by: pos).assign(from: b.right, count: b.frameCount)
            pos += b.frameCount
        }
        return out
    }
}

// MARK: - Peak pyramid

/// Multi-resolution min/max/RMS summary of a buffer. Level 0 summarises 32 frames per
/// bin; each further level summarises 4× more. Drawing at any zoom touches only a
/// handful of bins per pixel, so redraws stay cheap even for very long recordings.
final class WaveformPeaks {
    struct Level {
        let binSize: Int
        var minV: [[Float]]   // [channel][bin]
        var maxV: [[Float]]
        var rms: [[Float]]
        var count: Int { minV[0].count }
    }

    let levels: [Level]
    private unowned let buffer: SampleBuffer

    init(buffer: SampleBuffer) {
        self.buffer = buffer
        var levels: [Level] = []
        let base = 32
        let bins = (buffer.frameCount + base - 1) / base
        var level0 = Level(binSize: base,
                           minV: [[Float](repeating: 0, count: bins), [Float](repeating: 0, count: bins)],
                           maxV: [[Float](repeating: 0, count: bins), [Float](repeating: 0, count: bins)],
                           rms: [[Float](repeating: 0, count: bins), [Float](repeating: 0, count: bins)])
        for ch in 0..<2 {
            let src = buffer.channel(ch)
            for b in 0..<bins {
                let start = b * base
                let n = min(base, buffer.frameCount - start)
                var mn: Float = 0, mx: Float = 0, ms: Float = 0
                vDSP_minv(src + start, 1, &mn, vDSP_Length(n))
                vDSP_maxv(src + start, 1, &mx, vDSP_Length(n))
                vDSP_measqv(src + start, 1, &ms, vDSP_Length(n))
                level0.minV[ch][b] = mn
                level0.maxV[ch][b] = mx
                level0.rms[ch][b] = ms   // mean square for now; sqrt applied below
            }
        }
        levels.append(level0)
        var prev = level0
        while prev.count > 64 {
            let n = (prev.count + 3) / 4
            var next = Level(binSize: prev.binSize * 4,
                             minV: [[Float](repeating: 0, count: n), [Float](repeating: 0, count: n)],
                             maxV: [[Float](repeating: 0, count: n), [Float](repeating: 0, count: n)],
                             rms: [[Float](repeating: 0, count: n), [Float](repeating: 0, count: n)])
            for ch in 0..<2 {
                for b in 0..<n {
                    var mn: Float = .greatestFiniteMagnitude, mx: Float = -.greatestFiniteMagnitude, ms: Float = 0
                    let lo = b * 4, hi = min(lo + 4, prev.count)
                    for k in lo..<hi {
                        mn = min(mn, prev.minV[ch][k]); mx = max(mx, prev.maxV[ch][k]); ms += prev.rms[ch][k]
                    }
                    next.minV[ch][b] = mn
                    next.maxV[ch][b] = mx
                    next.rms[ch][b] = ms / Float(hi - lo)
                }
            }
            levels.append(next)
            prev = next
        }
        // Convert mean squares to RMS.
        self.levels = levels.map { lvl in
            var l = lvl
            l.rms = l.rms.map { $0.map { sqrtf($0) } }
            return l
        }
    }

    struct Column { var minV: Float; var maxV: Float; var rms: Float }

    /// Summary of frames in [from, to). `channel` -1 merges both channels.
    func column(channel: Int, from: Double, to: Double) -> Column {
        let a = max(0, Int(from)), b = min(buffer.frameCount, Int(ceil(to)))
        guard b > a else { return Column(minV: 0, maxV: 0, rms: 0) }
        let span = b - a
        if span <= 64 {
            return rawColumn(channel: channel, a: a, b: b)
        }
        var li = 0
        while li + 1 < levels.count && levels[li + 1].binSize * 2 <= span { li += 1 }
        let lvl = levels[li]
        let lo = a / lvl.binSize, hi = min(lvl.count, max(lo + 1, (b + lvl.binSize - 1) / lvl.binSize))
        var mn: Float = .greatestFiniteMagnitude, mx: Float = -.greatestFiniteMagnitude, ms: Float = 0
        let chans = channel < 0 ? [0, 1] : [channel]
        for ch in chans {
            let minA = lvl.minV[ch], maxA = lvl.maxV[ch], rmsA = lvl.rms[ch]
            for k in lo..<hi {
                if minA[k] < mn { mn = minA[k] }
                if maxA[k] > mx { mx = maxA[k] }
                ms += rmsA[k] * rmsA[k]
            }
        }
        let count = Float((hi - lo) * chans.count)
        return Column(minV: mn, maxV: mx, rms: sqrtf(ms / max(1, count)))
    }

    private func rawColumn(channel: Int, a: Int, b: Int) -> Column {
        var mn: Float = .greatestFiniteMagnitude, mx: Float = -.greatestFiniteMagnitude, ms: Float = 0
        let chans = channel < 0 ? [0, 1] : [channel]
        for ch in chans {
            let p = buffer.channel(ch)
            for i in a..<b {
                let v = p[i]
                if v < mn { mn = v }
                if v > mx { mx = v }
                ms += v * v
            }
        }
        return Column(minV: mn, maxV: mx, rms: sqrtf(ms / Float((b - a) * chans.count)))
    }
}

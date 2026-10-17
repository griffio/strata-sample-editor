import Foundation
import Accelerate

/// Onset detection for auto-slicing. Uses a high-frequency-weighted spectral-flux style
/// envelope (energy of the first difference) with an adaptive median threshold, then
/// pulls every onset back to the quiet point just before the attack.
enum TransientDetector {
    /// - Parameter sensitivity: 0…1, higher finds more (quieter) transients.
    static func detect(in buffer: SampleBuffer, range: Range<Int>? = nil, sensitivity: Double,
                       minimumGap: Double = 0.05) -> [Int] {
        let r = (range ?? 0..<buffer.frameCount).clamped(to: 0..<buffer.frameCount)
        guard r.count > 2048 else { return [] }
        let mono = buffer.monoSamples(range: r)
        let hop = 128, win = 512
        let odf = onsetEnvelope(mono, hop: hop, window: win)
        let frames = odf.count
        guard frames > 8 else { return [] }
        let lag = 4
        var peakODF: Float = 0
        vDSP_maxv(odf, 1, &peakODF, vDSP_Length(frames))
        guard peakODF > 0.5 else { return [] }

        let s = Float(min(max(sensitivity, 0), 1))
        let floor = peakODF * (0.5 - 0.45 * s)        // absolute floor relative to strongest attack
        let multiplier: Float = 1.8 - 0.9 * s           // relative to local mean
        let localHalf = 40                              // ±107 ms context
        let peakHalf = 3
        let gapFrames = max(1, Int(minimumGap * AudioSpec.sampleRate) / hop)

        var picks: [Int] = []
        for f in lag..<frames {
            let v = odf[f]
            guard v > floor else { continue }
            var isMax = true
            for k in max(0, f - peakHalf)...min(frames - 1, f + peakHalf) where k != f {
                if odf[k] > v || (odf[k] == v && k < f) { isMax = false; break }
            }
            guard isMax else { continue }
            let lo = max(0, f - localHalf), hi = min(frames, f + localHalf)
            var mean: Float = 0
            vDSP_meanv(Array(odf[lo..<hi]), 1, &mean, vDSP_Length(hi - lo))
            guard v > mean * multiplier else { continue }
            if let last = picks.last, f - last < gapFrames {
                if v > odf[last] { picks[picks.count - 1] = f }
                continue
            }
            picks.append(f)
        }

        // Refine each pick to the attack start: locate the amplitude peak, then walk
        // back along a short envelope until it falls to a fraction of that peak.
        return mono.withUnsafeBufferPointer { m -> [Int] in
            let n = mono.count
            var out: [Int] = []
            for f in picks {
                let a = max(0, f * hop - win), b = min(n, f * hop + win + hop)
                guard b > a + 32 else { continue }
                var peak: Float = 0
                var peakIdx = vDSP_Length(0)
                vDSP_maxmgvi(m.baseAddress! + a, 1, &peak, &peakIdx, vDSP_Length(b - a))
                var i = a + Int(peakIdx)
                let limit = max(0, i - Int(0.03 * AudioSpec.sampleRate))
                let threshold = peak * 0.12
                var env: Float = peak
                while i > limit {
                    var blockMax: Float = 0
                    let start = max(limit, i - 16)
                    vDSP_maxmgv(m.baseAddress! + start, 1, &blockMax, vDSP_Length(i - start))
                    env = blockMax
                    if env < threshold { break }
                    i = start
                }
                let absolute = buffer.nearestZeroCrossing(to: r.lowerBound + i, radius: 48)
                if absolute > r.lowerBound + 32, out.last.map({ absolute - $0 > 256 }) ?? true { out.append(absolute) }
            }
            return out
        }
    }

    /// Onset detection function: per-frame rise (dB) of full-band plus high-passed energy.
    /// Two bands: full-band energy catches kicks and bass, a first-difference (high-passed)
    /// band catches snares, hats and plucks. The rise is measured across one window, which
    /// keeps noisy sounds (hats, shakers) from producing frame-to-frame jitter.
    private static func onsetEnvelope(_ mono: [Float], hop: Int, window win: Int) -> [Float] {
        let frames = max(0, (mono.count - win) / hop)
        guard frames > 0 else { return [] }
        var hp = [Float](repeating: 0, count: mono.count)
        for i in 1..<mono.count { hp[i] = mono[i] - 0.95 * mono[i - 1] }

        func logEnergy(_ x: [Float]) -> [Float] {
            var e = [Float](repeating: 0, count: frames)
            x.withUnsafeBufferPointer { p in
                for f in 0..<frames {
                    var ms: Float = 0
                    vDSP_measqv(p.baseAddress! + f * hop, 1, &ms, vDSP_Length(win))
                    e[f] = 10 * log10f(ms + 1e-9)   // dB
                }
            }
            return e
        }
        let eFull = logEnergy(mono), eHigh = logEnergy(hp)
        let lag = win / hop
        var odf = [Float](repeating: 0, count: frames)
        for f in lag..<frames {
            let a = max(0, eFull[f] - eFull[f - lag])
            let b = max(0, eHigh[f] - eHigh[f - lag])
            odf[f] = a + b
        }
        return odf
    }

    /// Detects the tempo of a region (the whole buffer when nil). Loops are usually cut to
    /// whole bars, so a tempo at which the region is a power-of-two number of bars wins when
    /// it scores nearly as well as the strongest free period. That settles syncopation (a
    /// kick every 1.5 beats) and half/double time. Other audio gets the free estimate.
    static func estimateTempo(buffer: SampleBuffer, range: Range<Int>? = nil,
                              beatsPerBar: Int = 4, beatUnit: Int = 4) -> TempoEstimate? {
        let r = (range ?? 0..<buffer.frameCount).clamped(to: 0..<buffer.frameCount)
        guard let beat = periodicity(buffer.monoSamples(range: r)) else { return nil }
        let duration = Double(r.count) / AudioSpec.sampleRate
        // Bar-length tempos strong enough to be the beat; of those (they are octaves apart),
        // the one nearest the free estimate.
        var loop: (estimate: TempoEstimate, distance: Double)?
        for bars in [1, 2, 4, 8, 16, 32] {
            let bpm = barTempo(bars: bars, duration: duration, beatsPerBar: beatsPerBar, beatUnit: beatUnit)
            guard beat.range.contains(bpm), beat.strength(bpm) >= beat.peak * 0.8 else { continue }
            let distance = abs(log2(bpm / beat.bpm))
            if loop.map({ distance < $0.distance }) ?? true { loop = (TempoEstimate(bpm: bpm, bars: bars), distance) }
        }
        if let l = loop { return l.estimate }
        return resolveTempo(raw: beat.bpm, duration: duration, beatsPerBar: beatsPerBar, beatUnit: beatUnit)
    }

    /// Beat periodicity via autocorrelation of the onset envelope: the strongest tempo in
    /// `range`, its strength, and a scorer for any other tempo.
    private static func periodicity(_ mono: [Float])
        -> (bpm: Double, peak: Float, range: ClosedRange<Double>, strength: (Double) -> Float)? {
        let hop = 256
        let env = onsetEnvelope(mono, hop: hop, window: 1024)
        let frames = env.count
        guard frames > 64 else { return nil }
        let fps = AudioSpec.sampleRate / Double(hop)
        let minLag = Int(fps * 60 / 180), maxLag = min(frames / 2, Int(fps * 60 / 70))
        guard minLag < maxLag else { return nil }

        // Autocorrelation, normalised by overlap. (Circular correlation would suit exact loops,
        // but on a ragged region its wrap-around flatters every period dividing the length.)
        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(frames))
        let centred = env.map { $0 - mean }
        let maxTerm = frames * 3 / 4
        var acf = [Float](repeating: 0, count: maxTerm + 2)
        centred.withUnsafeBufferPointer { p in
            for lag in 0..<acf.count {
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &acf[lag], vDSP_Length(frames - lag))
                acf[lag] /= Float(frames - lag)
            }
        }
        /// Onset peaks are only a frame or two wide, so each lag takes the best of ±1 frame;
        /// otherwise multiples of a period that isn't a whole number of hops miss their peaks.
        func correlation(_ lag: Double) -> Float {
            let i = Int(lag.rounded())
            return max(acf[max(0, i - 1)], acf[i], acf[i + 1])
        }
        // Score each period by the pulse train it implies (1–4 periods), not a single lag:
        // a syncopated kick repeating every 1.5 beats otherwise outscores the beat itself.
        // A mild log-normal prior around 120 BPM leans octave choices towards common tempos.
        func score(_ lag: Double) -> Float {
            var sum: Float = 0, n: Float = 0
            for k in 1...4 where Double(k) * lag <= Double(maxTerm) { sum += correlation(Double(k) * lag); n += 1 }
            guard n > 0 else { return -.infinity }
            let octaves = log2(60 * fps / lag / 120)
            return sum / n * Float(exp(-0.5 * octaves * octaves))
        }
        var bestLag = Double(minLag)
        var best = -Float.infinity
        for lag in stride(from: Double(minLag), through: Double(maxLag), by: 0.125) {
            let s = score(lag)
            if s > best { best = s; bestLag = lag }
        }
        guard best > 0 else { return nil }
        return (60 * fps / bestLag, best, 70...180, { bpm in score(60 * fps / bpm) })
    }

    /// Snaps a raw tempo estimate to the tempo at which `duration` is a whole power-of-two
    /// number of bars, when one is close (folding out half/double-time errors). Loops are cut
    /// to bar lengths, so this turns a ±2% estimate into an exact one. Non-loops keep the
    /// raw estimate.
    static func resolveTempo(raw: Double, duration: Double, beatsPerBar: Int, beatUnit: Int,
                             tolerance: Double = 0.04) -> TempoEstimate {
        guard raw > 0, duration > 0 else { return TempoEstimate(bpm: raw, bars: nil) }
        var best: (bpm: Double, bars: Int, distance: Double)?
        for bars in [1, 2, 4, 8, 16, 32] {
            let bpm = barTempo(bars: bars, duration: duration, beatsPerBar: beatsPerBar, beatUnit: beatUnit)
            guard (40...240).contains(bpm) else { continue }
            let octaves = log2(bpm / raw)
            guard abs(octaves - octaves.rounded()) <= tolerance else { continue }
            // Among octave-equivalent candidates, keep the one nearest the raw estimate.
            if best.map({ abs(octaves) < $0.distance }) ?? true { best = (bpm, bars, abs(octaves)) }
        }
        if let b = best { return TempoEstimate(bpm: b.bpm, bars: b.bars) }
        return TempoEstimate(bpm: (raw * 10).rounded() / 10, bars: nil)
    }

    /// The tempo at which `duration` seconds is exactly `bars` bars.
    private static func barTempo(bars: Int, duration: Double, beatsPerBar: Int, beatUnit: Int) -> Double {
        // duration = bars × beatsPerBar × (60 / bpm × 4 / beatUnit)
        Double(bars * beatsPerBar) * 240 / (Double(beatUnit) * duration)
    }
}

/// A detected tempo; `bars` is set when the audio is a whole number of bars at `bpm`.
struct TempoEstimate: Equatable {
    var bpm: Double
    var bars: Int?

    /// Half- or double-time reading of the same audio (`factor` 0.5 or 2).
    func scaled(by factor: Double) -> TempoEstimate {
        let b = bars.map { Double($0) * factor }
        return TempoEstimate(bpm: bpm * factor, bars: b.flatMap { $0 >= 1 && $0 == $0.rounded() ? Int($0) : nil })
    }
}

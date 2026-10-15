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
        let frames = (mono.count - win) / hop
        guard frames > 8 else { return [] }

        // Two bands: full-band energy catches kicks and bass, a first-difference
        // (high-passed) band catches snares, hats and plucks.
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
        let lag = 4   // rise measured across one analysis window
        var odf = [Float](repeating: 0, count: frames)
        for f in lag..<frames {
            let a = max(0, eFull[f] - eFull[f - lag])
            let b = max(0, eHigh[f] - eHigh[f - lag])
            odf[f] = a + b
        }
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

    /// Detects the dominant beat interval via autocorrelation of the onset envelope.
    static func estimateTempo(buffer: SampleBuffer) -> Double? {
        let mono = buffer.monoSamples()
        let hop = 512
        let frames = mono.count / hop
        guard frames > 64 else { return nil }
        var env = [Float](repeating: 0, count: frames)
        var prev: Float = 0
        mono.withUnsafeBufferPointer { m in
            for f in 0..<frames {
                var ms: Float = 0
                vDSP_measqv(m.baseAddress! + f * hop, 1, &ms, vDSP_Length(hop))
                let e = log10f(ms + 1e-9)
                env[f] = max(0, e - prev)
                prev = e
            }
        }
        let fps = AudioSpec.sampleRate / Double(hop)
        let minLag = Int(fps * 60 / 180), maxLag = min(frames - 1, Int(fps * 60 / 70))
        guard minLag < maxLag else { return nil }
        var bestLag = 0
        var best: Float = 0
        for lag in minLag...maxLag {
            var acc: Float = 0
            for i in 0..<(frames - lag) { acc += env[i] * env[i + lag] }
            acc /= Float(frames - lag)
            if acc > best { best = acc; bestLag = lag }
        }
        guard bestLag > 0 else { return nil }
        return 60 * fps / Double(bestLag)
    }
}

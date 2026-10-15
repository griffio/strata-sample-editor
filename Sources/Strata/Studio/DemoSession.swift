import Foundation

/// Procedurally synthesises a small loop kit so the app can be explored without a mic.
enum DemoSession {
    static func build(bpm: Double) -> Project {
        var p = Project()
        p.bpm = bpm
        let spb = 60 / bpm
        let bar = spb * 4
        p.loop = LoopRegion(start: 0, end: bar * 4, enabled: true)

        let breakBuf = drumBreak(bpm: bpm, bars: 2)
        let bassBuf = bassLine(bpm: bpm, bars: 2)
        let stabBuf = chordStabs(bpm: bpm, bars: 2)
        let padBuf = pad(bpm: bpm, bars: 4)
        let hatBuf = shaker(bpm: bpm, bars: 1)

        let samples = [
            Sample(name: "Break \(Int(bpm))", buffer: breakBuf, colorIndex: 0, origin: "Synthesised demo"),
            Sample(name: "Sub Bass", buffer: bassBuf, colorIndex: 5, origin: "Synthesised demo"),
            Sample(name: "Chord Stabs", buffer: stabBuf, colorIndex: 7, origin: "Synthesised demo"),
            Sample(name: "Air Pad", buffer: padBuf, colorIndex: 3, origin: "Synthesised demo"),
            Sample(name: "Shaker", buffer: hatBuf, colorIndex: 2, origin: "Synthesised demo"),
        ]
        p.samples = samples
        func clip(_ s: Sample, _ start: Double, stretch: Double = 1) -> Clip {
            Clip(sampleID: s.id, name: s.name, start: start, sourceStart: 0, sourceLength: s.frameCount, stretch: stretch)
        }
        p.tracks = [
            Track(name: "Drums", colorIndex: 0, volume: 0.85, clips: [clip(samples[0], 0), clip(samples[0], bar * 2)]),
            Track(name: "Shaker", colorIndex: 2, volume: 0.5, pan: 0.3, clips: (0..<4).map { clip(samples[4], Double($0) * bar) }),
            Track(name: "Bass", colorIndex: 5, volume: 0.8, clips: [clip(samples[1], 0), clip(samples[1], bar * 2)]),
            Track(name: "Stabs", colorIndex: 7, volume: 0.6, pan: -0.15, clips: [clip(samples[2], 0), clip(samples[2], bar * 2)]),
            Track(name: "Pad", colorIndex: 3, volume: 0.55, clips: [clip(samples[3], 0)]),
        ]
        return p
    }

    // MARK: - Synthesis

    private static let sr = AudioSpec.sampleRate

    private struct Rand {
        var state: UInt64 = 0x9E3779B97F4A7C15
        mutating func next() -> Float {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(state % 2_000_000) / 1_000_000 - 1
        }
    }

    private static func mixIn(_ out: SampleBuffer, at frame: Int, gain: Float, pan: Float = 0, _ gen: (Int) -> Float, length: Int) {
        let gl = gain * min(1, 1 - pan), gr = gain * min(1, 1 + pan)
        for i in 0..<length {
            let idx = frame + i
            guard idx < out.frameCount else { break }
            let v = gen(i)
            out.left[idx] += v * gl
            out.right[idx] += v * gr
        }
    }

    static func drumBreak(bpm: Double, bars: Int) -> SampleBuffer {
        let step = 60 / bpm / 4 * sr   // sixteenth
        let total = Int(step * 16 * Double(bars))
        let out = SampleBuffer(frameCount: total)
        var rng = Rand()
        let kick: [Int] = [0, 7, 10, 16 + 0, 16 + 3, 16 + 10]
        let snare: [Int] = [4, 12, 16 + 4, 16 + 12, 16 + 15]
        for b in 0..<(bars / 2 * 2 == bars ? bars / 2 : 1) {
            let base = b * 32
            for k in kick {
                let f = Int(Double(base + k) * step)
                var phase: Float = 0
                mixIn(out, at: f, gain: 0.95, { i in
                    let t = Float(i) / Float(sr)
                    let freq = 48 + 140 * expf(-t * 38)
                    phase += 2 * .pi * freq / Float(sr)
                    let click: Float = i < 90 ? (1 - Float(i) / 90) * 0.4 : 0
                    return (sinf(phase) * expf(-t * 7.5) + click) * 0.9
                }, length: Int(sr * 0.45))
            }
            for s in snare {
                let f = Int(Double(base + s) * step)
                let ghost = s % 16 == 15
                var lp: Float = 0
                mixIn(out, at: f, gain: ghost ? 0.25 : 0.7, { i in
                    let t = Float(i) / Float(sr)
                    let n = rng.next()
                    lp += (n - lp) * 0.55
                    let tone = sinf(2 * .pi * 185 * t) * expf(-t * 22) * 0.6
                    return (n - lp * 0.6) * expf(-t * 16) * 0.8 + tone
                }, length: Int(sr * 0.32))
            }
            for h in 0..<32 {
                let f = Int(Double(base + h) * step + (h % 2 == 1 ? step * 0.12 : 0))   // swing
                let open = h % 8 == 6
                var hp: Float = 0, prev: Float = 0
                mixIn(out, at: f, gain: Float(h % 4 == 0 ? 0.22 : 0.14) * (open ? 1.2 : 1), pan: 0.2, { i in
                    let t = Float(i) / Float(sr)
                    let n = rng.next()
                    hp = 0.86 * (hp + n - prev)
                    prev = n
                    return hp * expf(-t * (open ? 9 : 55))
                }, length: Int(sr * (open ? 0.3 : 0.08)))
            }
        }
        return out.normalized(range: nil, targetDB: -1)
    }

    static func bassLine(bpm: Double, bars: Int) -> SampleBuffer {
        let step = 60 / bpm / 4 * sr
        let total = Int(step * 16 * Double(bars))
        let out = SampleBuffer(frameCount: total)
        // (sixteenth, length in sixteenths, midi note)
        let notes: [(Int, Int, Int)] = [(0, 3, 33), (3, 1, 33), (6, 2, 45), (8, 3, 31), (11, 1, 31), (14, 2, 43),
                                        (16, 3, 29), (19, 1, 29), (22, 2, 41), (24, 3, 28), (27, 2, 40), (30, 2, 31)]
        for (s, len, midi) in notes where s < 16 * bars {
            let freq = 440 * powf(2, Float(midi - 69) / 12)
            let length = Int(Double(len) * step)
            var phase: Float = 0, lp1: Float = 0, lp2: Float = 0
            mixIn(out, at: Int(Double(s) * step), gain: 0.8, { i in
                let t = Float(i) / Float(sr)
                phase += freq / Float(sr)
                if phase >= 1 { phase -= 1 }
                let saw = 2 * phase - 1
                let sub = sinf(2 * .pi * phase)
                let cutoff = 0.02 + 0.18 * expf(-t * 9)
                lp1 += (saw - lp1) * cutoff
                lp2 += (lp1 - lp2) * cutoff
                let env = min(1, Float(i) / 120) * min(1, Float(length - i) / 400)
                return (lp2 * 0.8 + sub * 0.55) * env
            }, length: length)
        }
        return out.normalized(range: nil, targetDB: -2)
    }

    static func chordStabs(bpm: Double, bars: Int) -> SampleBuffer {
        let step = 60 / bpm / 4 * sr
        let total = Int(step * 16 * Double(bars))
        let out = SampleBuffer(frameCount: total)
        let chords: [[Int]] = [[57, 60, 64, 67], [53, 57, 60, 64], [55, 59, 62, 65], [52, 55, 59, 64]]
        let hits = [2, 7, 10, 18, 23, 26]
        for (n, s) in hits.enumerated() where s < 16 * bars {
            let chord = chords[(s / 8) % chords.count]
            let length = Int(step * (n % 3 == 2 ? 3 : 1.6))
            for (v, midi) in chord.enumerated() {
                let freq = 440 * powf(2, Float(midi - 69) / 12)
                var p1: Float = 0, p2: Float = Float(v) * 0.3, lp: Float = 0
                mixIn(out, at: Int(Double(s) * step), gain: 0.22, pan: Float(v) * 0.25 - 0.375, { i in
                    let t = Float(i) / Float(sr)
                    p1 += freq * 1.003 / Float(sr); if p1 >= 1 { p1 -= 1 }
                    p2 += freq * 0.997 / Float(sr); if p2 >= 1 { p2 -= 1 }
                    let x = (2 * p1 - 1) + (2 * p2 - 1)
                    lp += (x - lp) * (0.08 + 0.3 * expf(-t * 14))
                    return lp * expf(-t * 6) * min(1, Float(i) / 60) * min(1, Float(length - i) / 300)
                }, length: length)
            }
        }
        return out.normalized(range: nil, targetDB: -3)
    }

    static func pad(bpm: Double, bars: Int) -> SampleBuffer {
        let total = Int(60 / bpm * 4 * Double(bars) * sr)
        let out = SampleBuffer(frameCount: total)
        let chords: [[Int]] = [[45, 57, 60, 64, 71], [41, 53, 57, 60, 67], [43, 55, 59, 62, 69], [40, 52, 55, 59, 67]]
        let barLen = total / bars
        for b in 0..<bars {
            for (v, midi) in chords[b % 4].enumerated() {
                let freq = 440 * powf(2, Float(midi - 69) / 12)
                var ph: [Float] = [0, 0.33, 0.66]
                var lp: Float = 0
                let len = barLen + Int(sr * 0.4)
                mixIn(out, at: b * barLen, gain: 0.12, pan: Float(v % 2 == 0 ? -0.4 : 0.4), { i in
                    var x: Float = 0
                    for k in 0..<3 {
                        ph[k] += freq * (1 + Float(k - 1) * 0.004) / Float(sr)
                        if ph[k] >= 1 { ph[k] -= 1 }
                        x += 2 * ph[k] - 1
                    }
                    let t = Float(i) / Float(sr)
                    lp += (x - lp) * (0.03 + 0.02 * sinf(t * 1.7 + Float(v)))
                    let env = min(1, Float(i) / Float(sr * 0.35)) * min(1, Float(len - i) / Float(sr * 0.4))
                    return lp * env
                }, length: len)
            }
        }
        return out.normalized(range: nil, targetDB: -4)
    }

    static func shaker(bpm: Double, bars: Int) -> SampleBuffer {
        let step = 60 / bpm / 4 * sr
        let total = Int(step * 16 * Double(bars))
        let out = SampleBuffer(frameCount: total)
        var rng = Rand(state: 0xD1B54A32D192ED03)
        for s in 0..<(16 * bars) {
            let accent: Float = s % 4 == 2 ? 1 : (s % 2 == 0 ? 0.55 : 0.35)
            var hp: Float = 0, prev: Float = 0
            mixIn(out, at: Int(Double(s) * step), gain: 0.5 * accent, { i in
                let t = Float(i) / Float(sr)
                let n = rng.next()
                hp = 0.7 * (hp + n - prev); prev = n
                let env = min(1, t * 400) * expf(-t * 30)
                return hp * env
            }, length: Int(step * 0.9))
        }
        return out.normalized(range: nil, targetDB: -6)
    }
}

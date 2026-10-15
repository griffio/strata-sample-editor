import Foundation
import Accelerate

/// Real-time view of one clip. Plain-old-data only (raw pointers and numbers) so the
/// audio thread can iterate clips without touching reference counts.
struct RenderClip {
    var start: Int64               // timeline frame
    var length: Int64              // timeline frames
    var srcL: UnsafeMutablePointer<Float>
    var srcR: UnsafeMutablePointer<Float>
    var srcStart: Double
    var srcEnd: Int                // exclusive, within the source buffer
    var rate: Double               // source frames per timeline frame (1 / stretch)
    var cacheL: UnsafeMutablePointer<Float>?   // pre-rendered pitch-preserving stretch
    var cacheR: UnsafeMutablePointer<Float>?
    var cacheLength: Int
    var gain: Float
    var fadeIn: Int64
    var fadeOut: Int64
}

struct RenderTrack {
    var firstClip: Int
    var clipCount: Int
    var volume: Float
    var pan: Float
    var audible: Bool
}

/// Immutable snapshot of the arrangement handed to the audio thread.
final class RenderGraph {
    let clips: ContiguousArray<RenderClip>
    let tracks: ContiguousArray<RenderTrack>
    let loopEnabled: Bool
    let loopStart: Int64
    let loopEnd: Int64
    let framesPerBeat: Double
    let beatsPerBar: Int
    let metronome: Bool
    let masterVolume: Float
    /// Keeps every buffer referenced by raw pointer alive for the graph's lifetime.
    private let retained: [AnyObject]

    static let empty = RenderGraph(project: Project(), stretchCache: { _ in nil })

    init(project: Project, stretchCache: (Clip) -> SampleBuffer?) {
        let sr = AudioSpec.sampleRate
        var clips = ContiguousArray<RenderClip>()
        var tracks = ContiguousArray<RenderTrack>()
        var retained: [AnyObject] = []
        let samples = Dictionary(uniqueKeysWithValues: project.samples.map { ($0.id, $0) })

        for track in project.tracks.prefix(AudioSpec.maxTracks) {
            let first = clips.count
            for clip in track.clips.sorted(by: { $0.start < $1.start }) where !clip.muted {
                guard let sample = samples[clip.sampleID] else { continue }
                let buffer = sample.buffer
                let srcStart = min(max(0, clip.sourceStart), buffer.frameCount)
                let srcEnd = min(buffer.frameCount, srcStart + max(0, clip.sourceLength))
                guard srcEnd > srcStart else { continue }
                retained.append(buffer)
                let length = Int64((Double(srcEnd - srcStart) * clip.stretch).rounded())
                var rc = RenderClip(start: Int64((clip.start * sr).rounded()), length: length,
                                    srcL: buffer.left, srcR: buffer.right,
                                    srcStart: Double(srcStart), srcEnd: srcEnd,
                                    rate: 1 / clip.stretch,
                                    cacheL: nil, cacheR: nil, cacheLength: 0,
                                    gain: clip.gain,
                                    fadeIn: Int64(clip.fadeIn * sr), fadeOut: Int64(clip.fadeOut * sr))
                if clip.isStretched && clip.preservePitch, let cache = stretchCache(clip) {
                    retained.append(cache)
                    rc.cacheL = cache.left
                    rc.cacheR = cache.right
                    rc.cacheLength = cache.frameCount
                }
                clips.append(rc)
            }
            tracks.append(RenderTrack(firstClip: first, clipCount: clips.count - first,
                                      volume: track.volume, pan: track.pan,
                                      audible: project.isAudible(track)))
        }
        self.clips = clips
        self.tracks = tracks
        self.retained = retained
        loopEnabled = project.loop.enabled && project.loop.end > project.loop.start + 0.01
        loopStart = Int64((project.loop.start * sr).rounded())
        loopEnd = Int64((project.loop.end * sr).rounded())
        framesPerBeat = project.secondsPerBeat * sr
        beatsPerBar = project.beatsPerBar
        metronome = project.metronome
        masterVolume = project.masterVolume
    }
}

/// The mixing core. Used by the real-time engine and by offline bounces.
/// All memory is preallocated; `render` never allocates, locks or calls into ObjC.
final class ArrangementRenderer {
    static let maxChunk = 1024

    private let trackL: UnsafeMutablePointer<Float>
    private let trackR: UnsafeMutablePointer<Float>
    private let gainState: UnsafeMutablePointer<Float>   // [track*2 + ch] current smoothed gains
    private var masterGain: Float = 0
    private let meters: AtomicFloats?

    // Metronome voice
    private var clickRemaining = 0
    private var clickPhase: Float = 0
    private var clickInc: Float = 0
    private var clickAmp: Float = 0
    private var clickEnv: Float = 0
    var metronomeLevel: Float = 0.5
    /// Offline bounces disable the click.
    var allowMetronome = true

    init(meters: AtomicFloats?) {
        self.meters = meters
        trackL = .allocate(capacity: Self.maxChunk)
        trackR = .allocate(capacity: Self.maxChunk)
        trackL.initialize(repeating: 0, count: Self.maxChunk)
        trackR.initialize(repeating: 0, count: Self.maxChunk)
        gainState = .allocate(capacity: AudioSpec.maxTracks * 2)
        gainState.initialize(repeating: 0, count: AudioSpec.maxTracks * 2)
    }

    deinit {
        trackL.deallocate()
        trackR.deallocate()
        gainState.deallocate()
    }

    /// Mixes `frames` frames starting at timeline frame `pos` into `outL/outR` (adds).
    /// `forceClick` enables the metronome regardless of the project setting (count-in).
    func render(graph: RenderGraph, pos: Int64, frames total: Int,
                outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, forceClick: Bool) {
        var offset = 0
        while offset < total {
            let n = min(Self.maxChunk, total - offset)
            renderChunk(graph: graph, pos: pos + Int64(offset), frames: n,
                        outL: outL + offset, outR: outR + offset, forceClick: forceClick)
            offset += n
        }
    }

    /// Starts smoothing at the target values (offline renders shouldn't fade in).
    func primeGains(graph: RenderGraph) {
        for (ti, t) in graph.tracks.enumerated() {
            let panL: Float = t.pan <= 0 ? 1 : cosf(t.pan * .pi / 2)
            let panR: Float = t.pan >= 0 ? 1 : cosf(-t.pan * .pi / 2)
            gainState[ti * 2] = t.audible ? t.volume * panL : 0
            gainState[ti * 2 + 1] = t.audible ? t.volume * panR : 0
        }
        masterGain = graph.masterVolume
    }

    func resetSmoothing() {
        gainState.assign(repeating: 0, count: AudioSpec.maxTracks * 2)
        masterGain = 0
        clickRemaining = 0
    }

    private func renderChunk(graph: RenderGraph, pos: Int64, frames n: Int,
                             outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, forceClick: Bool) {
        let chunkEnd = pos + Int64(n)
        var meterMasterL: Float = 0, meterMasterR: Float = 0

        graph.tracks.withUnsafeBufferPointer { tracks in
            graph.clips.withUnsafeBufferPointer { clips in
                for ti in 0..<tracks.count {
                    let track = tracks[ti]
                    // Balance-style pan keeps a centred stereo sample at unity.
                    let panL: Float = track.pan <= 0 ? 1 : cosf(track.pan * .pi / 2)
                    let panR: Float = track.pan >= 0 ? 1 : cosf(-track.pan * .pi / 2)
                    let targetL = track.audible ? track.volume * panL : 0
                    let targetR = track.audible ? track.volume * panR : 0
                    let gl0 = gainState[ti * 2], gr0 = gainState[ti * 2 + 1]
                    gainState[ti * 2] = targetL
                    gainState[ti * 2 + 1] = targetR
                    if gl0 == 0 && gr0 == 0 && targetL == 0 && targetR == 0 { continue }

                    var any = false
                    for ci in track.firstClip..<(track.firstClip + track.clipCount) {
                        let clip = clips[ci]
                        let clipEnd = clip.start + clip.length
                        if clip.start >= chunkEnd { break }   // sorted by start
                        if clipEnd <= pos { continue }
                        if !any {
                            trackL.assign(repeating: 0, count: n)
                            trackR.assign(repeating: 0, count: n)
                            any = true
                        }
                        renderClip(clip, pos: pos, frames: n)
                    }
                    guard any else { continue }

                    // Apply smoothed gain ramp and sum.
                    var peakL: Float = 0, peakR: Float = 0
                    let stepL = (targetL - gl0) / Float(n), stepR = (targetR - gr0) / Float(n)
                    var gl = gl0, gr = gr0
                    for i in 0..<n {
                        gl += stepL; gr += stepR
                        let l = trackL[i] * gl, r = trackR[i] * gr
                        outL[i] += l
                        outR[i] += r
                        let al = abs(l), ar = abs(r)
                        if al > peakL { peakL = al }
                        if ar > peakR { peakR = ar }
                    }
                    if let meters = meters {
                        meters.storeMax(ti * 2, peakL)
                        meters.storeMax(ti * 2 + 1, peakR)
                    }
                }
            }
        }

        // Metronome
        if (graph.metronome && allowMetronome) || forceClick {
            let fpb = graph.framesPerBeat
            var beat = Int64(((Double(pos) - 0.5) / fpb).rounded(.up))
            var beatFrame = Int64((Double(beat) * fpb).rounded())
            if beatFrame < pos { beat += 1; beatFrame = Int64((Double(beat) * fpb).rounded()) }
            for i in 0..<n {
                let f = pos + Int64(i)
                if f == beatFrame {
                    let barBeat = ((beat % Int64(graph.beatsPerBar)) + Int64(graph.beatsPerBar)) % Int64(graph.beatsPerBar)
                    let freq: Float = barBeat == 0 ? 1760 : 1175
                    clickInc = 2 * .pi * freq / Float(AudioSpec.sampleRate)
                    clickPhase = 0
                    clickRemaining = 2400
                    clickEnv = 1
                    clickAmp = (barBeat == 0 ? 0.55 : 0.36) * metronomeLevel
                    beat += 1
                    beatFrame = Int64((Double(beat) * fpb).rounded())
                }
                if clickRemaining > 0 {
                    let s = sinf(clickPhase) * clickAmp * clickEnv
                    clickPhase += clickInc
                    if clickPhase > 2 * .pi { clickPhase -= 2 * .pi }
                    clickEnv *= 0.9975
                    clickRemaining -= 1
                    outL[i] += s
                    outR[i] += s
                }
            }
        } else {
            clickRemaining = 0
        }

        // Master gain with smoothing + metering.
        let target = graph.masterVolume
        let step = (target - masterGain) / Float(n)
        var g = masterGain
        for i in 0..<n {
            g += step
            outL[i] = Self.softClip(outL[i] * g)
            outR[i] = Self.softClip(outR[i] * g)
            let al = abs(outL[i]), ar = abs(outR[i])
            if al > meterMasterL { meterMasterL = al }
            if ar > meterMasterR { meterMasterR = ar }
        }
        masterGain = target
        if let meters = meters {
            meters.storeMax(AudioSpec.maxTracks * 2, meterMasterL)
            meters.storeMax(AudioSpec.maxTracks * 2 + 1, meterMasterR)
        }
    }

    @inline(__always)
    private func renderClip(_ clip: RenderClip, pos: Int64, frames n: Int) {
        let from = max(pos, clip.start)
        let to = min(pos + Int64(n), clip.start + clip.length)
        guard to > from else { return }
        let declick: Int64 = 64
        let fadeIn = max(clip.fadeIn, declick)
        let fadeOut = max(clip.fadeOut, declick)

        var t = from - clip.start
        var i = Int(from - pos)
        let end = Int(to - pos)

        while i < end {
            var l: Float = 0, r: Float = 0
            if let cl = clip.cacheL, let cr = clip.cacheR {
                let idx = Int(t)
                if idx < clip.cacheLength { l = cl[idx]; r = cr[idx] }
            } else if clip.rate == 1 {
                let idx = Int(clip.srcStart) + Int(t)
                if idx < clip.srcEnd { l = clip.srcL[idx]; r = clip.srcR[idx] }
            } else {
                let s = clip.srcStart + Double(t) * clip.rate
                let idx = Int(s)
                if idx < clip.srcEnd {
                    let frac = Float(s - Double(idx))
                    l = Self.hermite(clip.srcL, idx, frac)
                    r = Self.hermite(clip.srcR, idx, frac)
                }
            }
            var g = clip.gain
            if t < fadeIn {
                let x = Float(t) / Float(fadeIn)
                g *= clip.fadeIn > declick ? sinf(x * .pi / 2) : x
            }
            let remaining = clip.length - t
            if remaining < fadeOut {
                let x = Float(remaining) / Float(fadeOut)
                g *= clip.fadeOut > declick ? sinf(x * .pi / 2) : x
            }
            trackL[i] += l * g
            trackR[i] += r * g
            i += 1
            t += 1
        }
    }

    /// Transparent below −1 dBFS; above it a tanh knee keeps peaks under 0 dBFS.
    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let t: Float = 0.89
        let a = abs(x)
        guard a > t else { return x }
        let y = t + (1 - t) * tanhf((a - t) / (1 - t))
        return x < 0 ? -y : y
    }

    /// 4-point, 3rd-order Hermite interpolation.
    @inline(__always)
    static func hermite(_ p: UnsafeMutablePointer<Float>, _ idx: Int, _ frac: Float) -> Float {
        let xm1 = idx > 0 ? p[idx - 1] : p[idx]
        let x0 = p[idx], x1 = p[idx + 1], x2 = p[idx + 2]
        let c = (x1 - xm1) * 0.5
        let v = x0 - x1
        let w = c + v
        let a = w + v + (x2 - x0) * 0.5
        let b = w + a
        return (((a * frac) - b) * frac + c) * frac + x0
    }
}

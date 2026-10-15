import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import os

/// One-shot audition of a sample region, independent of the transport.
struct PreviewRequest {
    var buffer: SampleBuffer
    var range: Range<Int>
    var loop: Bool
    var gain: Float = 0.9
}

/// Owns the output AVAudioEngine and the real-time render callback. The UI talks to the
/// audio thread only through try-locked command slots and atomics.
final class PlaybackEngine {
    let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    let meters = AtomicFloats(count: AudioSpec.maxTracks * 2 + 2)
    private let renderer: ArrangementRenderer

    // MARK: State shared with the audio thread

    private let lock = UnfairLock()
    // Guarded by `lock`:
    private var pendingGraph: RenderGraph?
    private var retiredGraph: RenderGraph?
    private var pendingSeek: Int64?
    private var pendingPlaying: Bool?
    private var pendingPreview: PreviewRequest??
    /// Live retarget of the playing preview (plain data: no ARC on the audio thread).
    private var pendingPreviewRegion: (start: Int, end: Int, loop: Bool, buffer: UnsafeMutablePointer<Float>)?
    private var retiredPreview: SampleBuffer?
    private var monitorSource: StereoRingBuffer?
    private var monitorGain: Float = 0

    // Audio-thread-only:
    private var graph: RenderGraph = .empty
    private var playing = false
    private var position: Int64 = 0
    private var previewBuffer: SampleBuffer?
    private var previewL: UnsafeMutablePointer<Float>?
    private var previewR: UnsafeMutablePointer<Float>?
    private var previewPos = 0
    private var previewStart = 0
    private var previewEnd = 0
    private var previewLoop = false
    private var previewGain: Float = 0
    private var rtMonitor: StereoRingBuffer?
    private var rtMonitorGain: Float = 0
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private static let scratchSize = 8192

    /// 0 position, 1 playing, 2 seqlock, 3 host time, 4 frame at host time, 8 playing at mapping time,
    /// 5 preview position (-1 idle), 6 count-in click-until frame, 7 loop wrap counter
    let shared = AtomicInts(count: 9)

    private(set) var outputLatency: Double = 0
    private(set) var isRunning = false
    /// Whether the engine should be running (restarts after device changes only if so).
    private var wantsRunning = false
    private let log = Logger(subsystem: "com.griffio.strata", category: "playback")
    var onConfigurationChange: (() -> Void)?
    private var configObserver: NSObjectProtocol?

    init() {
        renderer = ArrangementRenderer(meters: meters)
        scratchL = .allocate(capacity: Self.scratchSize)
        scratchR = .allocate(capacity: Self.scratchSize)
        scratchL.initialize(repeating: 0, count: Self.scratchSize)
        scratchR.initialize(repeating: 0, count: Self.scratchSize)
        shared[5] = -1
        shared[6] = Int64.min

        let format = AVAudioFormat(standardFormatWithSampleRate: AudioSpec.sampleRate, channels: 2)!
        sourceNode = AVAudioSourceNode(format: format) { [unowned self] _, timestamp, frameCount, abl in
            self.render(timestamp: timestamp, frames: Int(frameCount), abl: abl)
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
            self?.onConfigurationChange?()
        }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        engine.stop()
        scratchL.deallocate()
        scratchR.deallocate()
    }

    // MARK: Lifecycle

    func start() {
        wantsRunning = true
        guard !engine.isRunning else { isRunning = true; return }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            outputLatency = engine.outputNode.presentationLatency
        } catch {
            isRunning = false
            log.error("Output engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopEngine() {
        wantsRunning = false
        engine.stop()
        isRunning = false
    }

    /// Re-establishes the I/O after a hardware configuration change.
    func restart() {
        let shouldRun = wantsRunning
        engine.stop()
        isRunning = false
        if shouldRun { start() }
    }

    /// Routes playback to a specific output device (nil = system default).
    func setOutputDevice(_ id: AudioDeviceID?) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device = id ?? AudioDevices.defaultOutputDeviceID()
        guard device != 0 else { return }
        let wasRunning = engine.isRunning
        engine.stop()
        isRunning = false
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if wasRunning { start() }
    }

    // MARK: Commands (main thread)

    func update(graph newGraph: RenderGraph) {
        lock.withLock {
            pendingGraph = newGraph
            retiredGraph = nil   // released here, on the main thread
        }
    }

    func setPlaying(_ on: Bool) {
        lock.withLock { pendingPlaying = on }
        shared[1] = on ? 1 : 0
    }

    func seek(toFrame frame: Int64) {
        lock.withLock { pendingSeek = frame }
        shared[0] = frame
    }

    func setCountIn(clickUntil frame: Int64?) {
        shared[6] = frame ?? Int64.min
    }

    func preview(_ request: PreviewRequest?) {
        lock.withLock {
            pendingPreview = .some(request)
            retiredPreview = nil
        }
        if request == nil { shared[5] = -1 } else { shared[5] = Int64(request!.range.lowerBound) }
    }

    /// Changes the region of the preview that is playing now, keeping the playhead where it
    /// is (wrapping to the new start if it falls outside). Ignored if `buffer` isn't playing.
    func updatePreviewRegion(_ range: Range<Int>, loop: Bool, buffer: SampleBuffer) {
        guard range.count > 0 else { return }
        lock.withLock {
            pendingPreviewRegion = (range.lowerBound, range.upperBound, loop, buffer.left)
        }
    }

    func setMonitor(_ ring: StereoRingBuffer?, gain: Float) {
        if ring != nil && gain > 0 { start() }
        lock.withLock {
            monitorSource = ring
            monitorGain = gain
        }
    }

    var metronomeLevel: Float {
        get { renderer.metronomeLevel }
        set { renderer.metronomeLevel = newValue }
    }

    var positionFrame: Int64 { shared[0] }
    var isPlaying: Bool { shared[1] != 0 }
    var previewPosition: Int? { let p = shared[5]; return p >= 0 ? Int(p) : nil }

    /// Sequence number of the host-time mapping (advances every render callback).
    var mappingSequence: Int64 { shared[2] }

    /// True once a render callback has published a mapping while the transport was playing.
    func hasPlayingMapping(after sequence: Int64) -> Bool {
        shared[2] >= sequence + 4 && shared[8] == 1
    }

    /// Maps a host time to the timeline frame that was audible at that instant.
    func timelineFrame(atHostTime host: UInt64) -> Int64 {
        var h: Int64 = 0, f: Int64 = 0
        for _ in 0..<64 {
            let s1 = shared[2]
            if s1 & 1 != 0 { continue }
            h = shared[3]; f = shared[4]
            if shared[2] == s1 { break }
        }
        let dt = HostClock.signedSeconds(from: UInt64(max(0, h)), to: host) - outputLatency
        return f + Int64((dt * AudioSpec.sampleRate).rounded())
    }

    // MARK: Real-time render

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, frames: Int,
                        abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count >= 2,
              let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        outL.assign(repeating: 0, count: frames)
        outR.assign(repeating: 0, count: frames)

        if lock.tryLock() {
            if let g = pendingGraph, retiredGraph == nil {
                retiredGraph = graph      // released later by the main thread
                graph = g
                pendingGraph = nil
            }
            if let s = pendingSeek { position = s; pendingSeek = nil }
            if let p = pendingPlaying {
                if p && !playing { renderer.resetSmoothing() }
                playing = p
                pendingPlaying = nil
            }
            if let req = pendingPreview, retiredPreview == nil {
                retiredPreview = previewBuffer
                if let r = req {
                    previewBuffer = r.buffer
                    previewL = r.buffer.left
                    previewR = r.buffer.right
                    previewStart = r.range.lowerBound
                    previewEnd = r.range.upperBound
                    previewPos = r.range.lowerBound
                    previewLoop = r.loop
                    previewGain = r.gain
                } else {
                    previewBuffer = nil
                    previewL = nil
                    previewR = nil
                }
                pendingPreview = nil
            }
            if let region = pendingPreviewRegion {
                if previewL == region.buffer {
                    previewStart = region.start
                    previewEnd = region.end
                    previewLoop = region.loop
                    if previewPos < previewStart || previewPos >= previewEnd { previewPos = previewStart }
                }
                pendingPreviewRegion = nil
            }
            rtMonitor = monitorSource
            rtMonitorGain = monitorGain
            lock.unlock()
        }

        // Publish the host-time ↔ timeline mapping for latency-compensated recording.
        let seq = shared[2]
        shared[2] = seq + 1
        shared[3] = Int64(timestamp.pointee.mHostTime)
        shared[4] = position
        shared[8] = playing ? 1 : 0
        shared[2] = seq + 2

        if playing {
            var offset = 0
            var pos = position
            let g = graph
            while offset < frames {
                var chunk = frames - offset
                if g.loopEnabled {
                    if pos >= g.loopEnd { pos = g.loopStart; shared[7] = shared[7] + 1 }
                    chunk = min(chunk, Int(g.loopEnd - pos))
                }
                let clickUntil = shared[6]
                renderer.render(graph: g, pos: pos, frames: chunk, outL: outL + offset, outR: outR + offset,
                                forceClick: clickUntil != Int64.min && pos < clickUntil)
                pos += Int64(chunk)
                offset += chunk
            }
            position = pos
            shared[0] = pos
        }

        renderPreview(outL: outL, outR: outR, frames: frames)
        renderMonitor(outL: outL, outR: outR, frames: frames)
        return noErr
    }

    private func renderPreview(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        guard let pl = previewL, let pr = previewR else { return }
        var i = 0
        while i < frames {
            if previewPos >= previewEnd {
                if previewLoop && previewEnd > previewStart { previewPos = previewStart } else {
                    previewL = nil; previewR = nil
                    shared[5] = -1
                    return
                }
            }
            let n = min(frames - i, previewEnd - previewPos)
            for k in 0..<n {
                // Short declick ramps at both ends of the region.
                let fromStart = previewPos + k - previewStart, toEnd = previewEnd - previewPos - k
                let ramp = min(1, Float(min(fromStart, toEnd)) / 96)
                let g = previewGain * ramp
                outL[i + k] += pl[previewPos + k] * g
                outR[i + k] += pr[previewPos + k] * g
            }
            previewPos += n
            i += n
        }
        shared[5] = Int64(previewPos)
    }

    private func renderMonitor(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        guard let ring = rtMonitor, rtMonitorGain > 0 else { return }
        // Keep latency bounded: drop anything beyond two callbacks' worth.
        ring.skip(keeping: frames * 2 + 256)
        let n = ring.read(left: scratchL, right: scratchR, count: min(frames, Self.scratchSize))
        let g = rtMonitorGain
        for i in 0..<n {
            outL[i] += scratchL[i] * g
            outR[i] += scratchR[i] * g
        }
    }

    // MARK: Offline bounce

    /// Renders `range` (seconds) of the arrangement to a new buffer, faster than real time.
    static func bounce(graph: RenderGraph, from start: Double, to end: Double) -> SampleBuffer {
        let renderer = ArrangementRenderer(meters: nil)
        renderer.allowMetronome = false
        renderer.primeGains(graph: graph)
        let sr = AudioSpec.sampleRate
        let startFrame = Int64(start * sr)
        let total = max(0, Int((end - start) * sr))
        let out = SampleBuffer(frameCount: total)
        renderer.render(graph: graph, pos: startFrame, frames: total, outL: out.left, outR: out.right, forceClick: false)
        return out
    }
}

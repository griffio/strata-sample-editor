import Foundation
import AVFoundation
import AudioToolbox
import Combine
import ScreenCaptureKit
import CoreGraphics

enum CaptureSource: Hashable {
    case none
    case device(uid: String)
    case system(bundleID: String?)
}

/// Accumulates captured audio for a take. Written by the capture thread, read by the UI.
final class Recorder {
    private let lock = UnfairLock()
    private var left: [Float] = []
    private var right: [Float] = []
    private var livePeaks: [Float] = []        // max |x| per `peakBin` frames
    private var binAccum: Float = 0
    private var binCount = 0
    private(set) var firstHostTime: UInt64?
    static let peakBin = 256

    init(expectedSeconds: Double = 60) {
        let n = Int(expectedSeconds * AudioSpec.sampleRate)
        left.reserveCapacity(n)
        right.reserveCapacity(n)
    }

    func append(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int, hostTime: UInt64) {
        lock.withLock {
            if firstHostTime == nil { firstHostTime = hostTime }
            left.append(contentsOf: UnsafeBufferPointer(start: l, count: count))
            right.append(contentsOf: UnsafeBufferPointer(start: r, count: count))
            for i in 0..<count {
                binAccum = max(binAccum, abs(l[i]), abs(r[i]))
                binCount += 1
                if binCount == Self.peakBin {
                    livePeaks.append(binAccum)
                    binAccum = 0
                    binCount = 0
                }
            }
        }
    }

    var frameCount: Int { lock.withLock { left.count } }
    var hostTimeOfFirstFrame: UInt64? { lock.withLock { firstHostTime } }

    func peaksSnapshot() -> [Float] { lock.withLock { livePeaks } }

    /// Builds the final buffer, dropping `drop` leading frames and keeping at most `limit`.
    func finish(drop: Int = 0, limit: Int? = nil) -> SampleBuffer? {
        lock.withLock {
            let start = min(max(0, drop), left.count)
            let end = min(left.count, start + (limit ?? left.count))
            guard end > start else { return nil }
            return SampleBuffer(left: Array(left[start..<end]), right: Array(right[start..<end]))
        }
    }
}

/// Fixed-length history of the monitored source for retroactive "grab" capture.
final class HistoryBuffer {
    private let lock = UnfairLock()
    private var left: [Float]
    private var right: [Float]
    private var writeIndex = 0
    private var filled = 0
    let capacity: Int

    init(seconds: Double) {
        capacity = Int(seconds * AudioSpec.sampleRate)
        left = [Float](repeating: 0, count: capacity)
        right = [Float](repeating: 0, count: capacity)
    }

    func append(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) {
        lock.withLock {
            var i = 0
            while i < count {
                let n = min(count - i, capacity - writeIndex)
                left.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: writeIndex).assign(from: l + i, count: n) }
                right.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: writeIndex).assign(from: r + i, count: n) }
                writeIndex = (writeIndex + n) % capacity
                i += n
            }
            filled = min(capacity, filled + count)
        }
    }

    var availableSeconds: Double { lock.withLock { Double(filled) / AudioSpec.sampleRate } }

    func snapshot(seconds: Double) -> SampleBuffer? {
        lock.withLock {
            let n = min(filled, Int(seconds * AudioSpec.sampleRate))
            guard n > 0 else { return nil }
            let out = SampleBuffer(frameCount: n)
            let start = (writeIndex - n + capacity) % capacity
            for k in 0..<n {
                let idx = (start + k) % capacity
                out.left[k] = left[idx]
                out.right[k] = right[idx]
            }
            return out
        }
    }

    func clear() { lock.withLock { filled = 0; writeIndex = 0 } }
}

/// The single, app-wide capture pipeline:
///
///     hardware input ─▶ AVAudioSinkNode ─┐
///                                        ├─▶ raw SPSC ring ─▶ consumer (5 ms) ─▶ 48 kHz convert
///     system audio ──▶ ScreenCaptureKit ─┘        ├─▶ meters / scope / grab history
///                                                  ├─▶ monitor ring ─▶ playback engine
///                                                  └─▶ active Recorder
final class CaptureService: ObservableObject {
    static let shared = CaptureService()

    enum Status: Equatable {
        case idle, starting, running
        case failed(String)
        case permissionDenied(String)
    }

    @Published private(set) var source: CaptureSource = .none
    @Published private(set) var status: Status = .idle
    @Published private(set) var sourceChannelCount = 0
    @Published private(set) var sourceSampleRate: Double = 0
    @Published var firstChannel = 0 { didSet { pushChannelConfig() } }
    @Published var stereo = true { didSet { pushChannelConfig() } }
    @Published var inputGain: Float = 1 { didSet { gainBits[0] = Int64(inputGain.bitPattern) } }
    @Published private(set) var shareableApps: [ShareableApp] = []
    @Published var monitoring = false { didSet { updateMonitor() } }
    @Published var monitorLevel: Float = 0.8 { didSet { updateMonitor() } }

    let monitorRing = StereoRingBuffer(minimumCapacity: 1 << 14)
    let history = HistoryBuffer(seconds: 60)
    let levels = AtomicFloats(count: 2)
    private(set) var inputLatency: Double = 0

    weak var monitorEngine: PlaybackEngine? {
        didSet {
            if oldValue !== monitorEngine { oldValue?.setMonitor(nil, gain: 0) }
            updateMonitor()
        }
    }

    // Raw capture → consumer
    private let rawRing = StereoRingBuffer(minimumCapacity: 1 << 17)
    private var rawRate: Double = AudioSpec.sampleRate
    private let mapping = AtomicInts(count: 3)        // seq, host time, raw frame index
    private let channelConfig = AtomicInts(count: 2)  // first channel, stereo flag
    private let gainBits = AtomicInts(count: 1, value: Int64(Float(1).bitPattern))
    private let consumerQueue = DispatchQueue(label: "strata.capture.consumer", qos: .userInteractive)
    private var consumerTimer: DispatchSourceTimer?
    private var consumed: Int64 = 0
    private var converter: AVAudioConverter?
    private var convIn: AVAudioPCMBuffer?
    private var convOut: AVAudioPCMBuffer?
    private let readL = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
    private let readR = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)

    // Scope: max |x| per 10 ms, last 30 s.
    private let scopeLock = UnfairLock()
    private var scope = [Float](repeating: 0, count: 3000)
    private var scopeIndex = 0
    private var scopeAccum: Float = 0
    private var scopeCount = 0

    private let recorderLock = UnfairLock()
    private var recorder: Recorder?

    private var inputEngine: AVAudioEngine?
    private var inputObserver: NSObjectProtocol?
    private var systemCapturer: SystemAudioCapturer?
    private var generation = 0

    private init() {
        channelConfig[1] = 1
    }

    // MARK: Source selection

    func select(_ newSource: CaptureSource) {
        guard newSource != source || status != .running else { return }
        stopCurrent()
        source = newSource
        generation += 1
        let gen = generation
        switch newSource {
        case .none:
            status = .idle
        case .device(let uid):
            status = .starting
            requestMicrophone { [weak self] granted in
                guard let self = self, self.generation == gen else { return }
                if granted { self.startDevice(uid: uid) } else {
                    self.status = .permissionDenied("Allow microphone access for Strata in System Settings › Privacy & Security › Microphone.")
                }
            }
        case .system(let bundleID):
            // Check silently first: touching ScreenCaptureKit without permission makes
            // macOS show its dialog every time. Ask once; the grant needs a relaunch.
            guard Self.hasScreenCaptureAccess else {
                if !requestedScreenAccess {
                    requestedScreenAccess = true
                    CGRequestScreenCaptureAccess()
                }
                status = .permissionDenied("System Audio needs Screen & System Audio Recording permission. Turn on Strata in System Settings, then relaunch Strata.")
                return
            }
            status = .starting
            startSystem(bundleID: bundleID, generation: gen)
        }
    }

    /// Non-prompting check (CoreGraphics preflight); true only after a grant and relaunch.
    static var hasScreenCaptureAccess: Bool { CGPreflightScreenCaptureAccess() }
    private var requestedScreenAccess = false

    /// Lists apps for single-app capture. No-op without permission so it never prompts.
    func refreshShareableApps() {
        guard Self.hasScreenCaptureAccess else { return }
        Task {
            let apps = await SystemAudioCapturer.availableApps()
            await MainActor.run { self.shareableApps = apps }
        }
    }

    var sourceDisplayName: String {
        switch source {
        case .none: return "No Source"
        case .device(let uid): return AudioDevices.shared.device(uid: uid)?.name ?? "Input Device"
        case .system(let id):
            if let id = id { return shareableApps.first { $0.id == id }?.name ?? "App Audio" }
            return "System Audio"
        }
    }

    private func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    private func stopCurrent() {
        if let o = inputObserver { NotificationCenter.default.removeObserver(o); inputObserver = nil }
        inputEngine?.stop()
        inputEngine = nil
        systemCapturer?.stop()
        systemCapturer = nil
        stopConsumer()
        sourceChannelCount = 0
    }

    private func startDevice(uid: String) {
        guard let device = AudioDevices.shared.device(uid: uid) else {
            status = .failed("The device is no longer available.")
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            status = .failed("The input could not be opened.")
            return
        }
        var id = device.id
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard err == noErr else {
            status = .failed("Couldn’t select “\(device.name)” (error \(err)).")
            return
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = .failed("“\(device.name)” reports no usable input format.")
            return
        }
        sourceChannelCount = Int(format.channelCount)
        sourceSampleRate = format.sampleRate
        if firstChannel >= sourceChannelCount { firstChannel = 0 }
        if sourceChannelCount == 1 { stereo = false }
        pushChannelConfig()
        prepareConsumer(rate: format.sampleRate)

        let sink = AVAudioSinkNode { [unowned self] timestamp, frames, abl in
            self.receiveDevice(timestamp: timestamp, frames: Int(frames), abl: abl)
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        do {
            try engine.start()
            inputEngine = engine
            inputLatency = input.presentationLatency
            // Device unplugged, sample rate changed, etc. → reconnect cleanly.
            let gen = generation
            inputObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self = self, self.generation == gen, case .device(let current) = self.source, current == uid else { return }
                self.stopCurrent()
                self.status = .starting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    // The user may have picked another source meanwhile.
                    guard self.generation == gen, self.source == .device(uid: uid) else { return }
                    if AudioDevices.shared.device(uid: uid) != nil { self.startDevice(uid: uid) }
                    else { self.status = .failed("“\(device.name)” was disconnected.") }
                }
            }
            status = .running
            startConsumer()
        } catch {
            status = .failed("“\(device.name)” failed to start: \(error.localizedDescription)")
        }
    }

    private func startSystem(bundleID: String?, generation gen: Int) {
        sourceChannelCount = 2
        sourceSampleRate = AudioSpec.sampleRate
        firstChannel = 0
        stereo = true
        pushChannelConfig()
        prepareConsumer(rate: AudioSpec.sampleRate)
        inputLatency = 0
        let capturer = SystemAudioCapturer { [unowned self] l, r, n, host in
            self.writeRaw(left: l, right: r, frames: n, hostTime: host)
        }
        capturer.onStop = { [weak self] error in
            guard let self = self, self.generation == gen else { return }
            self.stopConsumer()
            self.status = .failed(error?.localizedDescription ?? "System audio capture stopped.")
        }
        systemCapturer = capturer
        Task {
            do {
                try await capturer.start(appBundleID: bundleID)
                await MainActor.run {
                    guard self.generation == gen else { capturer.stop(); return }
                    self.status = .running
                    self.startConsumer()
                    if self.shareableApps.isEmpty { self.refreshShareableApps() }
                }
            } catch {
                await MainActor.run {
                    guard self.generation == gen else { return }
                    let ns = error as NSError
                    if ns.domain == SCStreamErrorDomain || ns.code == -3801 {
                        self.status = .permissionDenied("System Audio needs Screen & System Audio Recording permission. Turn on Strata in System Settings, then relaunch Strata.")
                    } else {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func pushChannelConfig() {
        channelConfig[0] = Int64(firstChannel)
        channelConfig[1] = stereo ? 1 : 0
    }

    // MARK: Producers (real-time / capture threads)

    private func receiveDevice(timestamp: UnsafePointer<AudioTimeStamp>, frames: Int, abl: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard list.count > 0 else { return }
        let first = Int(channelConfig[0])
        let isStereo = channelConfig[1] != 0
        // De-interleaved: one buffer per channel.
        func channel(_ i: Int) -> UnsafePointer<Float>? {
            let idx = min(max(0, i), list.count - 1)
            return list[idx].mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) }
        }
        guard let l = channel(first) else { return }
        let r = isStereo ? (channel(first + 1) ?? l) : l
        writeRaw(left: l, right: r, frames: frames, hostTime: timestamp.pointee.mHostTime)
    }

    private func writeRaw(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, hostTime: UInt64) {
        let index = rawRing.totalWritten
        let seq = mapping[0]
        mapping[0] = seq + 1
        mapping[1] = Int64(bitPattern: hostTime)
        mapping[2] = index
        mapping[0] = seq + 2
        rawRing.write(left: left, right: right, count: frames)
    }

    private func hostTime(ofRawFrame frame: Int64) -> UInt64 {
        var host: Int64 = 0, idx: Int64 = 0
        for _ in 0..<64 {
            let s = mapping[0]
            if s & 1 != 0 { continue }
            host = mapping[1]; idx = mapping[2]
            if mapping[0] == s { break }
        }
        let dt = Double(frame - idx) / rawRate
        let base = UInt64(bitPattern: host)
        return dt >= 0 ? base &+ HostClock.ticks(dt) : base &- HostClock.ticks(-dt)
    }

    // MARK: Consumer

    private func prepareConsumer(rate: Double) {
        consumerQueue.sync {
            rawRing.reset()
            consumed = rawRing.totalWritten
            rawRate = rate
            if rate != AudioSpec.sampleRate {
                let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
                converter = AVAudioConverter(from: inFmt, to: AudioFileIO.processingFormat)
                converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
                convIn = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 16_384)
                convOut = AVAudioPCMBuffer(pcmFormat: AudioFileIO.processingFormat,
                                           frameCapacity: AVAudioFrameCount(16_384 * AudioSpec.sampleRate / rate + 64))
            } else {
                converter = nil
                convIn = nil
                convOut = nil
            }
        }
    }

    private func startConsumer() {
        stopConsumer()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: consumerQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        consumerTimer = timer
    }

    private func stopConsumer() {
        consumerTimer?.cancel()
        consumerTimer = nil
        levels.store(0, 0)
        levels.store(1, 0)
    }

    private func drain() {
        while true {
            let n = rawRing.read(left: readL, right: readR, count: 4096)
            guard n > 0 else { return }
            let host = hostTime(ofRawFrame: consumed)
            consumed += Int64(n)
            let g = Float(bitPattern: UInt32(truncatingIfNeeded: gainBits[0]))
            if g != 1 {
                for i in 0..<n { readL[i] *= g; readR[i] *= g }
            }
            if let converter = converter, let inBuf = convIn, let outBuf = convOut {
                inBuf.floatChannelData![0].assign(from: readL, count: n)
                inBuf.floatChannelData![1].assign(from: readR, count: n)
                inBuf.frameLength = AVAudioFrameCount(n)
                outBuf.frameLength = 0
                var supplied = false
                var error: NSError?
                converter.convert(to: outBuf, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return inBuf
                }
                let m = Int(outBuf.frameLength)
                if m > 0 { deliver(left: outBuf.floatChannelData![0], right: outBuf.floatChannelData![1], count: m, hostTime: host) }
            } else {
                deliver(left: readL, right: readR, count: n, hostTime: host)
            }
        }
    }

    private func deliver(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, count n: Int, hostTime: UInt64) {
        var pl: Float = 0, pr: Float = 0
        scopeLock.withLock {
            for i in 0..<n {
                let al = abs(l[i]), ar = abs(r[i])
                if al > pl { pl = al }
                if ar > pr { pr = ar }
                scopeAccum = max(scopeAccum, al, ar)
                scopeCount += 1
                if scopeCount >= 480 {
                    scope[scopeIndex] = scopeAccum
                    scopeIndex = (scopeIndex + 1) % scope.count
                    scopeAccum = 0
                    scopeCount = 0
                }
            }
        }
        levels.storeMax(0, pl)
        levels.storeMax(1, pr)
        history.append(left: l, right: r, count: n)
        monitorRing.write(left: l, right: r, count: n)
        recorderLock.withLock { recorder?.append(left: l, right: r, count: n, hostTime: hostTime) }
    }

    /// Last `count` scope bins (10 ms each), oldest first.
    func scopeSnapshot(count: Int) -> [Float] {
        scopeLock.withLock {
            let n = min(count, scope.count)
            var out = [Float](repeating: 0, count: n)
            for k in 0..<n {
                out[k] = scope[(scopeIndex - n + k + scope.count * 2) % scope.count]
            }
            return out
        }
    }

    #if DEBUG
    // MARK: Test signal (developer aid)

    private var testThread: Thread?

    /// Feeds a 44.1 kHz synthetic source through the full pipeline (resampling, meters,
    /// scope, history, recorder) without touching hardware or privacy permissions.
    func debugStartTestSignal(sourceUID: String? = nil) {
        stopCurrent()
        generation += 1
        source = .device(uid: sourceUID ?? "test-signal")
        sourceChannelCount = 2
        sourceSampleRate = 44_100
        firstChannel = 0
        stereo = true
        pushChannelConfig()
        prepareConsumer(rate: 44_100)
        status = .running
        startConsumer()
        let gen = generation
        let t = Thread { [weak self] in
            var phase = 0.0
            var l = [Float](repeating: 0, count: 441), r = [Float](repeating: 0, count: 441)
            var n = 0
            let start = Date()
            while let self = self, self.generation == gen {
                if Double(n) / 44_100 > Date().timeIntervalSince(start) { Thread.sleep(forTimeInterval: 0.002); continue }
                for i in 0..<441 {
                    let env = Float(0.5 + 0.5 * sin(Double(n + i) / 44_100 * 2 * .pi * 2))   // 2 Hz tremolo
                    l[i] = Float(sin(phase)) * 0.6 * env
                    r[i] = Float(sin(phase * 1.5)) * 0.4 * env
                    phase += 2 * .pi * 220 / 44_100
                }
                n += 441
                l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
                    self.writeRaw(left: lp.baseAddress!, right: rp.baseAddress!, frames: 441, hostTime: HostClock.now)
                } }
            }
        }
        t.start()
        testThread = t
    }
    #endif

    // MARK: Recording & monitoring

    func beginRecording() -> Recorder {
        let rec = Recorder()
        recorderLock.withLock { recorder = rec }
        return rec
    }

    func endRecording() {
        recorderLock.withLock { recorder = nil }
    }

    var isCapturing: Bool { status == .running }

    private func updateMonitor() {
        monitorEngine?.setMonitor(monitoring ? monitorRing : nil, gain: monitoring ? monitorLevel : 0)
    }
}

import SwiftUI
import Combine
import AppKit

/// Horizontal geometry of the arrangement (zoom + scroll), shared by ruler and lanes.
final class TimelineViewport: ObservableObject {
    @Published var pixelsPerSecond: Double = 48
    @Published var scrollSeconds: Double = 0
    var laneWidth: CGFloat = 900

    static let minPPS = 3.0
    static let maxPPS = 6000.0

    func x(_ t: Double) -> CGFloat { CGFloat((t - scrollSeconds) * pixelsPerSecond) }
    func time(_ x: CGFloat) -> Double { Double(x) / pixelsPerSecond + scrollSeconds }

    var visibleRange: ClosedRange<Double> { scrollSeconds...time(laneWidth) }

    func zoom(by factor: Double, anchorX: CGFloat) {
        let t = time(anchorX)
        let pps = min(Self.maxPPS, max(Self.minPPS, pixelsPerSecond * factor))
        guard pps != pixelsPerSecond else { return }
        pixelsPerSecond = pps
        scrollSeconds = max(0, t - Double(anchorX) / pps)
    }

    func scroll(byPixels dx: CGFloat) {
        let s = max(0, scrollSeconds + Double(dx) / pixelsPerSecond)
        if s != scrollSeconds { scrollSeconds = s }
    }

    func fit(_ range: ClosedRange<Double>) {
        let span = max(0.25, range.upperBound - range.lowerBound)
        pixelsPerSecond = min(Self.maxPPS, max(Self.minPPS, Double(laneWidth) * 0.94 / span))
        scrollSeconds = max(0, range.lowerBound - span * 0.03)
    }
}

/// High-frequency transport state, kept separate so only the views that need 60 fps
/// updates (playhead, LCD, editor cursor) are invalidated.
final class TransportClock: ObservableObject {
    @Published var position: Double = 0
    @Published var previewFrame: Int?
}

/// Smoothed meter levels for tracks, master and the capture source.
final class MeterStore: ObservableObject {
    @Published var tracks: [UUID: (Float, Float)] = [:]
    @Published var master: (Float, Float) = (0, 0)
    @Published var input: (Float, Float) = (0, 0)
    @Published var scope: [Float] = []
    var peakHold: [UUID: Float] = [:]
}

/// Sample editor view state.
final class EditorState: ObservableObject {
    @Published var sampleID: UUID?
    @Published var clipID: UUID?
    @Published var framesPerPixel: Double = 400
    @Published var scrollFrame: Double = 0
    @Published var selection: Range<Int>?
    @Published var verticalZoom: Float = 1
    @Published var snapToZeroCrossings = true
    @Published var sensitivity: Double = 0.55
    @Published var loopPreview = false
    var width: CGFloat = 800

    func x(_ frame: Double) -> CGFloat { CGFloat((frame - scrollFrame) / framesPerPixel) }
    func frame(_ x: CGFloat) -> Double { Double(x) * framesPerPixel + scrollFrame }

    func fit(frames: Int) {
        framesPerPixel = max(0.02, Double(max(1, frames)) / Double(max(100, width - 2)))
        scrollFrame = 0
    }

    func zoom(by factor: Double, anchorX: CGFloat, totalFrames: Int) {
        let f = frame(anchorX)
        let maxFPP = Double(max(1, totalFrames)) / Double(max(100, width)) * 1.2
        framesPerPixel = min(max(0.02, maxFPP), max(0.02, framesPerPixel / factor))
        scrollFrame = clampScroll(f - Double(anchorX) * framesPerPixel, totalFrames: totalFrames)
    }

    func clampScroll(_ s: Double, totalFrames: Int) -> Double {
        let visible = Double(width) * framesPerPixel
        return min(max(0, s), max(0, Double(totalFrames) - visible * 0.5))
    }
}

struct StudioAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum FocusArea { case arrangement, editor }

/// Per-window controller: owns the playback engine and implements every user action.
final class Studio: ObservableObject {
    let document: ProjectDocument
    let engine = PlaybackEngine()
    let stretchCache = StretchCache()
    let viewport = TimelineViewport()
    let clock = TransportClock()
    let meters = MeterStore()
    let editor = EditorState()
    let capture = CaptureService.shared
    weak var undoManager: UndoManager?
    weak var window: NSWindow?

    @Published var selectedClips: Set<UUID> = []
    @Published var selectedTrackID: UUID?
    @Published var tool: EditTool = .pointer
    @Published var snap: SnapGrid = .beat
    @Published private(set) var isPlaying = false
    @Published var followPlayhead = true
    @Published var focus: FocusArea = .arrangement
    @Published var alert: StudioAlert?
    @Published var toast: String?
    @Published var showEditor = true
    @Published var librarySelection: UUID?
    @Published var showShortcuts = false

    // Recording
    @Published var isRecording = false
    @Published var recordingTrackID: UUID?
    @Published var recordingStart: Double = 0
    @Published var recordingDuration: Double = 0
    @Published var livePeaks: [Float] = []
    var recorder: Recorder?
    var recordStartFrame: Int64 = 0
    var recordFirstFrame: Int64?
    var recordLoopTarget: Int64?
    var takeCounter = 1
    var recordWrapCount: Int64 = 0
    var recordWrapTicks = 0

    private var gestureBase: Project?
    private var gestureName = ""
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var keyMonitor: Any?
    private var toastWork: DispatchWorkItem?
    private var lastWrapCount: Int64 = 0
    private var tick = 0

    var project: Project { document.project }

    init(document: ProjectDocument) {
        self.document = document
        document.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        document.$project
            .sink { [weak self] p in self?.rebuildGraph(p) }
            .store(in: &cancellables)
        stretchCache.onReady = { [weak self] in
            guard let self = self else { return }
            self.rebuildGraph(self.project)
            self.objectWillChange.send()
        }
        engine.onConfigurationChange = { [weak self] in self?.capture.monitorEngine = self?.engine }
        applySettings()
        engine.start()
        capture.monitorEngine = engine
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        if let first = document.project.tracks.first { selectedTrackID = first.id }
        if let s = document.project.samples.first { openInEditor(sampleID: s.id) }
        startTimer()
        if !document.project.tracks.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.zoomToFit() }
        }
    }

    deinit {
        timer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if isRecording { capture.endRecording() }
        engine.setPlaying(false)
        engine.stopEngine()
        if capture.monitorEngine === engine { capture.monitorEngine = nil }
    }

    func windowBecameKey() {
        capture.monitorEngine = engine
    }

    // MARK: - Settings

    private var appliedOutputUID: String? {
        get { objc_getAssociatedObject(self, &Studio.outputKey) as? String }
        set { objc_setAssociatedObject(self, &Studio.outputKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    private static var outputKey = 0

    private func applySettings() {
        let d = UserDefaults.standard
        let level = d.object(forKey: "metronomeLevel") as? Double ?? 0.5
        engine.metronomeLevel = Float(level)
        let uid = d.string(forKey: "outputDeviceUID") ?? ""
        if uid != appliedOutputUID {
            appliedOutputUID = uid
            if uid.isEmpty {
                if engine.isRunning { engine.setOutputDevice(nil) }
            } else if let dev = AudioDevices.shared.outputs.first(where: { $0.uid == uid }) {
                engine.setOutputDevice(dev.id)
            }
        }
    }

    func loadDemo() {
        let demo = DemoSession.build(bpm: 124)
        perform("Load Demo Kit") { p in
            p.bpm = demo.bpm
            p.loop = demo.loop
            p.samples += demo.samples
            p.tracks += demo.tracks
        }
        DispatchQueue.global(qos: .userInitiated).async { demo.samples.forEach { $0.buffer.preparePeaks() } }
        selectedTrackID = demo.tracks.first?.id
        if let s = demo.samples.first { openInEditor(sampleID: s.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.zoomToFit() }
        showToast("Demo kit loaded — press Space to play")
    }

    // MARK: - Engine sync

    private func rebuildGraph(_ p: Project) {
        let graph = RenderGraph(project: p) { [weak self] clip in
            guard let self = self, let s = p.sample(clip.sampleID) else { return nil }
            // While dragging, preview stretches as varispeed; render once on release.
            return self.gestureBase == nil ? self.stretchCache.lookup(clip, sample: s) : self.stretchCache.cached(clip, sample: s)
        }
        engine.update(graph: graph)
    }

    // MARK: - Undo

    /// Applies a mutation as one undoable step.
    func perform(_ name: String, _ body: (inout Project) -> Void) {
        let old = document.project
        var p = old
        body(&p)
        guard p != old else { return }
        document.project = p
        registerUndo(restoring: old, name: name)
    }

    private func registerUndo(restoring old: Project, name: String) {
        guard let um = undoManager else { return }
        // Outside an event (timers, async completions) open an explicit group so the
        // step never merges with the user's next action.
        let explicit = um.groupingLevel == 0 && !um.isUndoing && !um.isRedoing
        if explicit { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { studio in
            let current = studio.document.project
            studio.document.project = old
            studio.registerUndo(restoring: current, name: name)
            studio.validateSelection()
        }
        um.setActionName(name)
        if explicit { um.endUndoGrouping() }
    }

    /// Continuous gestures (drags, fader moves) update live and commit one undo step.
    func beginGesture(_ name: String) {
        if gestureBase == nil { gestureBase = document.project }
        gestureName = name
    }

    func live(_ body: (inout Project) -> Void) {
        var p = document.project
        body(&p)
        if p != document.project { document.project = p }
    }

    func endGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        if base != document.project { registerUndo(restoring: base, name: gestureName) }
        rebuildGraph(document.project)
    }

    /// Abandons a gesture, restoring the state from before it began.
    func cancelGesture() {
        guard let base = gestureBase else { return }
        gestureBase = nil
        document.project = base
        validateSelection()
    }

    /// Live-or-undoable change used by controls that may be dragged or clicked.
    func change(_ name: String, _ body: (inout Project) -> Void) {
        if gestureBase != nil { live(body) } else { perform(name, body) }
    }

    func validateSelection() {
        let ids = Set(project.tracks.flatMap { $0.clips.map(\.id) })
        selectedClips = selectedClips.intersection(ids)
        if let s = editor.sampleID, project.sample(s) == nil { editor.sampleID = project.samples.first?.id }
        if let c = editor.clipID, !ids.contains(c) { editor.clipID = nil }
    }

    // MARK: - Transport

    var positionSeconds: Double { Double(engine.positionFrame) / AudioSpec.sampleRate }

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard !isPlaying else { return }
        if !engine.isRunning { engine.start() }
        if project.loop.enabled && positionSeconds >= project.loop.end { seek(to: project.loop.start) }
        engine.setPlaying(true)
        isPlaying = true
        lastWrapCount = engine.shared[7]
    }

    func stop() {
        if isRecording { stopRecording() }
        if isPlaying {
            engine.setPlaying(false)
            engine.setCountIn(clickUntil: nil)
            isPlaying = false
            if positionSeconds < 0 { seek(to: 0) }
        } else {
            seek(to: project.loop.enabled && positionSeconds > project.loop.start + 0.001 ? project.loop.start : 0)
        }
        clock.position = positionSeconds
    }

    func seek(to seconds: Double) {
        let s = max(project.countIn ? -project.secondsPerBar : 0, seconds)
        engine.seek(toFrame: Int64((s * AudioSpec.sampleRate).rounded()))
        clock.position = s
    }

    func returnToStart() { seek(to: project.loop.enabled ? project.loop.start : 0) }

    func toggleLoop() {
        perform(project.loop.enabled ? "Loop Off" : "Loop On") { $0.loop.enabled.toggle() }
    }

    func toggleMetronome() {
        perform("Metronome") { $0.metronome.toggle() }
    }

    func setLoop(start: Double, end: Double, enable: Bool = true) {
        let a = max(0, min(start, end)), b = max(start, end)
        guard b - a > 0.01 else { return }
        change("Set Loop") { $0.loop = LoopRegion(start: a, end: b, enabled: enable || $0.loop.enabled) }
    }

    func loopSelection() {
        let clips = project.tracks.flatMap(\.clips).filter { selectedClips.contains($0.id) }
        guard let a = clips.map(\.start).min(), let b = clips.map(\.end).max() else { return }
        setLoop(start: snapTime(a, mode: .floor), end: snapTime(b, mode: .ceil))
    }

    func setBPM(_ bpm: Double) {
        change("Tempo") { $0.bpm = min(300, max(30, bpm)) }
    }

    // MARK: - Snapping

    enum SnapMode { case nearest, floor, ceil }

    func snapTime(_ t: Double, mode: SnapMode = .nearest, bypass: Bool = false) -> Double {
        guard !bypass, let step = snap.step(in: project) else { return t }
        let q = t / step
        switch mode {
        case .nearest: return q.rounded() * step
        case .floor: return floor(q + 1e-9) * step
        case .ceil: return ceil(q - 1e-9) * step
        }
    }

    // MARK: - Timer (60 Hz UI refresh)

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func onTick() {
        tick += 1
        let pos = positionSeconds
        if isPlaying || abs(clock.position - pos) > 0.0005 {
            clock.position = pos
            if isPlaying && followPlayhead { followIfNeeded(pos) }
        }
        let pv = engine.previewPosition
        if pv != clock.previewFrame { clock.previewFrame = pv }
        if isRecording { pollRecording() }
        if tick % 2 == 0 { updateMeters() }
    }

    private func followIfNeeded(_ pos: Double) {
        let vp = viewport
        let x = vp.x(pos)
        if x > vp.laneWidth * 0.92 || x < 0 {
            vp.scrollSeconds = max(0, pos - Double(vp.laneWidth) * 0.08 / vp.pixelsPerSecond)
        }
    }

    private func updateMeters() {
        func decay(_ old: Float, _ new: Float) -> Float { max(new, old * 0.82) }
        var tracks: [UUID: (Float, Float)] = [:]
        for (i, t) in project.tracks.prefix(AudioSpec.maxTracks).enumerated() {
            let l = engine.meters.take(i * 2), r = engine.meters.take(i * 2 + 1)
            let old = meters.tracks[t.id] ?? (0, 0)
            tracks[t.id] = (decay(old.0, l), decay(old.1, r))
        }
        let ml = engine.meters.take(AudioSpec.maxTracks * 2), mr = engine.meters.take(AudioSpec.maxTracks * 2 + 1)
        let il = capture.levels.take(0), ir = capture.levels.take(1)
        let changed = tracks.contains { abs(($0.value.0 + $0.value.1) - ((meters.tracks[$0.key]?.0 ?? 0) + (meters.tracks[$0.key]?.1 ?? 0))) > 0.0005 }
        if changed || tracks.count != meters.tracks.count { meters.tracks = tracks }
        let newMaster = (decay(meters.master.0, ml), decay(meters.master.1, mr))
        if newMaster != meters.master { meters.master = newMaster }
        let newInput = (decay(meters.input.0, il), decay(meters.input.1, ir))
        if newInput != meters.input { meters.input = newInput }
        if capture.isCapturing {
            meters.scope = capture.scopeSnapshot(count: 600)
        } else if !meters.scope.isEmpty {
            meters.scope = []
        }
    }

    // MARK: - Feedback

    func showToast(_ message: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    func fail(_ title: String, _ error: Error) {
        alert = StudioAlert(title: title, message: error.localizedDescription)
    }

    // MARK: - Keyboard

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let w = self.window, event.window === w, w.isKeyWindow else { return event }
            if w.firstResponder is NSText { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard mods.isEmpty || mods == .shift else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 49: togglePlay(); return true                       // space
        case 36, 76: returnToStart(); return true                 // return / enter
        case 51, 117:                                             // delete
            if focus == .editor, editor.selection != nil { editDeleteSelection() } else { deleteSelectedClips() }
            return true
        case 123: nudgeSelection(-1, fine: mods == .shift); return true   // ←
        case 124: nudgeSelection(1, fine: mods == .shift); return true    // →
        case 53: selectedClips = []; editor.selection = nil; stopPreview(); return true // esc
        default: break
        }
        switch chars {
        case "r": toggleRecord()
        case "l": toggleLoop()
        case "k": toggleMetronome()
        case "v": tool = .pointer
        case "b": tool = .blade
        case "t": tool = .stretch
        case "s": splitAtPlayhead()
        case "m": addSliceMarkerAtCursor()
        case "z": if focus == .editor { editorZoomToFit() } else { zoomToFit() }
        case "p": previewEditorSelection()
        case "f": followPlayhead.toggle(); showToast(followPlayhead ? "Follow Playhead On" : "Follow Playhead Off")
        case "=", "+": zoom(1.4)
        case "-": zoom(1 / 1.4)
        default: return false
        }
        return true
    }

    func zoom(_ factor: Double) {
        if focus == .editor, let s = editorSample {
            editor.zoom(by: factor, anchorX: editor.width / 2, totalFrames: s.frameCount)
        } else {
            let anchor = isPlaying ? viewport.x(positionSeconds) : viewport.laneWidth / 2
            viewport.zoom(by: factor, anchorX: anchor)
        }
    }

    func zoomToFit() {
        let end = max(project.contentEnd, project.loop.enabled ? project.loop.end : 0, project.secondsPerBar * 4)
        withAnimation(.easeInOut(duration: 0.25)) { viewport.fit(0...end) }
    }
}

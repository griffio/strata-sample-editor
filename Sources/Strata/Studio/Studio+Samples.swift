import Foundation
import AppKit
import UniformTypeIdentifiers

extension Studio {
    var editorSample: Sample? { editor.sampleID.flatMap { project.sample($0) } }

    // MARK: - Library

    @discardableResult
    func addSample(_ buffer: SampleBuffer, name: String, origin: String, select: Bool = true) -> UUID {
        let color = project.samples.count % Theme.trackColors.count
        let sample = Sample(name: uniqueSampleName(name), buffer: buffer, colorIndex: color, origin: origin)
        DispatchQueue.global(qos: .userInitiated).async { buffer.preparePeaks() }
        perform("Add Sample") { $0.samples.append(sample) }
        if select { openInEditor(sampleID: sample.id) }
        return sample.id
    }

    func uniqueSampleName(_ base: String) -> String {
        let names = Set(project.samples.map(\.name))
        guard names.contains(base) else { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    func deleteSample(_ id: UUID) {
        perform("Delete Sample") { p in
            p.samples.removeAll { $0.id == id }
            p.reconcileClips(forSample: id)
        }
        if editor.sampleID == id { editor.sampleID = project.samples.first?.id; editor.clipID = nil; editor.selection = nil }
        validateSelection()
    }

    func renameSample(_ id: UUID, to name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        perform("Rename Sample") { p in
            if let i = p.sampleIndex(id) { p.samples[i].name = name }
        }
    }

    func duplicateSample(_ id: UUID) {
        guard let s = project.sample(id) else { return }
        addSample(s.buffer, name: s.name + " Copy", origin: s.origin)
    }

    func openInEditor(sampleID: UUID, clipID: UUID? = nil) {
        let changed = editor.sampleID != sampleID
        editor.sampleID = sampleID
        editor.clipID = clipID
        librarySelection = sampleID
        showEditor = true
        guard let s = project.sample(sampleID) else { return }
        if let cid = clipID, let clip = project.clip(cid) {
            editor.selection = clip.sourceStart..<(clip.sourceStart + clip.sourceLength)
        } else if changed {
            editor.selection = nil
        }
        if changed { editor.fit(frames: s.frameCount) }
    }

    // MARK: - Import / export

    func importAudio(urls: [URL], placeAt time: Double? = nil, onTrack trackID: UUID? = nil) {
        let audio = urls.filter { AudioFileIO.importableExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else {
            alert = StudioAlert(title: "Unsupported File", message: "Strata imports WAV, AIFF, CAF, MP3, M4A/AAC and FLAC audio.")
            return
        }
        showToast(audio.count == 1 ? "Importing \(audio[0].lastPathComponent)…" : "Importing \(audio.count) files…")
        DispatchQueue.global(qos: .userInitiated).async {
            var loaded: [(URL, SampleBuffer)] = []
            var failures: [String] = []
            for url in audio {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let b = try AudioFileIO.load(url: url)
                    b.preparePeaks()
                    loaded.append((url, b))
                } catch { failures.append(url.lastPathComponent) }
            }
            DispatchQueue.main.async {
                var cursor = time
                var track = trackID
                for (url, buffer) in loaded {
                    let id = self.addSample(buffer, name: url.deletingPathExtension().lastPathComponent,
                                            origin: "Imported from \(url.lastPathComponent)", select: loaded.count == 1)
                    if let t = cursor {
                        self.placeSample(id, onTrack: track, at: t)
                        if track != nil { cursor = t + buffer.duration } else { track = nil }
                    }
                }
                if !failures.isEmpty {
                    self.alert = StudioAlert(title: "Some Files Couldn’t Be Imported", message: failures.joined(separator: "\n"))
                }
                if let first = loaded.first, loaded.count == 1 { self.showToast("Imported \(first.0.lastPathComponent)") }
                else if loaded.count > 1 { self.showToast("Imported \(loaded.count) files") }
            }
        }
    }

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose audio files to add to the library"
        panel.prompt = "Import"
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { resp in
            if resp == .OK { self.importAudio(urls: panel.urls) }
        }
    }

    func exportSample(_ id: UUID, selectionOnly: Bool = false) {
        guard let s = project.sample(id), let w = window else { return }
        let range = selectionOnly ? editor.selection : nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav, .aiff]
        panel.nameFieldStringValue = s.name + ".wav"
        panel.message = "Export as 48 kHz / 24-bit"
        panel.beginSheetModal(for: w) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try AudioFileIO.write(s.buffer, range: range, to: url, kind: url.pathExtension.lowercased().hasPrefix("aif") ? .aiff : .wav)
                self.showToast("Exported \(url.lastPathComponent)")
            } catch { self.fail("Export Failed", error) }
        }
    }

    func exportMixdown() {
        guard let w = window else { return }
        let p = project
        let start = p.loop.enabled ? p.loop.start : 0
        let end = p.loop.enabled ? p.loop.end : max(p.contentEnd, 0.1)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav, .aiff]
        panel.nameFieldStringValue = (w.title.isEmpty ? "Mixdown" : w.title.replacingOccurrences(of: ".strata", with: "")) + " Mix.wav"
        panel.message = p.loop.enabled ? "Bounce the loop region (\(formatDuration(end - start)))" : "Bounce the whole arrangement (\(formatDuration(end - start)))"
        panel.beginSheetModal(for: w) { resp in
            guard resp == .OK, let url = panel.url else { return }
            self.showToast("Bouncing…")
            self.offlineGraph(for: p) { graph in
                let buffer = PlaybackEngine.bounce(graph: graph, from: start, to: end)
                do {
                    try AudioFileIO.write(buffer, to: url, kind: url.pathExtension.lowercased().hasPrefix("aif") ? .aiff : .wav)
                    DispatchQueue.main.async { self.showToast("Bounced \(url.lastPathComponent)") }
                } catch {
                    DispatchQueue.main.async { self.fail("Bounce Failed", error) }
                }
            }
        }
    }

    /// Bounces the loop (or arrangement) back into the library as a new sample.
    func bounceToLibrary() {
        let p = project
        let start = p.loop.enabled ? p.loop.start : 0
        let end = p.loop.enabled ? p.loop.end : p.contentEnd
        guard end > start else { return }
        offlineGraph(for: p) { graph in
            let buffer = PlaybackEngine.bounce(graph: graph, from: start, to: end)
            buffer.preparePeaks()
            DispatchQueue.main.async {
                self.addSample(buffer, name: "Bounce", origin: "Bounced from arrangement")
                self.showToast("Bounced \(formatDuration(end - start)) to Library")
            }
        }
    }

    /// Builds a render graph for offline use on a background queue. Pitch-preserving
    /// stretches that aren't cached yet are rendered synchronously, so a bounce never
    /// falls back to varispeed.
    func offlineGraph(for p: Project, _ body: @escaping (RenderGraph) -> Void) {
        var cached: [UUID: SampleBuffer] = [:]
        for clip in p.tracks.flatMap(\.clips) where clip.isStretched && clip.preservePitch {
            if let s = p.sample(clip.sampleID), let b = stretchCache.cached(clip, sample: s) { cached[clip.id] = b }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let graph = RenderGraph(project: p) { clip in
                if let b = cached[clip.id] { return b }
                guard let s = p.sample(clip.sampleID) else { return nil }
                return StretchCache.renderNow(clip, sample: s)
            }
            body(graph)
        }
    }

    // MARK: - Destructive sample edits (each is one undo step)

    /// - Parameters:
    ///   - removed: source ranges deleted by the edit (nil when the length is unchanged).
    ///   - inserted: frames inserted by the edit, in coordinates after `removed` was taken out.
    private func applyEdit(_ name: String, removed: [Range<Int>]? = nil, inserted: (at: Int, count: Int)? = nil,
                           _ transform: (Sample) -> (SampleBuffer, [Int])?) {
        guard let id = editor.sampleID, let s = project.sample(id), let (buffer, slices) = transform(s) else { return }
        DispatchQueue.global(qos: .userInitiated).async { buffer.preparePeaks() }
        perform(name) { p in
            guard let i = p.sampleIndex(id) else { return }
            p.samples[i].buffer = buffer
            p.samples[i].slices = slices.filter { $0 > 0 && $0 < buffer.frameCount }.sorted()
            if let removed = removed { p.remapClips(forSample: id, removed: removed) }
            if let ins = inserted { p.remapClips(forSample: id, inserted: ins.count, at: ins.at) }
        }
    }

    var editRange: Range<Int>? {
        guard let r = editor.selection, r.count > 0 else { return nil }
        return r
    }

    func editTrimToSelection() {
        guard let r = editRange else { return }
        let total = editorSample?.frameCount ?? 0
        applyEdit("Trim", removed: [0..<r.lowerBound, r.upperBound..<total]) { s in
            (s.buffer.copy(range: r), s.slices.filter { r.contains($0) }.map { $0 - r.lowerBound })
        }
        editor.selection = nil
        if let s = editorSample { editor.fit(frames: s.frameCount) }
    }

    func editDeleteSelection(name: String = "Delete Audio") {
        guard let r = editRange else { return }
        applyEdit(name, removed: [r]) { s in
            (s.buffer.deleting(range: r),
             s.slices.filter { !r.contains($0) }.map { $0 >= r.upperBound ? $0 - r.count : $0 })
        }
        editor.selection = r.lowerBound..<r.lowerBound
    }

    func editSilence() { applyEdit("Silence") { ($0.buffer.silenced(range: editRange), $0.slices) } }
    func editReverse() { applyEdit("Reverse") { ($0.buffer.reversed(range: editRange), $0.slices) } }
    func editNormalize() { applyEdit("Normalize") { ($0.buffer.normalized(range: editRange), $0.slices) } }
    func editFadeIn() { applyEdit("Fade In") { ($0.buffer.faded(in: true, range: editRange), $0.slices) } }
    func editFadeOut() { applyEdit("Fade Out") { ($0.buffer.faded(in: false, range: editRange), $0.slices) } }
    func editGain(_ db: Float) {
        applyEdit(String(format: "Gain %+.0f dB", db)) { ($0.buffer.gained(powf(10, db / 20), range: editRange), $0.slices) }
    }

    func editSelectionToNewSample() {
        guard let s = editorSample, let r = editRange else { return }
        addSample(s.buffer.copy(range: r), name: s.name + " Cut", origin: "Region of \(s.name)")
    }

    func editSelectAll() {
        guard let s = editorSample else { return }
        editor.selection = 0..<s.frameCount
    }

    // MARK: - Clipboard

    func editCopy() {
        guard let s = editorSample, let r = editRange else { return }
        AudioClipboard.buffer = s.buffer.copy(range: r)
        showToast("Copied \(formatDuration(Double(r.count) / AudioSpec.sampleRate))")
    }

    func editCut() {
        guard editRange != nil else { return }
        editCopy()
        editDeleteSelection(name: "Cut")
    }

    /// Pastes at the cursor, replacing the selected audio if there is any.
    func editPaste() {
        guard let audio = AudioClipboard.buffer, audio.frameCount > 0 else { return }
        editSplice(audio, name: "Paste", replacing: true)
        showToast("Pasted \(formatDuration(audio.duration))")
    }

    /// Inserts silence at the cursor (or before the selection, pushing it later).
    func editInsertSilence(seconds: Double) {
        let frames = Int((seconds * AudioSpec.sampleRate).rounded())
        guard frames > 0 else { return }
        editSplice(SampleBuffer(frameCount: frames), name: "Insert Silence", replacing: false)
    }

    /// Musical Insert Silence lengths, resolved against the project tempo when chosen.
    static let silenceLengths: [(title: String, seconds: (Project) -> Double)] = [
        ("1 Beat", { $0.secondsPerBeat }), ("1 Bar", { $0.secondsPerBar }), ("1 Second", { _ in 1 }),
    ]

    func newSampleFromClipboard() {
        guard let audio = AudioClipboard.buffer, audio.frameCount > 0 else { return }
        addSample(audio, name: "Clipboard", origin: "Pasted audio")
    }

    /// Splices `audio` in at the selection start and selects it. Clips and slice markers
    /// after the splice move with their audio.
    private func editSplice(_ audio: SampleBuffer, name: String, replacing: Bool) {
        guard let s = editorSample else { return }
        let sel = (editor.selection ?? s.frameCount..<s.frameCount).clamped(to: 0..<s.frameCount)
        let cut = replacing ? sel : sel.lowerBound..<sel.lowerBound
        let at = cut.lowerBound, n = audio.frameCount
        applyEdit(name, removed: cut.isEmpty ? nil : [cut], inserted: (at, n)) { s in
            let slices = s.slices.filter { !cut.contains($0) }
                .map { $0 >= cut.upperBound ? $0 - cut.count : $0 }
                .map { $0 >= at ? $0 + n : $0 }
            return (s.buffer.replacing(range: cut, with: audio), slices)
        }
        editor.selection = at..<(at + n)
        editor.anchor = nil
        if let s = editorSample { editor.reveal(at + n, totalFrames: s.frameCount) }
    }

    // MARK: - Tempo

    /// Detects the tempo of the selection (or the whole sample) in the background.
    func detectTempo() {
        guard let s = editorSample else { return }
        let range = editRange, buffer = s.buffer
        let signature = (project.beatsPerBar, project.beatUnit)
        DispatchQueue.global(qos: .userInitiated).async {
            let estimate = TransientDetector.estimateTempo(buffer: buffer, range: range,
                                                           beatsPerBar: signature.0, beatUnit: signature.1)
            DispatchQueue.main.async {
                guard let e = estimate else {
                    self.editor.tempo = nil
                    self.showToast("No steady beat found")
                    return
                }
                self.editor.tempo = DetectedTempo(bufferID: buffer.id, range: range, estimate: e)
            }
        }
    }

    /// The detected tempo, while it still describes the sample in the editor.
    var editorTempo: DetectedTempo? {
        guard let t = editor.tempo, let s = editorSample, t.bufferID == s.buffer.id else { return nil }
        return t
    }

    /// ½× / 2×: the same audio read in half or double time.
    func scaleDetectedTempo(by factor: Double) {
        guard var t = editorTempo else { return }
        let scaled = t.estimate.scaled(by: factor)
        guard (30...300).contains(scaled.bpm) else { return }
        t.estimate = scaled
        editor.tempo = t
    }

    func setProjectTempoFromSample() {
        guard let t = editorTempo else { showToast("Detect the sample’s tempo first"); return }
        setBPM(t.estimate.bpm)
        showToast(String(format: "Project tempo %.2f BPM", project.bpm))
    }

    /// Stretches the opened clip (or every clip of this sample) so the sample's detected
    /// tempo plays at the project tempo.
    func matchClipsToProjectTempo() {
        guard let t = editorTempo, let s = editorSample else { showToast("Detect the sample’s tempo first"); return }
        let ratio = min(16, max(0.0625, t.estimate.bpm / project.bpm))
        let targets = editor.clipID.map { [$0] } ?? project.tracks.flatMap(\.clips).filter { $0.sampleID == s.id }.map(\.id)
        guard !targets.isEmpty else { showToast("No clips use this sample"); return }
        perform("Match Tempo") { p in
            for id in targets { p.updateClip(id) { $0.stretch = ratio } }
        }
        showToast(String(format: "Stretched %d clip%@ to %.1f BPM", targets.count, targets.count == 1 ? "" : "s", project.bpm))
    }

    // MARK: - Keyboard navigation

    /// The first mark strictly beyond `frame` in `direction` (sorted `marks`), nil past the last.
    static func mark(after frame: Int, direction: Int, in marks: [Int]) -> Int? {
        direction > 0 ? marks.first { $0 > frame } : marks.last { $0 < frame }
    }

    /// The selection after moving its active edge to `target`, and the new anchor. A cursor
    /// (empty selection) grows from where it is.
    static func extend(_ sel: Range<Int>, activeIsStart: Bool, to target: Int) -> (Range<Int>, anchor: Int) {
        let fixed = activeIsStart ? sel.upperBound : sel.lowerBound
        return (min(fixed, target)..<max(fixed, target), fixed)
    }

    /// ← / →: jump to the previous / next slice boundary; ⇧ extends the selection.
    func editorStepSlice(_ direction: Int, extend: Bool) {
        guard let s = editorSample else { return }
        editorJump(direction, extend: extend, marks: [0] + s.slices + [s.frameCount], sample: s)
    }

    /// Tab / ⇧Tab: jump to the next / previous transient.
    func editorStepTransient(_ direction: Int) {
        guard let s = editorSample else { return }
        let onsets = cachedTransients(s)
        guard !onsets.isEmpty else { showToast("No transients found — raise sensitivity"); return }
        editorJump(direction, extend: false, marks: onsets, sample: s)
    }

    private func editorJump(_ direction: Int, extend: Bool, marks: [Int], sample s: Sample) {
        guard let sel = editor.selection else {
            // No cursor yet: start from the edge of the view.
            let from = direction > 0 ? Int(editor.scrollFrame) - 1 : Int(editor.frame(editor.width)) + 1
            if let t = Self.mark(after: from, direction: direction, in: marks) { placeEditorCursor(t, sample: s) }
            return
        }
        if extend {
            let startActive = editor.activeEdgeIsStart
            let edge = startActive ? sel.lowerBound : sel.upperBound
            guard let t = Self.mark(after: edge, direction: direction, in: marks) else { return }
            let (range, anchor) = Self.extend(sel, activeIsStart: startActive, to: t)
            editor.selection = range
            editor.anchor = anchor
            editor.reveal(t, totalFrames: s.frameCount)
        } else {
            let from = direction > 0 ? sel.upperBound : sel.lowerBound
            guard let t = Self.mark(after: from, direction: direction, in: marks) else { return }
            placeEditorCursor(t, sample: s)
        }
    }

    /// [ / ]: move the active selection edge (or the cursor) to the previous / next zero crossing.
    func editorNudgeEdgeToZeroCrossing(_ direction: Int) {
        guard let s = editorSample, let sel = editor.selection else { return }
        let startActive = editor.activeEdgeIsStart
        let edge = startActive ? sel.lowerBound : sel.upperBound
        guard let z = s.buffer.zeroCrossing(from: edge, forward: direction > 0) else { return }
        if sel.isEmpty {
            placeEditorCursor(z, sample: s)
        } else {
            let (range, anchor) = Self.extend(sel, activeIsStart: startActive, to: z)
            editor.selection = range
            editor.anchor = anchor
            editor.reveal(z, totalFrames: s.frameCount)
        }
    }

    /// Moves the cursor; a running one-shot preview restarts from it, as a click does.
    private func placeEditorCursor(_ frame: Int, sample s: Sample) {
        editor.selection = frame..<frame
        editor.anchor = nil
        editor.reveal(frame, totalFrames: s.frameCount)
        if clock.previewFrame != nil && !isLoopPreviewing && frame < s.frameCount {
            previewSample(s.id, range: frame..<s.frameCount, fromEditor: true)
        }
    }

    private func cachedTransients(_ s: Sample) -> [Int] {
        if let c = editor.transientCache, c.bufferID == s.buffer.id, c.sensitivity == editor.sensitivity { return c.onsets }
        let onsets = TransientDetector.detect(in: s.buffer, sensitivity: editor.sensitivity)
        editor.transientCache = (s.buffer.id, editor.sensitivity, onsets)
        return onsets
    }

    // MARK: - Slicing

    func setSlices(_ slices: [Int], name: String = "Edit Slices") {
        guard let id = editor.sampleID else { return }
        change(name) { p in
            guard let i = p.sampleIndex(id) else { return }
            let n = p.samples[i].frameCount
            p.samples[i].slices = Array(Set(slices.filter { $0 > 0 && $0 < n })).sorted()
        }
    }

    func addSliceMarkerAtCursor() {
        guard let s = editorSample else { return }
        var frame: Int
        if let pv = clock.previewFrame { frame = pv } else if let sel = editor.selection { frame = sel.count > 0 ? sel.upperBound : sel.lowerBound }
        else { frame = Int(editor.frame(editor.width / 2)) }
        if editor.snapToZeroCrossings { frame = s.buffer.nearestZeroCrossing(to: frame) }
        setSlices(s.slices + [frame], name: "Add Slice")
    }

    func autoSlice() {
        guard let s = editorSample else { return }
        let onsets = TransientDetector.detect(in: s.buffer, range: editRange, sensitivity: editor.sensitivity)
        let keep = editRange.map { r in s.slices.filter { !r.contains($0) } } ?? []
        setSlices(keep + onsets, name: "Auto Slice")
        showToast(onsets.isEmpty ? "No transients found — raise sensitivity" : "Found \(onsets.count) transients")
    }

    func sliceEqually(_ parts: Int) {
        guard let s = editorSample, parts > 1 else { return }
        let r = editRange ?? 0..<s.frameCount
        let step = Double(r.count) / Double(parts)
        var marks = (1..<parts).map { r.lowerBound + Int((Double($0) * step).rounded()) }
        if editor.snapToZeroCrossings { marks = marks.map { s.buffer.nearestZeroCrossing(to: $0, radius: 240) } }
        let keep = editRange.map { rr in s.slices.filter { !rr.contains($0) } } ?? []
        setSlices(keep + marks + (editRange.map { [$0.lowerBound, $0.upperBound] } ?? []), name: "Slice ÷\(parts)")
    }

    /// Slices on the beat grid of the project tempo (e.g. 1/16 notes).
    func sliceByGrid(beats: Double) {
        guard let s = editorSample else { return }
        let step = beats * project.secondsPerBeat * AudioSpec.sampleRate
        guard step > 64 else { return }
        var marks: [Int] = []
        var f = step
        while f < Double(s.frameCount) { marks.append(Int(f.rounded())); f += step }
        if editor.snapToZeroCrossings { marks = marks.map { s.buffer.nearestZeroCrossing(to: $0, radius: 240) } }
        setSlices(marks, name: "Slice to Grid")
    }

    func clearSlices() { setSlices([], name: "Clear Slices") }

    /// Lays the slices out sequentially on a new track — the classic “chop to timeline”.
    func slicesToTrack() {
        guard let s = editorSample else { return }
        let ranges = s.sliceRanges
        guard !ranges.isEmpty else { return }
        var t = Track(name: "\(s.name) Slices", colorIndex: nextTrackColor())
        var cursor = project.loop.enabled ? project.loop.start : 0
        for (i, r) in ranges.enumerated() {
            t.clips.append(Clip(sampleID: s.id, name: "\(s.name) · \(i + 1)", start: cursor,
                                sourceStart: r.lowerBound, sourceLength: r.count))
            cursor += Double(r.count) / AudioSpec.sampleRate
        }
        let newTrack = t
        perform("Slices to Track") { $0.tracks.append(newTrack) }
        selectedTrackID = t.id
        selectedClips = Set(t.clips.map(\.id))
        showToast("Placed \(ranges.count) slices on a new track")
    }

    func slicesToLibrary() {
        guard let s = editorSample else { return }
        let ranges = s.sliceRanges
        guard ranges.count > 1 else { return }
        let base = project.samples.count
        let newSamples = ranges.enumerated().map { i, r in
            Sample(name: "\(s.name) · \(i + 1)", buffer: s.buffer.copy(range: r),
                   colorIndex: (base + i) % Theme.trackColors.count, origin: "Slice \(i + 1) of \(s.name)")
        }
        DispatchQueue.global(qos: .userInitiated).async { newSamples.forEach { $0.buffer.preparePeaks() } }
        perform("Slices to Library") { $0.samples += newSamples }
        showToast("Added \(newSamples.count) slices to the Library")
    }

    func selectSlice(containing frame: Int) {
        guard let s = editorSample else { return }
        if let r = s.sliceRanges.first(where: { $0.contains(frame) }) { editor.selection = r }
    }

    /// Places a single slice/region at the playhead on the selected (or new) track.
    func placeEditorSelection() {
        guard let s = editorSample else { return }
        let r = editRange ?? 0..<s.frameCount
        placeSample(s.id, onTrack: selectedTrackID, at: snapTime(positionSeconds), range: r)
    }

    // MARK: - Preview

    func previewSample(_ id: UUID, range: Range<Int>? = nil, loop: Bool = false, fromEditor: Bool = false) {
        guard let s = project.sample(id) else { return }
        let r = (range ?? 0..<s.frameCount).clamped(to: 0..<s.frameCount)
        guard r.count > 0 else { return }
        previewContext = (id, fromEditor)
        ensureEngineRunning()
        engine.preview(PreviewRequest(buffer: s.buffer, range: r, loop: loop))
        retuneTimer()
    }

    func previewEditorSelection() {
        guard let s = editorSample else { return }
        if clock.previewFrame != nil { stopPreview(); return }
        let r = editRange ?? (editor.selection.map { $0.lowerBound..<s.frameCount } ?? 0..<s.frameCount)
        previewSample(s.id, range: r, loop: editor.loopPreview && editRange != nil, fromEditor: true)
    }

    func stopPreview() {
        previewContext = nil
        engine.preview(nil)
    }

    /// True while an editor preview is looping — selection changes then retarget it.
    var isLoopPreviewing: Bool {
        engine.previewPosition != nil && editor.loopPreview && previewContext?.fromEditor == true
    }

    /// Retargets a running editor preview to the new selection without restarting it.
    func syncLivePreview(selection: Range<Int>?, loop: Bool) {
        guard engine.previewPosition != nil, let ctx = previewContext, ctx.fromEditor,
              let s = editorSample, s.id == ctx.sampleID else { return }
        // Ignore cursor clicks and the first pixels of a drag; keep the current region.
        guard let r = selection?.clamped(to: 0..<s.frameCount), r.count >= 256 else { return }
        engine.updatePreviewRegion(r, loop: loop, buffer: s.buffer)
    }

    func editorZoomToFit() {
        guard let s = editorSample else { return }
        editor.fit(frames: s.frameCount)
    }

    func editorZoomToSelection() {
        guard let r = editRange else { return }
        editor.framesPerPixel = max(0.02, Double(r.count) / Double(max(100, editor.width)) * 1.1)
        editor.scrollFrame = max(0, Double(r.lowerBound) - Double(r.count) * 0.05)
    }
}

/// App-wide audio clipboard for the sample editor, so audio can be pasted across projects.
/// Buffers are immutable, so holding one shares it safely.
enum AudioClipboard {
    static var buffer: SampleBuffer?
}

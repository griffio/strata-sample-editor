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
            let graph = RenderGraph(project: p) { clip in
                guard let s = p.sample(clip.sampleID) else { return nil }
                return self.stretchCache.lookup(clip, sample: s)
            }
            DispatchQueue.global(qos: .userInitiated).async {
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
        let graph = RenderGraph(project: p) { clip in
            guard let s = p.sample(clip.sampleID) else { return nil }
            return self.stretchCache.lookup(clip, sample: s)
        }
        let buffer = PlaybackEngine.bounce(graph: graph, from: start, to: end)
        addSample(buffer, name: "Bounce", origin: "Bounced from arrangement")
        showToast("Bounced \(formatDuration(end - start)) to Library")
    }

    // MARK: - Destructive sample edits (each is one undo step)

    private func applyEdit(_ name: String, keepsLength: Bool, _ transform: (Sample) -> (SampleBuffer, [Int])?) {
        guard let id = editor.sampleID, let s = project.sample(id), let (buffer, slices) = transform(s) else { return }
        DispatchQueue.global(qos: .userInitiated).async { buffer.preparePeaks() }
        perform(name) { p in
            guard let i = p.sampleIndex(id) else { return }
            p.samples[i].buffer = buffer
            p.samples[i].slices = slices.filter { $0 > 0 && $0 < buffer.frameCount }.sorted()
            if !keepsLength { p.reconcileClips(forSample: id) }
        }
    }

    var editRange: Range<Int>? {
        guard let r = editor.selection, r.count > 0 else { return nil }
        return r
    }

    func editTrimToSelection() {
        guard let r = editRange else { return }
        applyEdit("Trim", keepsLength: false) { s in
            (s.buffer.copy(range: r), s.slices.filter { r.contains($0) }.map { $0 - r.lowerBound })
        }
        editor.selection = nil
        if let s = editorSample { editor.fit(frames: s.frameCount) }
    }

    func editDeleteSelection() {
        guard let r = editRange else { return }
        applyEdit("Delete Audio", keepsLength: false) { s in
            (s.buffer.deleting(range: r),
             s.slices.filter { !r.contains($0) }.map { $0 >= r.upperBound ? $0 - r.count : $0 })
        }
        editor.selection = r.lowerBound..<r.lowerBound
    }

    func editSilence() { applyEdit("Silence", keepsLength: true) { ($0.buffer.silenced(range: editRange), $0.slices) } }
    func editReverse() { applyEdit("Reverse", keepsLength: true) { ($0.buffer.reversed(range: editRange), $0.slices) } }
    func editNormalize() { applyEdit("Normalize", keepsLength: true) { ($0.buffer.normalized(range: editRange), $0.slices) } }
    func editFadeIn() { applyEdit("Fade In", keepsLength: true) { ($0.buffer.faded(in: true, range: editRange), $0.slices) } }
    func editFadeOut() { applyEdit("Fade Out", keepsLength: true) { ($0.buffer.faded(in: false, range: editRange), $0.slices) } }
    func editGain(_ db: Float) {
        applyEdit(String(format: "Gain %+.0f dB", db), keepsLength: true) { ($0.buffer.gained(powf(10, db / 20), range: editRange), $0.slices) }
    }

    func editSelectionToNewSample() {
        guard let s = editorSample, let r = editRange else { return }
        addSample(s.buffer.copy(range: r), name: s.name + " Cut", origin: "Region of \(s.name)")
    }

    func editSelectAll() {
        guard let s = editorSample else { return }
        editor.selection = 0..<s.frameCount
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

    func previewSample(_ id: UUID, range: Range<Int>? = nil, loop: Bool = false) {
        guard let s = project.sample(id) else { return }
        let r = (range ?? 0..<s.frameCount).clamped(to: 0..<s.frameCount)
        guard r.count > 0 else { return }
        engine.preview(PreviewRequest(buffer: s.buffer, range: r, loop: loop))
    }

    func previewEditorSelection() {
        guard let s = editorSample else { return }
        if clock.previewFrame != nil { stopPreview(); return }
        let r = editRange ?? (editor.selection.map { $0.lowerBound..<s.frameCount } ?? 0..<s.frameCount)
        previewSample(s.id, range: r, loop: editor.loopPreview && editRange != nil)
    }

    func stopPreview() { engine.preview(nil) }

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

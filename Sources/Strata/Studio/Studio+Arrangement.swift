import Foundation
import AppKit

extension Studio {
    // MARK: - Tracks

    @discardableResult
    func addTrack(name: String? = nil, select: Bool = true) -> UUID {
        let color = nextTrackColor()
        let track = Track(name: name ?? "Track \(project.tracks.count + 1)", colorIndex: color)
        perform("New Track") { $0.tracks.append(track) }
        if select { selectedTrackID = track.id }
        return track.id
    }

    func nextTrackColor() -> Int {
        let used = project.tracks.map(\.colorIndex)
        for i in 0..<Theme.trackColors.count where !used.contains(i) { return i }
        return project.tracks.count % Theme.trackColors.count
    }

    func deleteTrack(_ id: UUID) {
        perform("Delete Track") { $0.tracks.removeAll { $0.id == id } }
        if selectedTrackID == id { selectedTrackID = project.tracks.first?.id }
        validateSelection()
    }

    func duplicateTrack(_ id: UUID) {
        guard let idx = project.trackIndex(id) else { return }
        var copy = project.tracks[idx]
        copy.id = UUID()
        copy.name += " Copy"
        copy.armed = false
        copy.clips = copy.clips.map { var c = $0; c.id = UUID(); return c }
        perform("Duplicate Track") { $0.tracks.insert(copy, at: idx + 1) }
    }

    func moveTrack(_ id: UUID, by delta: Int) {
        guard let idx = project.trackIndex(id) else { return }
        let target = idx + delta
        guard target >= 0, target < project.tracks.count else { return }
        perform("Move Track") { $0.tracks.swapAt(idx, target) }
    }

    func updateTrack(_ id: UUID, _ name: String, _ body: @escaping (inout Track) -> Void) {
        change(name) { p in
            if let i = p.trackIndex(id) { body(&p.tracks[i]) }
        }
    }

    func toggleArm(_ id: UUID) {
        let arm = !(project.tracks.first { $0.id == id }?.armed ?? false)
        perform(arm ? "Arm Track" : "Disarm Track") { p in
            for i in p.tracks.indices { p.tracks[i].armed = p.tracks[i].id == id ? arm : false }
        }
        if arm, case .none = capture.source {
            showToast("Choose an input source in the sidebar to record")
        }
    }

    // MARK: - Clip creation

    /// Places a sample on the timeline. A nil track creates a new one.
    @discardableResult
    func placeSample(_ sampleID: UUID, onTrack trackID: UUID?, at time: Double, range: Range<Int>? = nil) -> UUID? {
        guard let sample = project.sample(sampleID) else { return nil }
        let r = (range ?? 0..<sample.frameCount).clamped(to: 0..<sample.frameCount)
        guard r.count > 0 else { return nil }
        let clip = Clip(sampleID: sampleID, name: sample.name, start: max(0, time),
                        sourceStart: r.lowerBound, sourceLength: r.count)
        var newTrack: Track?
        if trackID == nil || project.trackIndex(trackID!) == nil {
            newTrack = Track(name: sample.name, colorIndex: sample.colorIndex)
        }
        perform("Add Clip") { p in
            if var t = newTrack {
                t.clips.append(clip)
                p.tracks.append(t)
            } else if let i = p.trackIndex(trackID!) {
                p.tracks[i].clips.append(clip)
                p.tracks[i].sortClips()
            }
        }
        if let t = newTrack { selectedTrackID = t.id } else { selectedTrackID = trackID }
        selectedClips = [clip.id]
        return clip.id
    }

    // MARK: - Selection

    func selectClip(_ id: UUID, extend: Bool) {
        if extend {
            if selectedClips.contains(id) { selectedClips.remove(id) } else { selectedClips.insert(id) }
        } else if !selectedClips.contains(id) {
            selectedClips = [id]
        }
        if let loc = project.locateClip(id) { selectedTrackID = project.tracks[loc.track].id }
        focus = .arrangement
    }

    func selectAllClips() {
        selectedClips = Set(project.tracks.flatMap { $0.clips.map(\.id) })
    }

    var selectedClipValues: [Clip] {
        project.tracks.flatMap(\.clips).filter { selectedClips.contains($0.id) }
    }

    // MARK: - Clip editing

    func deleteSelectedClips() {
        guard !selectedClips.isEmpty else { return }
        let ids = selectedClips
        perform(ids.count == 1 ? "Delete Clip" : "Delete Clips") { p in
            for t in p.tracks.indices { p.tracks[t].clips.removeAll { ids.contains($0.id) } }
        }
        selectedClips = []
        validateSelection()
    }

    func duplicateSelectedClips() {
        let clips = selectedClipValues
        guard !clips.isEmpty, let start = clips.map(\.start).min(), let end = clips.map(\.end).max() else { return }
        var offset = end - start
        if let step = snap.step(in: project) { offset = ceil(offset / step - 1e-9) * step }
        var newIDs: Set<UUID> = []
        perform("Duplicate") { p in
            for t in p.tracks.indices {
                let copies = p.tracks[t].clips.filter { self.selectedClips.contains($0.id) }.map { c -> Clip in
                    var n = c
                    n.id = UUID()
                    n.start += offset
                    newIDs.insert(n.id)
                    return n
                }
                p.tracks[t].clips += copies
                p.tracks[t].sortClips()
            }
        }
        selectedClips = newIDs
    }

    func repeatSelectedClips(times: Int) {
        for _ in 0..<times { duplicateSelectedClips() }
    }

    /// Splits clips at `time`. Uses the selection, or every clip under the time on the selected track.
    func split(at time: Double, clipIDs: Set<UUID>? = nil) {
        let targets: Set<UUID>
        if let ids = clipIDs { targets = ids } else if !selectedClips.isEmpty {
            targets = selectedClips
        } else if let tid = selectedTrackID, let t = project.tracks.first(where: { $0.id == tid }) {
            targets = Set(t.clips.filter { $0.start < time && $0.end > time }.map(\.id))
        } else {
            targets = []
        }
        var created: Set<UUID> = []
        var count = 0
        perform("Split") { p in
            for t in p.tracks.indices {
                var out: [Clip] = []
                for c in p.tracks[t].clips {
                    guard targets.contains(c.id), time > c.start + 0.002, time < c.end - 0.002 else { out.append(c); continue }
                    let splitSrc = Int(c.sourceFrame(atTimelineTime: time).rounded())
                    var left = c, right = c
                    left.sourceLength = splitSrc - c.sourceStart
                    left.fadeOut = 0
                    right.id = UUID()
                    right.start = time
                    right.sourceStart = splitSrc
                    right.sourceLength = c.sourceStart + c.sourceLength - splitSrc
                    right.fadeIn = 0
                    guard left.sourceLength > 16, right.sourceLength > 16 else { out.append(c); continue }
                    out += [left, right]
                    created.insert(right.id)
                    count += 1
                }
                p.tracks[t].clips = out
            }
        }
        if count > 0 {
            selectedClips = selectedClips.union(created)
            showToast(count == 1 ? "Split clip" : "Split \(count) clips")
        }
    }

    func splitAtPlayhead() {
        if focus == .editor, editor.sampleID != nil {
            addSliceMarkerAtCursor()
        } else {
            split(at: positionSeconds)
        }
    }

    func nudgeSelection(_ direction: Double, fine: Bool) {
        guard !selectedClips.isEmpty else {
            seek(to: snapTime(positionSeconds + direction * (snap.step(in: project) ?? project.secondsPerBeat), mode: .nearest))
            return
        }
        let step = fine ? 0.001 : (snap.step(in: project) ?? project.secondsPerBeat / 4)
        perform("Nudge") { p in
            for t in p.tracks.indices {
                for c in p.tracks[t].clips.indices where self.selectedClips.contains(p.tracks[t].clips[c].id) {
                    p.tracks[t].clips[c].start = max(0, p.tracks[t].clips[c].start + direction * step)
                }
                p.tracks[t].sortClips()
            }
        }
    }

    func quantizeSelectedClips() {
        perform("Quantize") { p in
            for t in p.tracks.indices {
                for c in p.tracks[t].clips.indices where self.selectedClips.contains(p.tracks[t].clips[c].id) {
                    p.tracks[t].clips[c].start = max(0, self.snapTime(p.tracks[t].clips[c].start))
                }
                p.tracks[t].sortClips()
            }
        }
    }

    func updateClip(_ id: UUID, _ name: String, _ body: @escaping (inout Clip) -> Void) {
        change(name) { $0.updateClip(id, body) }
    }

    func updateSelectedClips(_ name: String, _ body: @escaping (inout Clip) -> Void) {
        let ids = selectedClips
        change(name) { p in ids.forEach { p.updateClip($0, body) } }
    }

    /// Stretches clips so they last exactly `bars` bars at the project tempo.
    func fitSelectedClips(toBars bars: Double) {
        let target = project.bars(bars)
        updateSelectedClips("Fit to \(bars.formatted()) Bars") { c in
            c.stretch = min(16, max(0.0625, target / c.sourceDuration))
        }
    }

    func resetStretch() {
        updateSelectedClips("Reset Stretch") { $0.stretch = 1 }
    }

    /// Splits each selected clip at the transients found inside its source region.
    func sliceSelectedClipsAtTransients() {
        var total = 0
        for id in selectedClips {
            guard let clip = project.clip(id), let sample = project.sample(clip.sampleID) else { continue }
            let onsets = TransientDetector.detect(in: sample.buffer, range: clip.sourceStart..<(clip.sourceStart + clip.sourceLength),
                                                  sensitivity: editor.sensitivity)
            let times = onsets.map { clip.start + Double($0 - clip.sourceStart) / AudioSpec.sampleRate * clip.stretch }
            var currentIDs: Set<UUID> = [id]
            for t in times.sorted() {
                split(at: t, clipIDs: currentIDs)
                currentIDs = Set(project.tracks.flatMap(\.clips).filter { $0.sampleID == clip.sampleID && $0.start >= clip.start - 0.001 && $0.end <= clip.end + 0.001 }.map(\.id))
                total += 1
            }
        }
        showToast(total == 0 ? "No transients found" : "Sliced at \(total) transients")
    }

    func renameClip(_ id: UUID, to name: String) {
        updateClip(id, "Rename Clip") { $0.name = name }
    }

    func openClipInEditor(_ id: UUID) {
        guard let clip = project.clip(id) else { return }
        openInEditor(sampleID: clip.sampleID, clipID: id)
    }

    func clipColor(_ clip: Clip, track: Track) -> NSColor {
        Theme.trackNSColor(track.colorIndex)
    }
}

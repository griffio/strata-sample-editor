import Foundation

/// A recorded or imported piece of audio living in the project library.
struct Sample: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var buffer: SampleBuffer
    /// Slice marker positions in frames, always sorted and inside (0, frameCount).
    var slices: [Int] = []
    var colorIndex: Int = 0
    var origin: String = ""
    var createdAt = Date()

    var frameCount: Int { buffer.frameCount }
    var duration: Double { buffer.duration }

    static func == (a: Sample, b: Sample) -> Bool {
        a.id == b.id && a.name == b.name && a.buffer === b.buffer && a.slices == b.slices
            && a.colorIndex == b.colorIndex && a.origin == b.origin
    }

    /// Slice boundaries including the sample start and end.
    var sliceRanges: [Range<Int>] {
        let edges = [0] + slices.filter { $0 > 0 && $0 < frameCount } + [frameCount]
        return zip(edges, edges.dropFirst()).compactMap { $0 < $1 ? $0..<$1 : nil }
    }
}

/// A placement of (part of) a sample on a track.
struct Clip: Identifiable, Equatable, Codable {
    var id = UUID()
    var sampleID: UUID
    var name: String
    /// Timeline position in seconds.
    var start: Double
    var sourceStart: Int
    var sourceLength: Int
    /// Timeline duration ÷ source duration. 2 = half speed / twice as long.
    var stretch: Double = 1
    /// When stretched: true keeps pitch (offline time-stretch), false is tape-style varispeed.
    var preservePitch: Bool = true
    /// Pitch-preserving algorithm: rhythm-tight WSOLA or spectral (phase vocoder).
    var stretchMode: StretchMode = .beats
    var gain: Float = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var muted: Bool = false

    var sourceDuration: Double { Double(sourceLength) / AudioSpec.sampleRate }
    var duration: Double { sourceDuration * stretch }
    var end: Double { start + duration }
    var isStretched: Bool { abs(stretch - 1) > 0.0005 }

    /// Converts a timeline time inside the clip to a source frame.
    func sourceFrame(atTimelineTime t: Double) -> Double {
        Double(sourceStart) + (t - start) / stretch * AudioSpec.sampleRate
    }
}

enum StretchMode: String, Codable, CaseIterable {
    case beats, tonal

    var label: String { self == .beats ? "Beats" : "Tonal" }
    var help: String {
        self == .beats ? "Tight, transient-safe stretching for drums and rhythmic loops"
                       : "Smooth spectral stretching for pads, vocals and sustained sounds"
    }
}

struct Track: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var volume: Float = 0.8
    var pan: Float = 0
    var mute = false
    var solo = false
    var armed = false
    var height: Double = 92
    var clips: [Clip] = []

    mutating func sortClips() { clips.sort { $0.start < $1.start } }
}

struct LoopRegion: Equatable, Codable {
    var start: Double
    var end: Double
    var enabled: Bool
    var length: Double { end - start }
}

struct Project: Equatable {
    var bpm: Double = 120
    var beatsPerBar: Int = 4
    var beatUnit: Int = 4
    var loop = LoopRegion(start: 0, end: 8, enabled: true)
    var tracks: [Track] = []
    var samples: [Sample] = []
    var masterVolume: Float = 0.9
    var metronome = false
    var countIn = false

    // MARK: Musical time

    var secondsPerBeat: Double { 60 / bpm * 4 / Double(beatUnit) }
    var secondsPerBar: Double { secondsPerBeat * Double(beatsPerBar) }

    func bars(_ n: Double) -> Double { n * secondsPerBar }

    var contentEnd: Double {
        tracks.flatMap(\.clips).map(\.end).max() ?? 0
    }

    // MARK: Lookup

    func sample(_ id: UUID) -> Sample? { samples.first { $0.id == id } }
    func sampleIndex(_ id: UUID) -> Int? { samples.firstIndex { $0.id == id } }
    func trackIndex(_ id: UUID) -> Int? { tracks.firstIndex { $0.id == id } }

    func locateClip(_ id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in tracks.enumerated() {
            if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) }
        }
        return nil
    }

    func clip(_ id: UUID) -> Clip? {
        locateClip(id).map { tracks[$0.track].clips[$0.clip] }
    }

    mutating func updateClip(_ id: UUID, _ body: (inout Clip) -> Void) {
        guard let loc = locateClip(id) else { return }
        body(&tracks[loc.track].clips[loc.clip])
    }

    var anySolo: Bool { tracks.contains { $0.solo } }

    func isAudible(_ track: Track) -> Bool {
        !track.mute && (!anySolo || track.solo)
    }

    /// Re-targets clips after frames were removed from a sample, so every clip keeps
    /// playing the same audio (and stays where it was on the timeline).
    mutating func remapClips(forSample id: UUID, removed: [Range<Int>]) {
        let cuts = removed.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        guard !cuts.isEmpty else { return }
        func removedBefore(_ x: Int) -> Int {
            cuts.reduce(0) { $0 + max(0, min(x, $1.upperBound) - $1.lowerBound) }
        }
        func map(_ x: Int) -> Int { x - removedBefore(x) }
        for t in tracks.indices {
            var kept: [Clip] = []
            for var c in tracks[t].clips {
                guard c.sampleID == id else { kept.append(c); continue }
                let oldStart = c.sourceStart, oldEnd = c.sourceStart + c.sourceLength
                // Frames lost at the head of the clip move its start later on the timeline.
                var head = oldStart
                while let cut = cuts.first(where: { $0.contains(head) }) { head = cut.upperBound }
                let a = map(head), b = map(oldEnd)
                guard b - a > 16 else { continue }   // the clip's audio is gone
                c.start += Double(head - oldStart) / AudioSpec.sampleRate * c.stretch
                c.sourceStart = a
                c.sourceLength = b - a
                kept.append(c)
            }
            tracks[t].clips = kept
        }
        reconcileClips(forSample: id)
    }

    /// Re-targets clips after `count` frames were inserted at `position`, so every clip keeps
    /// playing the same audio. A clip that spans the insertion point is split around it.
    mutating func remapClips(forSample id: UUID, inserted count: Int, at position: Int) {
        guard count > 0 else { return }
        for t in tracks.indices {
            var kept: [Clip] = []
            for c in tracks[t].clips {
                guard c.sampleID == id else { kept.append(c); continue }
                let end = c.sourceStart + c.sourceLength
                if end <= position { kept.append(c); continue }
                if c.sourceStart >= position {
                    var moved = c
                    moved.sourceStart += count
                    kept.append(moved)
                    continue
                }
                var head = c, tail = c
                head.sourceLength = position - c.sourceStart
                tail.id = UUID()
                tail.start = c.start + Double(head.sourceLength) / AudioSpec.sampleRate * c.stretch
                tail.sourceStart = position + count
                tail.sourceLength = end - position
                // Too short to keep as a clip of its own: the few frames are dropped.
                let keepHead = head.sourceLength > 16, keepTail = tail.sourceLength > 16
                if keepHead && keepTail {
                    head.fadeOut = 0
                    tail.fadeIn = 0
                }
                head.fadeIn = min(head.fadeIn, head.duration)
                tail.fadeOut = min(tail.fadeOut, tail.duration)
                if keepHead { kept.append(head) }
                if keepTail { kept.append(tail) }
            }
            tracks[t].clips = kept
            tracks[t].sortClips()
        }
        reconcileClips(forSample: id)
    }

    /// Keeps clip references valid after a sample's length changed.
    mutating func reconcileClips(forSample id: UUID) {
        guard let s = sample(id) else {
            for t in tracks.indices { tracks[t].clips.removeAll { $0.sampleID == id } }
            return
        }
        for t in tracks.indices {
            for c in tracks[t].clips.indices where tracks[t].clips[c].sampleID == id {
                var clip = tracks[t].clips[c]
                if clip.sourceStart >= s.frameCount { clip.sourceStart = 0 }
                clip.sourceLength = min(clip.sourceLength, s.frameCount - clip.sourceStart)
                if clip.sourceLength <= 0 { clip.sourceStart = 0; clip.sourceLength = s.frameCount }
                tracks[t].clips[c] = clip
            }
        }
    }
}

/// Grid resolution for snapping, expressed in beats.
enum SnapGrid: String, CaseIterable, Identifiable {
    case off, bar, half, beat, eighth, sixteenth, thirtySecond

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .bar: return "Bar"
        case .half: return "1/2"
        case .beat: return "1/4"
        case .eighth: return "1/8"
        case .sixteenth: return "1/16"
        case .thirtySecond: return "1/32"
        }
    }

    /// Grid step in seconds for the project, nil when snapping is off.
    func step(in project: Project) -> Double? {
        let beat = project.secondsPerBeat
        switch self {
        case .off: return nil
        case .bar: return project.secondsPerBar
        case .half: return beat * 2
        case .beat: return beat
        case .eighth: return beat / 2
        case .sixteenth: return beat / 4
        case .thirtySecond: return beat / 8
        }
    }
}

enum EditTool: String, CaseIterable {
    case pointer, blade, stretch

    var symbol: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .blade: return "scissors"
        case .stretch: return "arrow.left.and.right"
        }
    }

    var label: String {
        switch self {
        case .pointer: return "Pointer (V)"
        case .blade: return "Blade (B)"
        case .stretch: return "Stretch (T)"
        }
    }
}

/// Bars.Beats.Sixteenths formatting used by the LCD and inspectors.
struct MusicalTimeFormatter {
    let project: Project

    func components(_ seconds: Double) -> (bar: Int, beat: Int, sixteenth: Int, ticks: Int) {
        let beatsF = seconds / project.secondsPerBeat
        let negative = beatsF < 0
        let totalTicks = Int((abs(beatsF) * 960).rounded(.down))
        let beatsPerBar = project.beatsPerBar
        var beats = totalTicks / 960
        let ticksInBeat = totalTicks % 960
        if negative { beats = -beats - 1 }
        let bar = Int(floor(Double(beats) / Double(beatsPerBar)))
        let beat = ((beats % beatsPerBar) + beatsPerBar) % beatsPerBar
        return (bar + 1, beat + 1, ticksInBeat / 240 + 1, ticksInBeat % 240)
    }

    func string(_ seconds: Double) -> String {
        let c = components(seconds)
        return "\(c.bar).\(c.beat).\(c.sixteenth)"
    }
}

func formatClock(_ seconds: Double, millis: Bool = true) -> String {
    let s = max(0, seconds)
    let m = Int(s) / 60
    let sec = Int(s) % 60
    if millis {
        let ms = Int((s - floor(s)) * 1000)
        return String(format: "%02d:%02d.%03d", m, sec, ms)
    }
    return String(format: "%d:%02d", m, sec)
}

func formatDuration(_ seconds: Double) -> String {
    if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
    if seconds < 60 { return String(format: "%.2f s", seconds) }
    return formatClock(seconds, millis: false)
}

func dbString(_ linear: Float) -> String {
    guard linear > 0.00001 else { return "-∞ dB" }
    let db = 20 * log10f(linear)
    return String(format: "%+.1f dB", db)
}

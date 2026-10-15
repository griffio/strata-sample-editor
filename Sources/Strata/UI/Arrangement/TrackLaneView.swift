import SwiftUI
import AppKit

/// Registry so a drag that starts in one lane can find the lane under the cursor.
final class LaneRegistry {
    private var lanes: [UUID: WeakLane] = [:]
    private struct WeakLane { weak var view: TrackLaneNSView? }

    func register(_ v: TrackLaneNSView, id: UUID) { lanes[id] = WeakLane(view: v) }
    func unregister(_ id: UUID, view: TrackLaneNSView) {
        if lanes[id]?.view === view { lanes[id] = nil }
    }

    func trackID(atWindowPoint p: NSPoint) -> UUID? {
        for (id, lane) in lanes {
            guard let v = lane.view, v.window != nil else { continue }
            let r = v.convert(v.bounds, to: nil)
            if p.y >= r.minY && p.y <= r.maxY { return id }
        }
        return nil
    }
}

struct TrackLaneView: NSViewRepresentable {
    @ObservedObject var studio: Studio
    @ObservedObject var viewport: TimelineViewport
    let track: Track
    let index: Int

    func makeNSView(context: Context) -> TrackLaneNSView {
        let v = TrackLaneNSView(studio: studio, trackID: track.id)
        v.update(track: track, index: index)
        return v
    }

    func updateNSView(_ v: TrackLaneNSView, context: Context) {
        v.update(track: track, index: index)
    }

    static func dismantleNSView(_ v: TrackLaneNSView, coordinator: ()) {
        v.teardown()
    }
}

final class TrackLaneNSView: NSView {
    private unowned let studio: Studio
    private(set) var trackID: UUID
    private var track: Track
    private var index = 0

    // Interaction state
    private enum Zone: Equatable { case none, body, header, trimLeft, trimRight, stretchLeft, stretchRight, fadeIn, fadeOut }
    private struct DragOrigin { var trackIndex: Int; var clip: Clip }
    private var dragZone: Zone = .none
    private var dragClipID: UUID?
    private var dragDownPoint: NSPoint = .zero
    private var dragDownTime: Double = 0
    private var origins: [UUID: DragOrigin] = [:]
    private var didDrag = false
    private var optionDuplicated = false
    private var clickedSelectedID: UUID?
    private var rubberBand: NSRect?
    private var hoverClipID: UUID?
    private var hoverZone: Zone = .none
    private var dropTime: Double?
    private var trackingArea: NSTrackingArea?

    static let registry = LaneRegistry()
    private let headerH: CGFloat = 15
    private let edge: CGFloat = 7

    init(studio: Studio, trackID: UUID) {
        self.studio = studio
        self.trackID = trackID
        self.track = Track(name: "", colorIndex: 0)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.string, .fileURL])
        Self.registry.register(self, id: trackID)
    }

    required init?(coder: NSCoder) { fatalError() }

    func teardown() { Self.registry.unregister(trackID, view: self) }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "\(track.name) lane, \(track.clips.count) clips" }

    override func accessibilityChildren() -> [Any]? {
        let fmt = MusicalTimeFormatter(project: project)
        return track.clips.map { clip -> NSAccessibilityElement in
            let el = ClipAccessibilityElement()
            el.onPress = { [weak self] in self?.studio.selectClip(clip.id, extend: false); self?.needsDisplay = true }
            el.setAccessibilityRole(.button)
            var label = "\(clip.name), bar \(fmt.string(clip.start)), \(String(format: "%.2f", clip.duration / project.secondsPerBar)) bars"
            if clip.isStretched { label += ", stretched \(Int((clip.stretch * 100).rounded())) percent" }
            if clip.muted { label += ", muted" }
            if studio.selectedClips.contains(clip.id) { label += ", selected" }
            el.setAccessibilityLabel(label)
            el.setAccessibilityParent(self)
            el.setAccessibilityFrameInParentSpace(rect(for: clip))
            return el
        }
    }

    func update(track: Track, index: Int) {
        if track.id != trackID {
            Self.registry.unregister(trackID, view: self)
            trackID = track.id
            Self.registry.register(self, id: trackID)
        }
        self.track = track
        self.index = index
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width > 50 && abs(studio.viewport.laneWidth - newSize.width) > 0.5 {
            studio.viewport.laneWidth = newSize.width
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: - Geometry

    private var vp: TimelineViewport { studio.viewport }
    private var project: Project { studio.project }

    private func rect(for clip: Clip) -> NSRect {
        let x0 = vp.x(clip.start), x1 = vp.x(clip.end)
        return NSRect(x: x0, y: 3, width: max(2, x1 - x0), height: bounds.height - 6)
    }

    private func hit(_ p: NSPoint) -> (Clip, Zone)? {
        for clip in track.clips.reversed() {
            let r = rect(for: clip)
            guard r.insetBy(dx: -2, dy: 0).contains(p) else { continue }
            return (clip, zone(in: r, clip: clip, at: p))
        }
        return nil
    }

    private func zone(in r: NSRect, clip: Clip, at p: NSPoint) -> Zone {
        let stretchTool = studio.tool == .stretch
        let edgeW = min(edge, r.width / 4)
        let bodyTop = r.minY + headerH
        // Fade handles: small squares at the top corners of the body.
        let fadeInX = r.minX + CGFloat(clip.fadeIn * vp.pixelsPerSecond)
        let fadeOutX = r.maxX - CGFloat(clip.fadeOut * vp.pixelsPerSecond)
        if r.width > 40 && abs(p.y - bodyTop) < 6 {
            if abs(p.x - fadeInX) < 6 { return .fadeIn }
            if abs(p.x - fadeOutX) < 6 { return .fadeOut }
        }
        // Stretch grips: bottom corners.
        if r.width > 30 && p.y > r.maxY - 12 {
            if p.x < r.minX + 12 { return .stretchLeft }
            if p.x > r.maxX - 12 { return .stretchRight }
        }
        if p.x < r.minX + edgeW { return stretchTool ? .stretchLeft : .trimLeft }
        if p.x > r.maxX - edgeW { return stretchTool ? .stretchRight : .trimRight }
        return p.y < bodyTop ? .header : .body
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = project
        let scale = window?.backingScaleFactor ?? 2

        // Lane background
        (index % 2 == 0 ? Theme.NS.lane : Theme.NS.laneAlt).setFill()
        bounds.fill()
        if studio.selectedTrackID == trackID {
            NSColor.white.withAlphaComponent(0.018).setFill()
            bounds.fill()
        }

        // Loop region tint (outside region slightly darkened)
        if p.loop.enabled {
            let lx0 = vp.x(p.loop.start), lx1 = vp.x(p.loop.end)
            NSColor.black.withAlphaComponent(0.16).setFill()
            NSRect(x: dirtyRect.minX, y: 0, width: max(0, lx0 - dirtyRect.minX), height: bounds.height).fill()
            NSRect(x: lx1, y: 0, width: max(0, dirtyRect.maxX - lx1), height: bounds.height).fill()
            Theme.NS.loop.withAlphaComponent(0.035).setFill()
            NSRect(x: lx0, y: 0, width: lx1 - lx0, height: bounds.height).fill()
        }

        // Grid
        let grid = GridMetrics(secondsPerBeat: p.secondsPerBeat, beatsPerBar: p.beatsPerBar, pixelsPerSecond: vp.pixelsPerSecond)
        grid.forEachLine(from: vp.time(dirtyRect.minX - 1), to: vp.time(dirtyRect.maxX + 1)) { t, kind, _ in
            let x = (vp.x(t) * scale).rounded() / scale + 0.5 / scale
            let color = kind == 0 ? Theme.NS.gridBar : (kind == 1 ? Theme.NS.gridBeat : Theme.NS.gridSub)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x - 0.5 / scale, y: 0, width: 1 / scale * (kind == 0 ? 2 : 1), height: bounds.height))
        }

        // Clips
        let samples = Dictionary(uniqueKeysWithValues: p.samples.map { ($0.id, $0) })
        let base = Theme.trackNSColor(track.colorIndex)
        let audible = p.isAudible(track)
        for clip in track.clips {
            let r = rect(for: clip)
            guard r.intersects(dirtyRect.insetBy(dx: -4, dy: 0)), let sample = samples[clip.sampleID] else { continue }
            drawClip(ctx, clip: clip, sample: sample, rect: r, base: base, audible: audible && !clip.muted,
                     selected: studio.selectedClips.contains(clip.id), dirty: dirtyRect, scale: scale)
        }

        // Live recording ghost
        if studio.isRecording, studio.recordingTrackID == trackID, studio.recordingDuration > 0 {
            let x0 = vp.x(studio.recordingStart)
            let x1 = vp.x(studio.recordingStart + studio.recordingDuration)
            let r = NSRect(x: x0, y: 3, width: max(2, x1 - x0), height: bounds.height - 6)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            Theme.NS.record.withAlphaComponent(0.22).setFill()
            path.fill()
            Theme.NS.record.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
            let header = NSRect(x: r.minX, y: r.minY, width: r.width, height: headerH)
            ctx.saveGState()
            path.addClip()
            Theme.NS.record.setFill()
            header.fill()
            ctx.restoreGState()
            NSAttributedString.label("● REC", size: 9.5, weight: .heavy, color: .white)
                .draw(at: NSPoint(x: r.minX + 6, y: r.minY + 1.5))
            let fpp = 1 / vp.pixelsPerSecond * AudioSpec.sampleRate
            WaveformDrawing.drawLive(ctx, peaks: studio.livePeaks, framesPerBin: Recorder.peakBin, originX: x0, framesPerPoint: fpp,
                                     xRange: dirtyRect.minX...dirtyRect.maxX, midY: r.minY + headerH + (r.height - headerH) / 2,
                                     halfHeight: (r.height - headerH) / 2 - 3, color: Theme.NS.record.blended(0.35, with: .white))
        }

        // Rubber band
        if let rb = rubberBand {
            Theme.NS.selection.withAlphaComponent(0.12).setFill()
            rb.fill()
            Theme.NS.selection.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(rect: rb.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }

        // Drop indicator
        if let t = dropTime {
            let x = vp.x(t)
            Theme.NS.accent.setFill()
            NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
            Theme.NS.accent.withAlphaComponent(0.08).setFill()
            NSRect(x: x, y: 0, width: 120, height: bounds.height).fill()
        }

        // Bottom hairline
        Theme.NS.hairline.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.height - 1, width: dirtyRect.width, height: 1).fill()
    }

    private func drawClip(_ ctx: CGContext, clip: Clip, sample: Sample, rect r: NSRect, base: NSColor,
                          audible: Bool, selected: Bool, dirty: NSRect, scale: CGFloat) {
        let color = audible ? base : base.blended(0.65, with: NSColor(white: 0.35, alpha: 1))
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        let hovered = hoverClipID == clip.id

        // Body
        ctx.saveGState()
        path.addClip()
        let top = color.withAlphaComponent(selected ? 0.34 : 0.22)
        let bottom = color.withAlphaComponent(selected ? 0.20 : 0.11)
        NSGradient(starting: top, ending: bottom)?.draw(in: r, angle: 90)

        // Header strip
        let header = NSRect(x: r.minX, y: r.minY, width: r.width, height: headerH)
        color.withAlphaComponent(selected ? 1 : 0.82).setFill()
        header.fill()

        // Waveform
        let wave = NSRect(x: r.minX, y: r.minY + headerH + 2, width: r.width, height: r.height - headerH - 4)
        let fpp = AudioSpec.sampleRate / vp.pixelsPerSecond / clip.stretch
        let mapping = WaveformDrawing.Mapping(originX: r.minX, frameAtOrigin: Double(clip.sourceStart), framesPerPoint: fpp,
                                              frameLimit: Double(clip.sourceStart)..<Double(clip.sourceStart + clip.sourceLength))
        let waveColor = color.blended(selected ? 0.35 : 0.15, with: .white)
        WaveformDrawing.draw(ctx, buffer: sample.buffer, channel: -1, mapping: mapping,
                             xRange: max(dirty.minX, r.minX)...min(dirty.maxX, r.maxX),
                             midY: wave.midY, halfHeight: wave.height / 2 * 0.96,
                             peakColor: waveColor.withAlphaComponent(0.55), rmsColor: waveColor,
                             scale: scale, gain: clip.gain)

        // Fades
        let fiW = CGFloat(clip.fadeIn * vp.pixelsPerSecond), foW = CGFloat(clip.fadeOut * vp.pixelsPerSecond)
        if fiW > 1 || foW > 1 {
            let shade = NSColor.black.withAlphaComponent(0.35)
            let curve = NSBezierPath()
            if fiW > 1 {
                let f = NSBezierPath()
                f.move(to: NSPoint(x: r.minX, y: wave.minY))
                f.line(to: NSPoint(x: r.minX + fiW, y: wave.minY))
                f.curve(to: NSPoint(x: r.minX, y: r.maxY), controlPoint1: NSPoint(x: r.minX + fiW * 0.35, y: wave.minY),
                        controlPoint2: NSPoint(x: r.minX, y: wave.midY))
                f.close()
                shade.setFill(); f.fill()
                curve.move(to: NSPoint(x: r.minX, y: r.maxY))
                curve.curve(to: NSPoint(x: r.minX + fiW, y: wave.minY), controlPoint1: NSPoint(x: r.minX, y: wave.midY),
                            controlPoint2: NSPoint(x: r.minX + fiW * 0.35, y: wave.minY))
            }
            if foW > 1 {
                let f = NSBezierPath()
                f.move(to: NSPoint(x: r.maxX, y: wave.minY))
                f.line(to: NSPoint(x: r.maxX - foW, y: wave.minY))
                f.curve(to: NSPoint(x: r.maxX, y: r.maxY), controlPoint1: NSPoint(x: r.maxX - foW * 0.35, y: wave.minY),
                        controlPoint2: NSPoint(x: r.maxX, y: wave.midY))
                f.close()
                shade.setFill(); f.fill()
                curve.move(to: NSPoint(x: r.maxX - foW, y: wave.minY))
                curve.curve(to: NSPoint(x: r.maxX, y: r.maxY), controlPoint1: NSPoint(x: r.maxX - foW * 0.35, y: wave.minY),
                            controlPoint2: NSPoint(x: r.maxX, y: wave.midY))
            }
            NSColor.white.withAlphaComponent(0.75).setStroke()
            curve.lineWidth = 1
            curve.stroke()
        }
        ctx.restoreGState()

        // Title + badges
        if r.width > 24 {
            var x = r.minX + 6
            let textColor = NSColor.black.withAlphaComponent(0.82)
            if clip.isStretched {
                let pending = clip.preservePitch && studio.stretchCache.isPending(clip, sample: sample)
                let badge = String(format: "%@%.2f×", pending ? "◌ " : "", clip.stretch)
                let s = NSAttributedString.label(badge, size: 9, weight: .heavy, color: textColor, mono: true)
                let w = s.size().width + 8
                if r.width > w + 40 {
                    let br = NSRect(x: r.maxX - w - 4, y: r.minY + 2, width: w, height: headerH - 4)
                    NSColor.black.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: br, xRadius: 3, yRadius: 3).fill()
                    s.draw(at: NSPoint(x: br.minX + 4, y: br.minY - 0.5))
                }
            }
            if clip.muted {
                NSAttributedString.label("M", size: 9, weight: .heavy, color: textColor).draw(at: NSPoint(x: x, y: r.minY + 1.5))
                x += 12
            }
            let title = NSAttributedString.label(clip.name, size: 10.5, weight: .semibold, color: textColor)
            ctx.saveGState()
            ctx.clip(to: NSRect(x: x, y: r.minY, width: max(0, r.width - (x - r.minX) - 50), height: headerH))
            title.draw(at: NSPoint(x: x, y: r.minY + 0.5))
            ctx.restoreGState()
        }

        // Outline
        if selected {
            NSColor.white.withAlphaComponent(0.92).setStroke()
            let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
            o.lineWidth = 1.5
            o.stroke()
        } else {
            color.withAlphaComponent(0.6).setStroke()
            let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            o.lineWidth = 1
            o.stroke()
        }

        // Hover affordances: fade handles + stretch grips.
        if hovered && r.width > 40 {
            let bodyTop = r.minY + headerH
            let handles = [NSPoint(x: r.minX + max(4, fiW), y: bodyTop), NSPoint(x: r.maxX - max(4, foW), y: bodyTop)]
            for (i, h) in handles.enumerated() {
                let active = (i == 0 && hoverZone == .fadeIn) || (i == 1 && hoverZone == .fadeOut)
                let hr = NSRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: hr.insetBy(dx: active ? -1 : 0, dy: active ? -1 : 0)).fill()
                color.setStroke()
                let ring = NSBezierPath(ovalIn: hr.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            for right in [false, true] {
                let active = (right && hoverZone == .stretchRight) || (!right && hoverZone == .stretchLeft)
                let tri = NSBezierPath()
                if right {
                    tri.move(to: NSPoint(x: r.maxX - 2, y: r.maxY - 2))
                    tri.line(to: NSPoint(x: r.maxX - 12, y: r.maxY - 2))
                    tri.line(to: NSPoint(x: r.maxX - 2, y: r.maxY - 12))
                } else {
                    tri.move(to: NSPoint(x: r.minX + 2, y: r.maxY - 2))
                    tri.line(to: NSPoint(x: r.minX + 12, y: r.maxY - 2))
                    tri.line(to: NSPoint(x: r.minX + 2, y: r.maxY - 12))
                }
                tri.close()
                (active ? NSColor.white : NSColor.white.withAlphaComponent(0.55)).setFill()
                tri.fill()
            }
        }
    }

    // MARK: - Cursor & hover

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = hit(p)
        let newID = h?.0.id, newZone = h?.1 ?? .none
        if newID != hoverClipID || newZone != hoverZone {
            hoverClipID = newID
            hoverZone = newZone
            needsDisplay = true
        }
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        if hoverClipID != nil { hoverClipID = nil; hoverZone = .none; needsDisplay = true }
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor() }

    private func updateCursor() {
        if studio.tool == .blade { Cursors.blade.set(); return }
        switch hoverZone {
        case .trimLeft, .trimRight: NSCursor.resizeLeftRight.set()
        case .stretchLeft, .stretchRight: Cursors.stretch.set()
        case .fadeIn, .fadeOut: Cursors.fade.set()
        case .header: NSCursor.openHand.set()
        default: NSCursor.arrow.set()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        studio.focus = .arrangement
        let p = convert(event.locationInWindow, from: nil)
        dragDownPoint = p
        dragDownTime = vp.time(p.x)
        didDrag = false
        dragZone = .none
        dragClipID = nil
        studio.selectedTrackID = trackID
        let bypass = event.modifierFlags.contains(.command)

        if let (clip, zone) = hit(p) {
            if studio.tool == .blade {
                studio.split(at: studio.snapTime(dragDownTime, bypass: bypass), clipIDs: [clip.id])
                return
            }
            if event.clickCount == 2 {
                studio.openClipInEditor(clip.id)
                return
            }
            studio.selectClip(clip.id, extend: event.modifierFlags.contains(.shift))
            guard studio.selectedClips.contains(clip.id) else { return }
            dragClipID = clip.id
            var z = zone
            if event.modifierFlags.contains(.option) {
                if z == .trimLeft { z = .stretchLeft } else if z == .trimRight { z = .stretchRight }
            }
            dragZone = z
            if z == .header { NSCursor.closedHand.set() }
            captureOrigins()
            studio.beginGesture(gestureName(z))
            optionDuplicated = false
            clickedSelectedID = event.modifierFlags.contains(.shift) ? nil : clip.id
            if event.modifierFlags.contains(.option) && (z == .body || z == .header) {
                duplicateForOptionDrag()
                optionDuplicated = true
            }
        } else {
            if !event.modifierFlags.contains(.shift) { studio.selectedClips = [] }
            if event.clickCount == 2 {
                studio.seek(to: studio.snapTime(dragDownTime, bypass: bypass))
                return
            }
            rubberBand = NSRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    private func gestureName(_ z: Zone) -> String {
        switch z {
        case .trimLeft, .trimRight: return "Trim Clip"
        case .stretchLeft, .stretchRight: return "Stretch Clip"
        case .fadeIn: return "Fade In"
        case .fadeOut: return "Fade Out"
        default: return "Move Clips"
        }
    }

    private func captureOrigins() {
        origins = [:]
        for (ti, t) in project.tracks.enumerated() {
            for c in t.clips where studio.selectedClips.contains(c.id) {
                origins[c.id] = DragOrigin(trackIndex: ti, clip: c)
            }
        }
    }

    /// ⌥-drag: leave copies behind and drag the originals.
    private func duplicateForOptionDrag() {
        studio.beginGesture("Duplicate Clips")
        let copies = origins.values.map { o -> (Int, Clip) in
            var c = o.clip
            c.id = UUID()
            return (o.trackIndex, c)
        }
        studio.live { p in
            for (ti, c) in copies where ti < p.tracks.count {
                p.tracks[ti].clips.append(c)
                p.tracks[ti].sortClips()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !didDrag && hypot(p.x - dragDownPoint.x, p.y - dragDownPoint.y) < 3 { return }
        didDrag = true
        let bypass = event.modifierFlags.contains(.command)

        if var rb = rubberBand {
            rb = NSRect(x: min(p.x, dragDownPoint.x), y: min(p.y, dragDownPoint.y),
                        width: abs(p.x - dragDownPoint.x), height: abs(p.y - dragDownPoint.y))
            rubberBand = rb
            let hits = track.clips.filter { rect(for: $0).intersects(rb) }.map(\.id)
            if event.modifierFlags.contains(.shift) { studio.selectedClips.formUnion(hits) } else { studio.selectedClips = Set(hits) }
            needsDisplay = true
            return
        }

        guard let id = dragClipID, let origin = origins[id] else { return }
        autoscroll(with: event)
        let t = vp.time(p.x)
        let dt = t - dragDownTime
        let sr = AudioSpec.sampleRate
        let sample = project.sample(origin.clip.sampleID)

        switch dragZone {
        case .body, .header:
            let anchorStart = studio.snapTime(origin.clip.start + dt, bypass: bypass)
            let delta = max(anchorStart, 0) - origin.clip.start
            let minStart = origins.values.map(\.clip.start).min() ?? 0
            let clampedDelta = max(delta, -minStart)
            // Vertical: move between tracks.
            var trackOffset = 0
            if let target = Self.registry.trackID(atWindowPoint: event.locationInWindow),
               let ti = project.trackIndex(target) {
                trackOffset = ti - origin.trackIndex
            }
            let maxTi = project.tracks.count - 1
            let lo = origins.values.map(\.trackIndex).min() ?? 0, hi = origins.values.map(\.trackIndex).max() ?? 0
            trackOffset = min(max(trackOffset, -lo), maxTi - hi)
            let moved = origins
            studio.live { p in
                for t in p.tracks.indices { p.tracks[t].clips.removeAll { moved[$0.id] != nil } }
                for (_, o) in moved {
                    var c = o.clip
                    c.start = o.clip.start + clampedDelta
                    let ti = o.trackIndex + trackOffset
                    p.tracks[ti].clips.append(c)
                }
                for t in p.tracks.indices { p.tracks[t].sortClips() }
            }
            if let tid = studio.project.tracks[safe: origin.trackIndex + trackOffset]?.id { studio.selectedTrackID = tid }

        case .trimLeft:
            guard let s = sample else { return }
            let c0 = origin.clip
            var newStart = studio.snapTime(c0.start + dt, bypass: bypass)
            let minStart = c0.start - Double(c0.sourceStart) / sr * c0.stretch
            newStart = min(max(newStart, minStart, 0), c0.end - 0.005)
            let srcDelta = Int(((newStart - c0.start) / c0.stretch * sr).rounded())
            studio.live { p in
                p.updateClip(id) { c in
                    c.start = newStart
                    c.sourceStart = max(0, c0.sourceStart + srcDelta)
                    c.sourceLength = min(s.frameCount - c.sourceStart, c0.sourceLength - srcDelta)
                }
            }

        case .trimRight:
            guard let s = sample else { return }
            let c0 = origin.clip
            var newEnd = studio.snapTime(c0.end + dt, bypass: bypass)
            let maxEnd = c0.start + Double(s.frameCount - c0.sourceStart) / sr * c0.stretch
            newEnd = max(min(newEnd, maxEnd), c0.start + 0.005)
            studio.live { p in
                p.updateClip(id) { c in c.sourceLength = Int(((newEnd - c0.start) / c0.stretch * sr).rounded()) }
            }

        case .stretchRight:
            let c0 = origin.clip
            var newEnd = studio.snapTime(c0.end + dt, bypass: bypass)
            newEnd = max(newEnd, c0.start + c0.sourceDuration / 16)
            let ratio = min(16, max(1.0 / 16, (newEnd - c0.start) / c0.sourceDuration))
            studio.live { p in p.updateClip(id) { $0.stretch = ratio } }
            studio.showToast(String(format: "Stretch %.1f%% · %@", ratio * 100, formatDuration(c0.sourceDuration * ratio)))

        case .stretchLeft:
            let c0 = origin.clip
            var newStart = studio.snapTime(c0.start + dt, bypass: bypass)
            newStart = max(0, min(newStart, c0.end - c0.sourceDuration / 16))
            let ratio = min(16, max(1.0 / 16, (c0.end - newStart) / c0.sourceDuration))
            studio.live { p in p.updateClip(id) { c in c.stretch = ratio; c.start = c0.end - c0.sourceDuration * ratio } }
            studio.showToast(String(format: "Stretch %.1f%% · %@", ratio * 100, formatDuration(c0.sourceDuration * ratio)))

        case .fadeIn:
            let c0 = origin.clip
            let v = min(max(0, t - c0.start), c0.duration - c0.fadeOut)
            studio.live { p in p.updateClip(id) { $0.fadeIn = v } }

        case .fadeOut:
            let c0 = origin.clip
            let v = min(max(0, c0.end - t), c0.duration - c0.fadeIn)
            studio.live { p in p.updateClip(id) { $0.fadeOut = v } }

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if rubberBand != nil {
            rubberBand = nil
            needsDisplay = true
            if !didDrag { studio.seek(to: studio.snapTime(dragDownTime, bypass: event.modifierFlags.contains(.command))) }
        }
        if dragClipID != nil {
            if !didDrag && optionDuplicated {
                studio.cancelGesture()
            } else {
                studio.endGesture()
            }
            if !didDrag, let id = clickedSelectedID { studio.selectedClips = [id] }
        }
        clickedSelectedID = nil
        optionDuplicated = false
        dragClipID = nil
        dragZone = .none
        origins = [:]
        updateCursor()
    }

    // MARK: - Scroll & zoom

    override func scrollWheel(with event: NSEvent) {
        if handleTimelineScroll(event, viewport: vp, location: convert(event.locationInWindow, from: nil)) { return }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        vp.zoom(by: 1 + Double(event.magnification), anchorX: p.x)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        let t = vp.time(p.x)
        if let (clip, _) = hit(p) {
            if !studio.selectedClips.contains(clip.id) { studio.selectClip(clip.id, extend: false) }
            let count = studio.selectedClips.count
            menu.add("Open in Sample Editor", symbol: "waveform") { self.studio.openClipInEditor(clip.id) }
            menu.add("Preview Clip", symbol: "play") {
                self.studio.previewSample(clip.sampleID, range: clip.sourceStart..<(clip.sourceStart + clip.sourceLength))
            }
            menu.addItem(.separator())
            menu.add("Split Here", symbol: "scissors") { self.studio.split(at: self.studio.snapTime(t), clipIDs: [clip.id]) }
            menu.add("Split at Playhead") { self.studio.split(at: self.studio.positionSeconds) }
            menu.add("Slice at Transients", symbol: "waveform.path.ecg") { self.studio.sliceSelectedClipsAtTransients() }
            menu.addItem(.separator())
            menu.add(count > 1 ? "Duplicate \(count) Clips" : "Duplicate", symbol: "plus.square.on.square") { self.studio.duplicateSelectedClips() }
            menu.submenu("Repeat", symbol: "repeat") { m in
                for n in [2, 4, 8, 16] { m.add("× \(n)") { self.studio.repeatSelectedClips(times: n - 1) } }
            }
            menu.add("Loop This Clip", symbol: "repeat.circle") { self.studio.loopSelection() }
            menu.add("Quantize Start to Grid", symbol: "square.grid.3x1.below.line.grid.1x2") { self.studio.quantizeSelectedClips() }
            menu.addItem(.separator())
            menu.submenu("Stretch to Fit", symbol: "arrow.left.and.right") { m in
                for (label, bars) in [("1 Beat", 0.25), ("2 Beats", 0.5), ("1 Bar", 1.0), ("2 Bars", 2.0), ("4 Bars", 4.0), ("8 Bars", 8.0)] {
                    m.add(label) { self.studio.fitSelectedClips(toBars: bars) }
                }
                m.addItem(.separator())
                m.add("Half Speed (200%)") { self.studio.updateSelectedClips("Stretch") { $0.stretch = min(16, $0.stretch * 2) } }
                m.add("Double Speed (50%)") { self.studio.updateSelectedClips("Stretch") { $0.stretch = max(1.0 / 16, $0.stretch / 2) } }
            }
            menu.add("Reset Stretch", enabled: clip.isStretched) { self.studio.resetStretch() }
            menu.submenu("Stretch Mode", symbol: "waveform.path") { m in
                for mode in StretchMode.allCases {
                    m.add(mode.label, checked: clip.preservePitch && clip.stretchMode == mode) {
                        self.studio.updateSelectedClips("Stretch Mode") { $0.preservePitch = true; $0.stretchMode = mode }
                    }
                }
                m.add("Varispeed", checked: !clip.preservePitch) {
                    self.studio.updateSelectedClips("Stretch Mode") { $0.preservePitch = false }
                }
            }
            menu.addItem(.separator())
            menu.add(clip.muted ? "Unmute Clip" : "Mute Clip", symbol: clip.muted ? "speaker.wave.2" : "speaker.slash") {
                let m = !clip.muted
                self.studio.updateSelectedClips(m ? "Mute Clip" : "Unmute Clip") { $0.muted = m }
            }
            menu.add("Remove Fades") { self.studio.updateSelectedClips("Remove Fades") { $0.fadeIn = 0; $0.fadeOut = 0 } }
            menu.addItem(.separator())
            menu.add(count > 1 ? "Delete \(count) Clips" : "Delete", symbol: "trash") { self.studio.deleteSelectedClips() }
        } else {
            menu.add("Set Playhead Here", symbol: "arrow.right.to.line") { self.studio.seek(to: self.studio.snapTime(t)) }
            menu.add("Loop 1 Bar Here", symbol: "repeat") {
                let bar = self.project.secondsPerBar
                let s = floor(t / bar) * bar
                self.studio.setLoop(start: s, end: s + bar)
            }
            menu.add("Loop 4 Bars Here") {
                let bar = self.project.secondsPerBar
                let s = floor(t / bar) * bar
                self.studio.setLoop(start: s, end: s + bar * 4)
            }
            menu.addItem(.separator())
            if let s = studio.editorSample {
                menu.add("Place “\(s.name)” Here", symbol: "square.and.arrow.down") {
                    self.studio.placeSample(s.id, onTrack: self.trackID, at: self.studio.snapTime(t), range: self.studio.editRange)
                }
            }
            menu.add("Import Audio…", symbol: "square.and.arrow.down.on.square") { self.studio.presentImportPanel() }
            menu.add("Select All Clips") { self.studio.selectAllClips() }
        }
        return menu
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        dropTime = studio.snapTime(max(0, vp.time(p.x)))
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTime = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        let t = studio.snapTime(max(0, vp.time(p.x)))
        dropTime = nil
        needsDisplay = true
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            studio.importAudio(urls: urls, placeAt: t, onTrack: trackID)
            return true
        }
        if let s = pb.string(forType: .string), let (id, range) = DragPayload.parse(s) {
            studio.placeSample(id, onTrack: trackID, at: t, range: range)
            return true
        }
        return false
    }
}

/// Shared scroll-wheel behaviour for timeline views: ⌘/⌥/⌃-scroll zooms around the
/// cursor, horizontal gestures pan, vertical scrolling falls through to the track list.
func handleTimelineScroll(_ event: NSEvent, viewport vp: TimelineViewport, location p: NSPoint) -> Bool {
    let mods = event.modifierFlags
    let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
    let precise = event.hasPreciseScrollingDeltas
    if mods.contains(.command) || mods.contains(.option) || mods.contains(.control) {
        let amount = Double(dy == 0 ? dx : dy) * (precise ? 0.008 : 0.06)
        vp.zoom(by: exp(amount), anchorX: p.x)
        return true
    }
    if abs(dx) > abs(dy) * 0.8 && dx != 0 {
        vp.scroll(byPixels: -dx * (precise ? 1 : 8))
        return true
    }
    return false
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Accessibility proxy for a clip drawn inside a lane.
final class ClipAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
}

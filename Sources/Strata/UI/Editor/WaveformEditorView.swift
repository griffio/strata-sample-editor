import SwiftUI
import AppKit
import Combine

struct WaveformEditorView: NSViewRepresentable {
    @ObservedObject var studio: Studio
    @ObservedObject var editor: EditorState
    let sample: Sample
    let clip: Clip?

    func makeNSView(context: Context) -> WaveformEditorNSView { WaveformEditorNSView(studio: studio) }

    func updateNSView(_ v: WaveformEditorNSView, context: Context) {
        v.sample = sample
        v.clip = clip
        v.needsDisplay = true
    }
}

/// Detailed stereo editor: selection, slice markers, zoom down to individual samples.
final class WaveformEditorNSView: NSView {
    private unowned let studio: Studio
    var sample: Sample?
    var clip: Clip?

    private enum Drag { case none, select(anchor: Int), edgeLow, edgeHigh, marker(index: Int, original: Int), overviewPan }
    private var drag: Drag = .none
    private var downPoint: NSPoint = .zero
    private var didDrag = false
    private var hoverX: CGFloat?
    private var hoverMarker: Int?
    private var trackingArea: NSTrackingArea?
    private let playheadLayer = CALayer()
    private var cancellable: AnyCancellable?

    let rulerH: CGFloat = 22
    let markerHit: CGFloat = 6

    init(studio: Studio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        playheadLayer.backgroundColor = NSColor.white.cgColor
        playheadLayer.shadowColor = NSColor.white.cgColor
        playheadLayer.shadowOpacity = 0.7
        playheadLayer.shadowRadius = 3
        playheadLayer.shadowOffset = .zero
        playheadLayer.isHidden = true
        playheadLayer.zPosition = 10
        layer?.addSublayer(playheadLayer)
        cancellable = studio.clock.$previewFrame.sink { [weak self] f in self?.movePlayhead(f) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityRoleDescription() -> String? { "waveform editor" }
    override func accessibilityLabel() -> String? {
        guard let s = sample else { return "Waveform editor, empty" }
        var text = "\(s.name), \(formatDuration(s.duration)), \(s.sliceRanges.count) slices"
        if let sel = ed.selection, sel.count > 0 {
            text += ", selection \(formatDuration(Double(sel.count) / AudioSpec.sampleRate)) starting at \(formatClock(Double(sel.lowerBound) / AudioSpec.sampleRate))"
        }
        return text
    }

    private var ed: EditorState { studio.editor }

    override func setFrameSize(_ newSize: NSSize) {
        let first = ed.width < 101 || abs(ed.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if first && newSize.width > 100 {
            let wasFit = sample.map { abs(ed.framesPerPixel - Double($0.frameCount) / Double(max(100, ed.width - 2))) < 0.5 } ?? false
            ed.width = newSize.width
            if wasFit, let s = sample { ed.fit(frames: s.frameCount) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    private func movePlayhead(_ frame: Int?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let f = frame {
            let x = ed.x(Double(f))
            playheadLayer.isHidden = x < 0 || x > bounds.width
            playheadLayer.frame = CGRect(x: x - 0.75, y: 0, width: 1.5, height: bounds.height)
        } else {
            playheadLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private var waveRect: NSRect { NSRect(x: 0, y: rulerH, width: bounds.width, height: bounds.height - rulerH) }

    private var color: NSColor {
        guard let s = sample else { return Theme.NS.accent }
        if let c = clip, let loc = studio.project.locateClip(c.id) { return Theme.trackNSColor(studio.project.tracks[loc.track].colorIndex) }
        return Theme.trackNSColor(s.colorIndex)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.NS.base.setFill()
        bounds.fill()
        guard let s = sample else { return }
        let scale = window?.backingScaleFactor ?? 2
        let wr = waveRect
        let total = s.frameCount
        let base = color

        // Channel lanes
        let laneH = wr.height / 2
        for ch in 0..<2 {
            let lane = NSRect(x: 0, y: wr.minY + CGFloat(ch) * laneH, width: wr.width, height: laneH)
            (ch == 0 ? NSColor(hex: 0x121418) : NSColor(hex: 0x111317)).setFill()
            lane.fill()
        }

        // Outside-the-sample area
        let endX = ed.x(Double(total))
        if endX < bounds.width {
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: endX, y: rulerH, width: bounds.width - endX, height: wr.height).fill()
        }

        // Time grid
        drawRuler(ctx, total: total, scale: scale)

        // Slice regions (alternating tint)
        let ranges = s.sliceRanges
        if ranges.count > 1 {
            for (i, r) in ranges.enumerated() where i % 2 == 1 {
                let x0 = ed.x(Double(r.lowerBound)), x1 = ed.x(Double(r.upperBound))
                guard x1 > dirtyRect.minX, x0 < dirtyRect.maxX else { continue }
                NSColor.white.withAlphaComponent(0.022).setFill()
                NSRect(x: x0, y: wr.minY, width: x1 - x0, height: wr.height).fill()
            }
        }

        // Clip region (non-destructive bounds of the clip opened from the timeline)
        if let c = clip {
            let x0 = ed.x(Double(c.sourceStart)), x1 = ed.x(Double(c.sourceStart + c.sourceLength))
            NSColor.black.withAlphaComponent(0.4).setFill()
            NSRect(x: 0, y: wr.minY, width: max(0, x0), height: wr.height).fill()
            NSRect(x: x1, y: wr.minY, width: max(0, bounds.width - x1), height: wr.height).fill()
        }

        // Selection
        if let sel = ed.selection {
            let x0 = ed.x(Double(sel.lowerBound)), x1 = ed.x(Double(sel.upperBound))
            if sel.count > 0 {
                Theme.NS.selection.withAlphaComponent(0.16).setFill()
                NSRect(x: x0, y: wr.minY, width: x1 - x0, height: wr.height).fill()
                Theme.NS.selection.withAlphaComponent(0.9).setFill()
                NSRect(x: x0 - 0.5, y: wr.minY, width: 1, height: wr.height).fill()
                NSRect(x: x1 - 0.5, y: wr.minY, width: 1, height: wr.height).fill()
                // Selection length badge
                let label = NSAttributedString.label("\(formatDuration(Double(sel.count) / AudioSpec.sampleRate))  ·  \(sel.count) smp",
                                                     size: 9.5, weight: .semibold, color: NSColor.black.withAlphaComponent(0.85), mono: true)
                let sz = label.size()
                if x1 - x0 > sz.width + 14 {
                    let br = NSRect(x: (x0 + x1) / 2 - sz.width / 2 - 6, y: wr.minY + 6, width: sz.width + 12, height: sz.height + 4)
                    Theme.NS.selection.setFill()
                    NSBezierPath(roundedRect: br, xRadius: br.height / 2, yRadius: br.height / 2).fill()
                    label.draw(at: NSPoint(x: br.minX + 6, y: br.minY + 2))
                }
            } else {
                Theme.NS.selection.setFill()
                NSRect(x: x0 - 0.75, y: wr.minY, width: 1.5, height: wr.height).fill()
            }
        }

        // Waveforms
        let mapping = WaveformDrawing.Mapping(originX: 0, frameAtOrigin: ed.scrollFrame, framesPerPoint: ed.framesPerPixel,
                                              frameLimit: 0..<Double(total))
        for ch in 0..<2 {
            let mid = wr.minY + laneH * (CGFloat(ch) + 0.5)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSRect(x: 0, y: mid - 0.25, width: min(bounds.width, endX), height: 0.5).fill()
            WaveformDrawing.draw(ctx, buffer: s.buffer, channel: ch, mapping: mapping,
                                 xRange: dirtyRect.minX...dirtyRect.maxX, midY: mid, halfHeight: laneH / 2 * 0.92,
                                 peakColor: base.withAlphaComponent(0.5), rmsColor: base.blended(0.2, with: .white),
                                 lineColor: base.blended(0.25, with: .white), scale: scale, gain: ed.verticalZoom)
            let tag = NSAttributedString.label(ch == 0 ? "L" : "R", size: 9, weight: .heavy, color: Theme.NS.textTertiary)
            tag.draw(at: NSPoint(x: 6, y: wr.minY + laneH * CGFloat(ch) + 4))
        }
        NSColor.white.withAlphaComponent(0.05).setFill()
        NSRect(x: 0, y: wr.minY + laneH - 0.5, width: bounds.width, height: 1).fill()

        // Slice markers
        for (i, m) in s.slices.enumerated() {
            let x = ed.x(Double(m))
            guard x > dirtyRect.minX - 30, x < dirtyRect.maxX + 30 else { continue }
            let hot = hoverMarker == i
            let mc = hot ? NSColor.white : Theme.NS.loop
            mc.withAlphaComponent(hot ? 1 : 0.85).setFill()
            NSRect(x: x - 0.5, y: rulerH, width: 1, height: wr.height).fill()
            // Flag
            let flag = NSBezierPath()
            flag.move(to: NSPoint(x: x, y: rulerH - 1))
            flag.line(to: NSPoint(x: x, y: 3))
            flag.line(to: NSPoint(x: x + 16, y: 3))
            flag.line(to: NSPoint(x: x + 16, y: rulerH - 7))
            flag.line(to: NSPoint(x: x + 5, y: rulerH - 7))
            flag.close()
            mc.setFill()
            flag.fill()
            NSAttributedString.label("\(i + 2)", size: 8.5, weight: .heavy, color: NSColor.black.withAlphaComponent(0.8), mono: true)
                .draw(at: NSPoint(x: x + 3, y: 3))
        }
        if !s.slices.isEmpty {
            let x = ed.x(0)
            if x > -20 {
                NSAttributedString.label("1", size: 8.5, weight: .heavy, color: Theme.NS.loop, mono: true).draw(at: NSPoint(x: x + 3, y: 3))
            }
        }

        // Hover line
        if let hx = hoverX, case .none = drag {
            NSColor.white.withAlphaComponent(0.25).setFill()
            NSRect(x: hx - 0.5, y: rulerH, width: 1, height: wr.height).fill()
            let f = max(0, Int(ed.frame(hx)))
            let label = NSAttributedString.label(formatClock(Double(f) / AudioSpec.sampleRate), size: 9, weight: .medium,
                                                 color: Theme.NS.textSecondary, mono: true)
            let sz = label.size()
            let lx = min(bounds.width - sz.width - 4, hx + 5)
            NSColor(hex: 0x0D0E11, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: lx - 3, y: bounds.height - sz.height - 6, width: sz.width + 6, height: sz.height + 2),
                         xRadius: 3, yRadius: 3).fill()
            label.draw(at: NSPoint(x: lx, y: bounds.height - sz.height - 5))
        }
        movePlayhead(studio.clock.previewFrame)
    }

    private func drawRuler(_ ctx: CGContext, total: Int, scale: CGFloat) {
        NSGradient(starting: NSColor(hex: 0x1B1D22), ending: NSColor(hex: 0x15171B))?
            .draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: rulerH), angle: 90)
        let sr = AudioSpec.sampleRate
        let secondsPerPixel = ed.framesPerPixel / sr
        // Pick a "nice" major tick spacing ≥ 80 px.
        let candidates: [Double] = [0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60]
        let major = candidates.first { $0 / secondsPerPixel >= 80 } ?? 120
        let minor = major / 5
        let t0 = ed.scrollFrame / sr, t1 = ed.frame(bounds.width) / sr
        var tick = Int(floor(t0 / minor))
        while Double(tick) * minor <= t1 {
            let t = Double(tick) * minor
            tick += 1
            let x = (ed.x(t * sr) * scale).rounded() / scale
            let isMajor = (tick - 1) % 5 == 0
            NSColor.white.withAlphaComponent(isMajor ? 0.3 : 0.12).setFill()
            NSRect(x: x, y: rulerH - (isMajor ? 9 : 4), width: 1, height: isMajor ? 9 : 4).fill()
            if isMajor && t >= 0 {
                let text = major < 0.01 ? String(format: "%.2f ms", t * 1000) : (major < 1 ? String(format: "%.3f", t) : formatClock(t + 1e-6, millis: false))
                NSAttributedString.label(text, size: 9, weight: .medium, color: Theme.NS.textSecondary, mono: true)
                    .draw(at: NSPoint(x: x + 3, y: rulerH - 19))
            }
        }
        Theme.NS.hairline.setFill()
        NSRect(x: 0, y: rulerH - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: Hit testing

    private func markerIndex(at p: NSPoint) -> Int? {
        guard let s = sample else { return nil }
        for (i, m) in s.slices.enumerated() {
            let x = ed.x(Double(m))
            if p.y < rulerH ? (p.x >= x - 2 && p.x <= x + 17) : abs(p.x - x) <= 3 { return i }
        }
        return nil
    }

    private func snapped(_ frame: Int, _ event: NSEvent) -> Int {
        guard let s = sample else { return frame }
        let f = min(max(0, frame), s.frameCount)
        if ed.snapToZeroCrossings && !event.modifierFlags.contains(.command) {
            return s.buffer.nearestZeroCrossing(to: f, radius: max(64, Int(ed.framesPerPixel * 6)))
        }
        return f
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverX = p.x
        hoverMarker = markerIndex(at: p)
        needsDisplay = true
        updateCursor(p)
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        hoverMarker = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func updateCursor(_ p: NSPoint) {
        if markerIndex(at: p) != nil { NSCursor.resizeLeftRight.set(); return }
        if let sel = ed.selection, sel.count > 0 {
            let x0 = ed.x(Double(sel.lowerBound)), x1 = ed.x(Double(sel.upperBound))
            if abs(p.x - x0) < 5 || abs(p.x - x1) < 5 { NSCursor.resizeLeftRight.set(); return }
        }
        NSCursor.iBeam.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        studio.focus = .editor
        guard let s = sample else { return }
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        didDrag = false
        let frame = Int(ed.frame(p.x).rounded())

        if event.modifierFlags.contains(.option), let sel = ed.selection, sel.count > 0,
           p.x >= ed.x(Double(sel.lowerBound)), p.x <= ed.x(Double(sel.upperBound)) {
            beginRegionDrag(event: event, sample: s, range: sel)
            return
        }

        if let mi = markerIndex(at: p) {
            if event.modifierFlags.contains(.option) {
                var sl = s.slices
                sl.remove(at: mi)
                studio.setSlices(sl, name: "Remove Slice")
                return
            }
            studio.beginGesture("Move Slice")
            drag = .marker(index: mi, original: s.slices[mi])
            return
        }

        if p.y < rulerH {
            // Click in the ruler: audition the slice under the cursor (MPC-style).
            if event.clickCount == 2 {
                studio.setSlices(s.slices + [snapped(frame, event)], name: "Add Slice")
                return
            }
            if let r = s.sliceRanges.first(where: { $0.contains(frame) }) {
                ed.selection = r
                studio.previewSample(s.id, range: r, loop: ed.loopPreview, fromEditor: true)
            }
            return
        }

        if event.clickCount == 2 {
            studio.selectSlice(containing: frame)
            return
        }
        if let sel = ed.selection, sel.count > 0 {
            let x0 = ed.x(Double(sel.lowerBound)), x1 = ed.x(Double(sel.upperBound))
            if abs(p.x - x0) < 5 { drag = .edgeLow; return }
            if abs(p.x - x1) < 5 { drag = .edgeHigh; return }
            if event.modifierFlags.contains(.shift) {
                let f = snapped(frame, event)
                ed.selection = min(sel.lowerBound, f)..<max(sel.upperBound, f)
                drag = f < sel.lowerBound ? .edgeLow : .edgeHigh
                return
            }
        }
        let anchor = snapped(frame, event)
        ed.selection = anchor..<anchor
        drag = .select(anchor: anchor)
        // One-shot previews restart from the click; a looping preview keeps playing and
        // follows the new selection once it is dragged out.
        if studio.clock.previewFrame != nil && !studio.isLoopPreviewing {
            studio.previewSample(s.id, range: anchor..<s.frameCount, fromEditor: true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = sample else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !didDrag && abs(p.x - downPoint.x) < 2 && abs(p.y - downPoint.y) < 2 { return }
        didDrag = true
        // Auto-scroll at the edges.
        if p.x < 0 { ed.scrollFrame = ed.clampScroll(ed.scrollFrame + Double(p.x) * ed.framesPerPixel * 0.3, totalFrames: s.frameCount) }
        if p.x > bounds.width { ed.scrollFrame = ed.clampScroll(ed.scrollFrame + Double(p.x - bounds.width) * ed.framesPerPixel * 0.3, totalFrames: s.frameCount) }
        let frame = snapped(Int(ed.frame(min(max(p.x, 0), bounds.width)).rounded()), event)
        switch drag {
        case .select(let anchor):
            ed.selection = min(anchor, frame)..<max(anchor, frame)
        case .edgeLow:
            if let sel = ed.selection { ed.selection = min(frame, sel.upperBound)..<max(frame, sel.upperBound) }
        case .edgeHigh:
            if let sel = ed.selection { ed.selection = min(frame, sel.lowerBound)..<max(frame, sel.lowerBound) }
        case .marker(let index, _):
            var sl = s.slices
            guard index < sl.count else { return }
            sl[index] = min(max(1, frame), s.frameCount - 1)
            studio.live { proj in
                if let i = proj.sampleIndex(s.id) { proj.samples[i].slices = sl }
            }
        case .overviewPan, .none:
            break
        }
        hoverX = p.x
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .marker = drag {
            // Re-sort and commit.
            if let s = sample { studio.live { proj in if let i = proj.sampleIndex(s.id) { proj.samples[i].slices = Array(Set(s.slices)).sorted() } } }
            studio.endGesture()
        }
        if case .select = drag, let sel = ed.selection, sel.count == 0, let s = sample, !didDrag {
            // A click: place the cursor; if previewing, restart from here.
            if studio.clock.previewFrame != nil && !studio.isLoopPreviewing {
                studio.previewSample(s.id, range: sel.lowerBound..<s.frameCount, fromEditor: true)
            }
        }
        drag = .none
    }

    private func beginRegionDrag(event: NSEvent, sample s: Sample, range: Range<Int>) {
        let item = NSPasteboardItem()
        item.setString(DragPayload.region(s.id, range), forType: .string)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let w: CGFloat = 140, h: CGFloat = 40
        let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { rect in
            let c = self.color
            c.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
            NSAttributedString.label("\(s.name) · \(formatDuration(Double(range.count) / AudioSpec.sampleRate))", size: 10.5,
                                     weight: .semibold, color: NSColor.black.withAlphaComponent(0.85))
                .draw(at: NSPoint(x: 8, y: 12))
            return true
        }
        let p = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), contents: img)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    // MARK: Scroll / zoom

    override func scrollWheel(with event: NSEvent) {
        guard let s = sample else { return }
        let p = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags
        let precise = event.hasPreciseScrollingDeltas
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if mods.contains(.command) || mods.contains(.control) || (!precise && abs(dy) > abs(dx) && !mods.contains(.shift)) {
            let amount = Double(dy) * (precise ? 0.01 : 0.08)
            ed.zoom(by: exp(amount), anchorX: p.x, totalFrames: s.frameCount)
        } else if mods.contains(.option) {
            ed.verticalZoom = min(16, max(0.25, ed.verticalZoom * Float(exp(Double(dy) * 0.01))))
        } else {
            let d = abs(dx) > abs(dy) ? dx : dy
            ed.scrollFrame = ed.clampScroll(ed.scrollFrame - Double(d) * ed.framesPerPixel * (precise ? 1 : 10), totalFrames: s.frameCount)
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        guard let s = sample else { return }
        ed.zoom(by: 1 + Double(event.magnification), anchorX: convert(event.locationInWindow, from: nil).x, totalFrames: s.frameCount)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let s = sample else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let mi = markerIndex(at: p) {
            menu.add("Remove Slice Marker", symbol: "minus.circle") {
                var sl = s.slices; sl.remove(at: mi); self.studio.setSlices(sl, name: "Remove Slice")
            }
            menu.addItem(.separator())
        }
        let hasSel = studio.editRange != nil
        menu.add(hasSel ? "Play Selection" : "Play", symbol: "play") { self.studio.previewEditorSelection() }
        menu.add("Place on Timeline at Playhead", symbol: "square.and.arrow.down") { self.studio.placeEditorSelection() }
        menu.addItem(.separator())
        menu.add("Trim to Selection", symbol: "crop", enabled: hasSel) { self.studio.editTrimToSelection() }
        menu.add("Delete Selection", symbol: "delete.left", enabled: hasSel) { self.studio.editDeleteSelection() }
        menu.add("Silence", symbol: "speaker.slash", enabled: hasSel) { self.studio.editSilence() }
        menu.add("Selection to New Sample", symbol: "plus.square.on.square", enabled: hasSel) { self.studio.editSelectionToNewSample() }
        menu.addItem(.separator())
        menu.add("Reverse", symbol: "arrow.uturn.backward") { self.studio.editReverse() }
        menu.add("Normalize", symbol: "waveform.badge.plus") { self.studio.editNormalize() }
        menu.add("Fade In", symbol: "chart.line.uptrend.xyaxis") { self.studio.editFadeIn() }
        menu.add("Fade Out", symbol: "chart.line.downtrend.xyaxis") { self.studio.editFadeOut() }
        menu.addItem(.separator())
        let frame = snapped(Int(ed.frame(p.x)), event)
        menu.add("Add Slice Marker Here", symbol: "flag") { self.studio.setSlices(s.slices + [frame], name: "Add Slice") }
        menu.add("Auto-Slice at Transients", symbol: "waveform.path.ecg") { self.studio.autoSlice() }
        menu.add("Clear Slices", enabled: !s.slices.isEmpty) { self.studio.clearSlices() }
        return menu
    }
}

extension WaveformEditorNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - Overview strip

struct WaveformOverview: NSViewRepresentable {
    @ObservedObject var studio: Studio
    @ObservedObject var editor: EditorState
    let sample: Sample

    func makeNSView(context: Context) -> OverviewNSView { OverviewNSView(studio: studio) }
    func updateNSView(_ v: OverviewNSView, context: Context) {
        v.sample = sample
        v.needsDisplay = true
    }
}

/// Whole-sample miniature with the visible window; drag to navigate.
final class OverviewNSView: NSView {
    private unowned let studio: Studio
    var sample: Sample?

    init(studio: Studio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let s = sample, s.frameCount > 0 else { return }
        NSColor(hex: 0x111317).setFill()
        bounds.fill()
        let fpp = Double(s.frameCount) / Double(max(1, bounds.width))
        let mapping = WaveformDrawing.Mapping(originX: 0, frameAtOrigin: 0, framesPerPoint: fpp, frameLimit: 0..<Double(s.frameCount))
        let c = Theme.trackNSColor(s.colorIndex)
        WaveformDrawing.draw(ctx, buffer: s.buffer, channel: -1, mapping: mapping, xRange: 0...bounds.width,
                             midY: bounds.midY, halfHeight: bounds.height / 2 - 2,
                             peakColor: c.withAlphaComponent(0.35), rmsColor: c.withAlphaComponent(0.7), scale: window?.backingScaleFactor ?? 2)
        for m in s.slices {
            Theme.NS.loop.withAlphaComponent(0.6).setFill()
            NSRect(x: CGFloat(Double(m) / fpp), y: 0, width: 1, height: bounds.height).fill()
        }
        if let sel = studio.editor.selection, sel.count > 0 {
            Theme.NS.selection.withAlphaComponent(0.25).setFill()
            NSRect(x: CGFloat(Double(sel.lowerBound) / fpp), y: 0, width: max(1, CGFloat(Double(sel.count) / fpp)), height: bounds.height).fill()
        }
        let ed = studio.editor
        let x0 = CGFloat(ed.scrollFrame / fpp)
        let w = CGFloat(Double(ed.width) * ed.framesPerPixel / fpp)
        let win = NSRect(x: max(0, x0), y: 0.5, width: min(bounds.width, max(4, w)), height: bounds.height - 1)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSRect(x: 0, y: 0, width: win.minX, height: bounds.height).fill()
        NSRect(x: win.maxX, y: 0, width: max(0, bounds.width - win.maxX), height: bounds.height).fill()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath(roundedRect: win.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { navigate(event) }
    override func mouseDragged(with event: NSEvent) { navigate(event) }

    private func navigate(_ event: NSEvent) {
        guard let s = sample else { return }
        let p = convert(event.locationInWindow, from: nil)
        let ed = studio.editor
        let fpp = Double(s.frameCount) / Double(max(1, bounds.width))
        let visible = Double(ed.width) * ed.framesPerPixel
        ed.scrollFrame = ed.clampScroll(Double(p.x) * fpp - visible / 2, totalFrames: s.frameCount)
    }
}

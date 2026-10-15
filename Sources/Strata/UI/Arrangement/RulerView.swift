import SwiftUI
import AppKit

struct RulerView: NSViewRepresentable {
    @ObservedObject var studio: Studio
    @ObservedObject var viewport: TimelineViewport

    func makeNSView(context: Context) -> RulerNSView { RulerNSView(studio: studio) }
    func updateNSView(_ v: RulerNSView, context: Context) { v.needsDisplay = true }
}

/// Bar/beat ruler with the loop brace on top. Click or drag below the brace to scrub,
/// drag in the brace to draw, move or resize the loop; double-click toggles it.
final class RulerNSView: NSView {
    private unowned let studio: Studio
    private enum Drag { case none, scrub, loopNew(Double), loopMove(LoopRegion, Double), loopStart, loopEnd }
    private var drag: Drag = .none
    private var trackingArea: NSTrackingArea?
    private let braceH: CGFloat = 13

    init(studio: Studio) {
        self.studio = studio
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .ruler }
    override func accessibilityLabel() -> String? {
        let p = project
        let fmt = MusicalTimeFormatter(project: p)
        return "Timeline ruler. Loop \(p.loop.enabled ? "on" : "off") from bar \(fmt.string(p.loop.start)) to \(fmt.string(p.loop.end))"
    }

    private var vp: TimelineViewport { studio.viewport }
    private var project: Project { studio.project }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = project
        let scale = window?.backingScaleFactor ?? 2
        NSGradient(starting: NSColor(hex: 0x1D2025), ending: NSColor(hex: 0x16181C))?.draw(in: bounds, angle: 90)

        // Loop brace
        let lx0 = vp.x(p.loop.start), lx1 = vp.x(p.loop.end)
        let brace = NSRect(x: lx0, y: 2, width: max(2, lx1 - lx0), height: braceH - 3)
        let loopColor = p.loop.enabled ? Theme.NS.loop : NSColor(white: 0.45, alpha: 1)
        let bracePath = NSBezierPath(roundedRect: brace, xRadius: 3, yRadius: 3)
        loopColor.withAlphaComponent(p.loop.enabled ? 0.85 : 0.35).setFill()
        bracePath.fill()
        if p.loop.enabled {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: Theme.NS.loop.withAlphaComponent(0.5).cgColor)
            loopColor.setStroke()
            bracePath.lineWidth = 0.5
            bracePath.stroke()
            ctx.restoreGState()
        }
        if brace.width > 60 {
            let len = NSAttributedString.label(String(format: "%.4g bars", p.loop.length / p.secondsPerBar), size: 8.5, weight: .bold,
                                               color: NSColor.black.withAlphaComponent(0.7))
            let w = len.size().width
            if brace.width > w + 16 { len.draw(at: NSPoint(x: brace.midX - w / 2, y: brace.minY - 1)) }
        }

        // Grid ticks and bar numbers
        let grid = GridMetrics(secondsPerBeat: p.secondsPerBeat, beatsPerBar: p.beatsPerBar, pixelsPerSecond: vp.pixelsPerSecond)
        let labelEvery = grid.labelEveryBars
        grid.forEachLine(from: vp.time(dirtyRect.minX - 40), to: vp.time(dirtyRect.maxX + 1)) { t, kind, bar in
            let x = (vp.x(t) * scale).rounded() / scale
            switch kind {
            case 0:
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
                ctx.fill(CGRect(x: x, y: braceH + 4, width: 1, height: bounds.height - braceH - 4))
                if bar % labelEvery == 0 {
                    let s = NSAttributedString.label("\(bar + 1)", size: 10, weight: .semibold,
                                                     color: NSColor.white.withAlphaComponent(0.78), mono: true)
                    s.draw(at: NSPoint(x: x + 4, y: braceH + 3))
                }
            case 1:
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
                ctx.fill(CGRect(x: x, y: bounds.height - 8, width: 1, height: 8))
            default:
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.09).cgColor)
                ctx.fill(CGRect(x: x, y: bounds.height - 4, width: 1, height: 4))
            }
        }

        Theme.NS.hairline.setFill()
        NSRect(x: dirtyRect.minX, y: bounds.height - 1, width: dirtyRect.width, height: 1).fill()
    }

    // MARK: Mouse

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at p: NSPoint) {
        if p.y < braceH + 2 {
            let lx0 = vp.x(project.loop.start), lx1 = vp.x(project.loop.end)
            if abs(p.x - lx0) < 6 || abs(p.x - lx1) < 6 { NSCursor.resizeLeftRight.set() }
            else if p.x > lx0 && p.x < lx1 { NSCursor.openHand.set() }
            else { NSCursor.crosshair.set() }
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = max(0, vp.time(p.x))
        let bypass = event.modifierFlags.contains(.command)
        if p.y < braceH + 2 {
            if event.clickCount == 2 { studio.toggleLoop(); return }
            let lx0 = vp.x(project.loop.start), lx1 = vp.x(project.loop.end)
            studio.beginGesture("Loop")
            if abs(p.x - lx0) < 6 { drag = .loopStart }
            else if abs(p.x - lx1) < 6 { drag = .loopEnd }
            else if p.x > lx0 && p.x < lx1 { drag = .loopMove(project.loop, t); NSCursor.closedHand.set() }
            else { drag = .loopNew(studio.snapTime(t, bypass: bypass)) }
        } else {
            drag = .scrub
            studio.seek(to: studio.snapTime(t, bypass: bypass))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = max(0, vp.time(p.x))
        let bypass = event.modifierFlags.contains(.command)
        let snapped = studio.snapTime(t, bypass: bypass)
        switch drag {
        case .scrub:
            studio.seek(to: snapped)
        case .loopNew(let anchor):
            if abs(snapped - anchor) > 0.01 { studio.setLoop(start: anchor, end: snapped) }
        case .loopMove(let original, let downT):
            let ns = max(0, studio.snapTime(original.start + (t - downT), bypass: bypass))
            studio.setLoop(start: ns, end: ns + original.length)
        case .loopStart:
            if snapped < project.loop.end - 0.01 { studio.setLoop(start: snapped, end: project.loop.end) }
        case .loopEnd:
            if snapped > project.loop.start + 0.01 { studio.setLoop(start: project.loop.start, end: snapped) }
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .scrub = drag {} else if case .none = drag {} else { studio.endGesture() }
        drag = .none
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if !handleTimelineScroll(event, viewport: vp, location: convert(event.locationInWindow, from: nil)) {
            // Vertical wheel over the ruler zooms, as in most DAWs.
            let dy = event.scrollingDeltaY
            if dy != 0 {
                vp.zoom(by: exp(Double(dy) * (event.hasPreciseScrollingDeltas ? 0.008 : 0.06)),
                        anchorX: convert(event.locationInWindow, from: nil).x)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        vp.zoom(by: 1 + Double(event.magnification), anchorX: convert(event.locationInWindow, from: nil).x)
    }
}

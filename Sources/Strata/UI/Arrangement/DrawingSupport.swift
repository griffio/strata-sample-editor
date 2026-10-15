import AppKit

/// Core Graphics waveform renderer shared by timeline clips and the sample editor.
/// Chooses between peak-pyramid columns (zoomed out), raw min/max (mid zoom) and
/// per-sample polylines with sample dots (deep zoom).
enum WaveformDrawing {
    struct Mapping {
        /// x position (points) where `frameAtOrigin` lies.
        var originX: CGFloat
        var frameAtOrigin: Double
        /// Source frames per point.
        var framesPerPoint: Double
        /// Only frames in this range are drawn.
        var frameLimit: Range<Double>

        func x(_ frame: Double) -> CGFloat { originX + CGFloat((frame - frameAtOrigin) / framesPerPoint) }
        func frame(_ x: CGFloat) -> Double { frameAtOrigin + Double(x - originX) * framesPerPoint }
    }

    static func draw(_ ctx: CGContext, buffer: SampleBuffer, channel: Int, mapping m: Mapping,
                     xRange: ClosedRange<CGFloat>, midY: CGFloat, halfHeight: CGFloat,
                     peakColor: NSColor, rmsColor: NSColor, lineColor: NSColor? = nil,
                     scale: CGFloat, gain: Float = 1) {
        let lo = max(xRange.lowerBound, m.x(m.frameLimit.lowerBound))
        let hi = min(xRange.upperBound, m.x(m.frameLimit.upperBound))
        guard hi > lo, buffer.frameCount > 0 else { return }
        let g = CGFloat(gain)
        let devicePixel = 1 / max(1, scale)
        let framesPerPixel = m.framesPerPoint * Double(devicePixel)

        if framesPerPixel < 1.2 {
            // Sample-accurate polyline.
            let firstFrame = max(Int(floor(m.frame(lo))) - 1, 0)
            let lastFrame = min(Int(ceil(m.frame(hi))) + 1, buffer.frameCount - 1)
            guard lastFrame > firstFrame else { return }
            let p = buffer.channel(max(0, channel))
            let other = channel < 0 ? buffer.channel(1) : nil
            let path = CGMutablePath()
            var points: [CGPoint] = []
            points.reserveCapacity(lastFrame - firstFrame + 1)
            for i in firstFrame...lastFrame {
                let v = other.map { (p[i] + $0[i]) * 0.5 } ?? p[i]
                points.append(CGPoint(x: m.x(Double(i)), y: midY - CGFloat(v) * halfHeight * g))
            }
            path.addLines(between: points)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: lo, y: midY - halfHeight - 2, width: hi - lo, height: halfHeight * 2 + 4))
            ctx.addPath(path)
            ctx.setStrokeColor((lineColor ?? rmsColor).cgColor)
            ctx.setLineWidth(1.25)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            let pointsPerFrame = 1 / m.framesPerPoint
            if pointsPerFrame > 7 {
                ctx.setFillColor((lineColor ?? rmsColor).cgColor)
                for pt in points {
                    ctx.fillEllipse(in: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4))
                }
            }
            ctx.restoreGState()
            return
        }

        let peaks = buffer.peaks
        var upper: [CGPoint] = [], lower: [CGPoint] = [], rU: [CGPoint] = [], rL: [CGPoint] = []
        let count = Int(((hi - lo) / devicePixel).rounded(.up)) + 1
        upper.reserveCapacity(count); lower.reserveCapacity(count); rU.reserveCapacity(count); rL.reserveCapacity(count)
        var x = (lo / devicePixel).rounded(.down) * devicePixel
        while x <= hi {
            let a = max(m.frameLimit.lowerBound, m.frame(x))
            let b = min(m.frameLimit.upperBound, m.frame(x + devicePixel))
            if b > a {
                let col = peaks.column(channel: channel, from: a, to: b)
                let maxV = CGFloat(max(col.maxV, 0)) * g, minV = CGFloat(min(col.minV, 0)) * g
                let r = min(CGFloat(col.rms) * g, max(maxV, -minV))
                // Always show at least a hairline so silence is visible.
                upper.append(CGPoint(x: x, y: midY - max(maxV * halfHeight, 0.5)))
                lower.append(CGPoint(x: x, y: midY - min(minV * halfHeight, -0.5)))
                rU.append(CGPoint(x: x, y: midY - r * halfHeight))
                rL.append(CGPoint(x: x, y: midY + r * halfHeight))
            }
            x += devicePixel
        }
        guard upper.count > 1 else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: lo, y: midY - halfHeight - 1, width: hi - lo, height: halfHeight * 2 + 2))
        let peakPath = CGMutablePath()
        peakPath.addLines(between: upper + lower.reversed())
        peakPath.closeSubpath()
        ctx.addPath(peakPath)
        ctx.setFillColor(peakColor.cgColor)
        ctx.fillPath()
        let rmsPath = CGMutablePath()
        rmsPath.addLines(between: rU + rL.reversed())
        rmsPath.closeSubpath()
        ctx.addPath(rmsPath)
        ctx.setFillColor(rmsColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Draws live recording peaks (max |x| per bin) as a mirrored shape.
    static func drawLive(_ ctx: CGContext, peaks: [Float], framesPerBin: Int, originX: CGFloat, framesPerPoint: Double,
                         xRange: ClosedRange<CGFloat>, midY: CGFloat, halfHeight: CGFloat, color: NSColor) {
        guard !peaks.isEmpty else { return }
        let binWidth = CGFloat(Double(framesPerBin) / framesPerPoint)
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        let step = max(1, Int(1 / max(0.0001, binWidth)))
        var i = 0
        while i < peaks.count {
            let x = originX + CGFloat(i) * binWidth
            if x > xRange.upperBound { break }
            var v: Float = 0
            for k in i..<min(peaks.count, i + step) { v = max(v, peaks[k]) }
            if x >= xRange.lowerBound - binWidth * CGFloat(step) {
                upper.append(CGPoint(x: x, y: midY - CGFloat(min(1, v)) * halfHeight - 0.5))
                lower.append(CGPoint(x: x, y: midY + CGFloat(min(1, v)) * halfHeight + 0.5))
            }
            i += step
        }
        guard upper.count > 1 else { return }
        let path = CGMutablePath()
        path.addLines(between: upper + lower.reversed())
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
}

/// Picks musically sensible grid densities for the current zoom level.
struct GridMetrics {
    let secondsPerBeat: Double
    let beatsPerBar: Int
    let pixelsPerSecond: Double

    var pixelsPerBeat: Double { secondsPerBeat * pixelsPerSecond }
    var pixelsPerBar: Double { pixelsPerBeat * Double(beatsPerBar) }

    /// Every n-th bar gets a numbered label.
    var labelEveryBars: Int {
        var n = 1
        while pixelsPerBar * Double(n) < 46 { n *= 2 }
        return n
    }

    /// Bars between drawn bar lines.
    var barLineEvery: Int {
        var n = 1
        while pixelsPerBar * Double(n) < 10 { n *= 2 }
        return n
    }

    /// Beat fraction for the finest drawn subdivision, nil when too dense.
    var subdivision: Double? {
        for sub in [0.125, 0.25, 0.5, 1.0] where pixelsPerBeat * sub >= 14 { return sub }
        return nil
    }

    func forEachLine(from t0: Double, to t1: Double, _ body: (_ time: Double, _ kind: Int, _ barIndex: Int) -> Void) {
        // kind: 0 = bar, 1 = beat, 2 = subdivision
        let barSeconds = secondsPerBeat * Double(beatsPerBar)
        let firstBar = max(0, Int(floor(t0 / barSeconds)))
        let lastBar = Int(ceil(t1 / barSeconds))
        guard lastBar >= firstBar else { return }
        let every = barLineEvery
        for bar in firstBar...lastBar {
            let tb = Double(bar) * barSeconds
            if bar % every == 0 { body(tb, 0, bar) }
            guard let sub = subdivision else { continue }
            let steps = Int((Double(beatsPerBar) / sub).rounded())
            for s in 1..<max(1, steps) {
                let beatPos = Double(s) * sub
                let t = tb + beatPos * secondsPerBeat
                if t < t0 || t > t1 { continue }
                let isBeat = abs(beatPos - beatPos.rounded()) < 1e-6
                body(t, isBeat ? 1 : 2, bar)
            }
        }
    }
}

/// NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true,
         state: NSControl.StateValue = .off, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        isEnabled = enabled
        self.state = state
        if let s = symbol { image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSMenu {
    func add(_ title: String, symbol: String? = nil, enabled: Bool = true, checked: Bool = false, _ handler: @escaping () -> Void) {
        addItem(ActionMenuItem(title, enabled: enabled, state: checked ? .on : .off, symbol: symbol, handler: handler))
    }

    func submenu(_ title: String, symbol: String? = nil, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let s = symbol { item.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
        let sub = NSMenu(title: title)
        build(sub)
        item.submenu = sub
        addItem(item)
    }
}

enum Cursors {
    static func symbol(_ name: String, size: CGFloat = 15) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return .crosshair
        }
        let img = NSImage(size: NSSize(width: base.size.width + 4, height: base.size.height + 4), flipped: false) { rect in
            // White glyph with dark halo, legible over any waveform.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 2
            shadow.set()
            let tinted = base.copy() as! NSImage
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: rect.insetBy(dx: 2, dy: 2))
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: img.size.width / 2, y: img.size.height / 2))
    }

    static let blade = symbol("scissors")
    static let stretch = symbol("arrow.left.and.right.righttriangle.left.righttriangle.right", size: 14)
    static let fade = symbol("arrow.up.right.and.arrow.down.left", size: 12)
}

extension NSAttributedString {
    static func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor, mono: Bool = false) -> NSAttributedString {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }
}

/// Pasteboard payloads for dragging samples and regions onto the timeline.
enum DragPayload {
    static let samplePrefix = "strata.sample:"
    static let regionPrefix = "strata.region:"

    static func sample(_ id: UUID) -> String { samplePrefix + id.uuidString }
    static func region(_ id: UUID, _ range: Range<Int>) -> String { "\(regionPrefix)\(id.uuidString):\(range.lowerBound):\(range.upperBound)" }

    static func parse(_ s: String) -> (UUID, Range<Int>?)? {
        if s.hasPrefix(samplePrefix), let id = UUID(uuidString: String(s.dropFirst(samplePrefix.count))) { return (id, nil) }
        if s.hasPrefix(regionPrefix) {
            let parts = s.dropFirst(regionPrefix.count).split(separator: ":")
            if parts.count == 3, let id = UUID(uuidString: String(parts[0])), let a = Int(parts[1]), let b = Int(parts[2]), b > a {
                return (id, a..<b)
            }
        }
        return nil
    }
}

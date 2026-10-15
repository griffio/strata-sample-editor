import SwiftUI
import AppKit

// MARK: - Level meter

/// Segmented stereo meter with a green → amber → red gradient and dB scaling.
struct LevelMeter: View {
    let left: Float
    let right: Float
    var vertical = false
    var segments = 24
    var gap: CGFloat = 1.5

    static func normalized(_ v: Float) -> CGFloat {
        guard v > 0.00001 else { return 0 }
        let db = 20 * log10(Double(v))
        return CGFloat(min(1, max(0, (db + 54) / 57)))   // -54 dB … +3 dB
    }

    var body: some View {
        Canvas { ctx, size in
            let bars = [Self.normalized(left), Self.normalized(right)]
            let lanes = CGFloat(bars.count)
            let laneGap: CGFloat = 2
            for (i, level) in bars.enumerated() {
                let lane: CGRect
                if vertical {
                    let w = (size.width - laneGap * (lanes - 1)) / lanes
                    lane = CGRect(x: CGFloat(i) * (w + laneGap), y: 0, width: w, height: size.height)
                } else {
                    let h = (size.height - laneGap * (lanes - 1)) / lanes
                    lane = CGRect(x: 0, y: CGFloat(i) * (h + laneGap), width: size.width, height: h)
                }
                let total = vertical ? lane.height : lane.width
                let seg = (total - gap * CGFloat(segments - 1)) / CGFloat(segments)
                let lit = Int((level * CGFloat(segments)).rounded(.up))
                for s in 0..<segments {
                    let pos = CGFloat(s) * (seg + gap)
                    let r = vertical
                        ? CGRect(x: lane.minX, y: lane.maxY - pos - seg, width: lane.width, height: seg)
                        : CGRect(x: lane.minX + pos, y: lane.minY, width: seg, height: lane.height)
                    let frac = Double(s) / Double(segments - 1)
                    let color: Color = frac > 0.9 ? Theme.record : (frac > 0.72 ? Theme.loop : Color(hex: 0x3CE38A))
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(s < lit ? color : Color.white.opacity(0.06)))
                }
            }
        }
    }
}

// MARK: - Knob

/// Rotary knob with a glowing value arc. Drag vertically; ⌥-click resets.
struct Knob: View {
    @Binding var value: Double          // 0…1 (or -1…1 when bipolar)
    var bipolar = false
    var color: Color = Theme.accent
    var size: CGFloat = 26
    var defaultValue: Double = 0
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    @State private var dragStart: Double?
    @State private var hover = false

    private var unit: Double { bipolar ? (value + 1) / 2 : value }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x30343C), Color(hex: 0x1C1E23)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(Color.white.opacity(hover ? 0.18 : 0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(90))
                .padding(-3)
            arc
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(90))
                .padding(-3)
                .shadow(color: color.opacity(0.6), radius: 3)
            Capsule()
                .fill(Theme.text)
                .frame(width: 2, height: size * 0.28)
                .offset(y: -size * 0.24)
                .rotationEffect(.degrees(-135 + 270 * unit))
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onHover { hover = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil {
                        if NSEvent.modifierFlags.contains(.option) {
                            onBegin(); value = defaultValue; onEnd()
                            dragStart = .infinity
                            return
                        }
                        dragStart = value
                        onBegin()
                    }
                    guard let start = dragStart, start.isFinite else { return }
                    let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1
                    let range = bipolar ? 2.0 : 1.0
                    let delta = Double(-g.translation.height) / 150 * range * fine
                    value = min(bipolar ? 1 : 1, max(bipolar ? -1 : 0, start + delta))
                }
                .onEnded { _ in
                    if dragStart?.isFinite == true { onEnd() }
                    dragStart = nil
                }
        )
    }

    private var arc: some Shape {
        let from: Double, to: Double
        if bipolar {
            let mid = 0.5
            from = 0.125 + 0.75 * min(mid, unit)
            to = 0.125 + 0.75 * max(mid, unit)
        } else {
            from = 0.125
            to = 0.125 + 0.75 * unit
        }
        return Circle().trim(from: from, to: to)
    }
}

// MARK: - Horizontal fader

/// Slim horizontal fader with a glowing fill and a cap. ⌥-click resets to unity.
struct MiniFader: View {
    @Binding var value: Double   // 0…1 maps to linear gain 0…maxGain via curve
    var color: Color
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var defaultValue: Double = 0.8
    @State private var dragging = false
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = CGFloat(value) * (w - 10) + 5
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07)).frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, x), height: 4)
                    .shadow(color: color.opacity(0.5), radius: 3)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xF4F5F7), Color(hex: 0xB9BDC6)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 9, height: 14)
                    .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                    .scaleEffect(dragging || hover ? 1.08 : 1)
                    .offset(x: x - 4.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging {
                            dragging = true
                            onBegin()
                            if NSEvent.modifierFlags.contains(.option) { value = defaultValue; return }
                        }
                        value = Double(min(1, max(0, (g.location.x - 5) / (w - 10))))
                    }
                    .onEnded { _ in dragging = false; onEnd() }
            )
        }
        .frame(height: 16)
    }

    /// Perceptual fader curve: position 0.8 ≙ unity, 1.0 ≙ +6 dB.
    static func gain(fromPosition p: Double) -> Float {
        guard p > 0.001 else { return 0 }
        let db = p >= 0.8 ? (p - 0.8) / 0.2 * 6 : -60 * pow((0.8 - p) / 0.8, 1.6)
        return Float(pow(10, db / 20))
    }

    static func position(fromGain g: Float) -> Double {
        guard g > 0.001 else { return 0 }
        let db = 20 * log10(Double(g))
        if db >= 0 { return min(1, 0.8 + db / 6 * 0.2) }
        return max(0, 0.8 - 0.8 * pow(-db / 60, 1 / 1.6))
    }
}

// MARK: - Scrubbable number

/// A value you can drag vertically to change, or double-click to type into.
struct ScrubField: View {
    let value: Double
    let format: (Double) -> String
    var step: Double = 1
    var range: ClosedRange<Double> = -1_000_000...1_000_000
    var font: Font = Theme.mono(12)
    var color: Color = Theme.text
    var onBegin: () -> Void = {}
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}
    @State private var start: Double?
    @State private var editing = false
    @State private var text = ""
    @State private var hover = false

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text, onCommit: commit)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundColor(color)
                    .multilineTextAlignment(.center)
                    .onExitCommand { editing = false }
            } else {
                Text(format(value))
                    .font(font)
                    .foregroundColor(color)
                    .monospacedDigit()
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(hover ? Color.white.opacity(0.06) : .clear))
                    .onHover { h in
                        hover = h
                        if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { g in
                                if start == nil { start = value; onBegin() }
                                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                                let v = (start ?? value) + Double(-g.translation.height / 3).rounded() * step * fine
                                onChange(min(range.upperBound, max(range.lowerBound, v)))
                            }
                            .onEnded { _ in start = nil; onEnd() }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        text = format(value).filter { "0123456789.-".contains($0) }
                        editing = true
                    })
            }
        }
    }

    private func commit() {
        editing = false
        if let v = Double(text.trimmingCharacters(in: .whitespaces)) {
            onBegin()
            onChange(min(range.upperBound, max(range.lowerBound, v)))
            onEnd()
        }
    }
}

// MARK: - Waveform thumbnail

/// Lightweight waveform thumbnail rendered from the peak pyramid.
struct WaveformThumbnail: View {
    let buffer: SampleBuffer
    var range: Range<Int>? = nil
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let r = (range ?? 0..<buffer.frameCount).clamped(to: 0..<buffer.frameCount)
            guard r.count > 0, size.width > 2 else { return }
            let peaks = buffer.peaks
            let cols = Int(size.width)
            let fpp = Double(r.count) / Double(cols)
            let mid = size.height / 2
            var top = Path(), rms = Path()
            var upper: [CGPoint] = [], lower: [CGPoint] = [], rmsU: [CGPoint] = [], rmsL: [CGPoint] = []
            for c in 0..<cols {
                let a = Double(r.lowerBound) + Double(c) * fpp
                let col = peaks.column(channel: -1, from: a, to: a + fpp)
                let x = CGFloat(c) + 0.5
                upper.append(CGPoint(x: x, y: mid - CGFloat(max(0, col.maxV)) * mid * 0.95))
                lower.append(CGPoint(x: x, y: mid - CGFloat(min(0, col.minV)) * mid * 0.95))
                rmsU.append(CGPoint(x: x, y: mid - CGFloat(col.rms) * mid * 0.95))
                rmsL.append(CGPoint(x: x, y: mid + CGFloat(col.rms) * mid * 0.95))
            }
            top.addLines(upper + lower.reversed())
            top.closeSubpath()
            rms.addLines(rmsU + rmsL.reversed())
            rms.closeSubpath()
            ctx.fill(top, with: .color(color.opacity(0.55)))
            ctx.fill(rms, with: .color(color))
        }
    }
}

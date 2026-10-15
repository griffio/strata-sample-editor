import SwiftUI

/// Centre toolbar cluster: transport buttons + LCD.
struct TransportBar: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                TransportButton(symbol: "backward.end.fill", help: "Return to Start (↩)") { studio.returnToStart() }
                TransportButton(symbol: "stop.fill", help: "Stop (Space)") { studio.stop() }
                TransportButton(symbol: studio.isPlaying ? "pause.fill" : "play.fill", help: "Play / Pause (Space)",
                                active: studio.isPlaying, activeColor: Color(hex: 0x3CE38A)) { studio.togglePlay() }
                RecordButton()
            }
            .padding(3)
            .background(Capsule().fill(Color.black.opacity(0.28)))
            .overlay(Capsule().strokeBorder(Theme.hairline))

            HStack(spacing: 2) {
                TransportButton(symbol: "repeat", help: "Loop (L)", active: studio.project.loop.enabled, activeColor: Theme.loop) { studio.toggleLoop() }
                TransportButton(symbol: "metronome.fill", help: "Metronome (K)", active: studio.project.metronome, activeColor: Theme.accent) { studio.toggleMetronome() }
                TransportButton(symbol: "1.circle", help: "Count-in one bar before recording", active: studio.project.countIn, activeColor: Theme.accent) {
                    studio.perform("Count-in") { $0.countIn.toggle() }
                }
            }
            .padding(3)
            .background(Capsule().fill(Color.black.opacity(0.28)))
            .overlay(Capsule().strokeBorder(Theme.hairline))

            LCDDisplay(clock: studio.clock)
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let help: String
    var active = false
    var activeColor: Color = Theme.accent
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(active ? activeColor : (hover ? Theme.text : Theme.textSecondary))
                .frame(width: 30, height: 24)
                .background(Circle().fill(active ? activeColor.opacity(0.16) : (hover ? Color.white.opacity(0.08) : .clear)).frame(width: 26, height: 26))
                .shadow(color: active ? activeColor.opacity(0.6) : .clear, radius: 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct RecordButton: View {
    @EnvironmentObject var studio: Studio
    @State private var hover = false
    @State private var blink = false

    var body: some View {
        Button { studio.toggleRecord() } label: {
            ZStack {
                Circle()
                    .fill(studio.isRecording ? Theme.record : Theme.record.opacity(hover ? 0.22 : 0.12))
                    .frame(width: 26, height: 26)
                    .shadow(color: studio.isRecording ? Theme.record.opacity(blink ? 0.9 : 0.4) : .clear, radius: blink ? 9 : 4)
                Circle()
                    .fill(studio.isRecording ? Color.white : Theme.record)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 30, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(studio.armedTrack != nil ? "Record onto “\(studio.armedTrack!.name)” (R)" : "Capture to Library (R) — arm a track to record onto the timeline")
        .onChange(of: studio.isRecording) { rec in
            if rec { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { blink = true } }
            else { blink = false }
        }
    }
}

/// The glowing position display: bars.beats.sixteenths, clock time, tempo and metre.
struct LCDDisplay: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var clock: TransportClock

    var body: some View {
        let fmt = MusicalTimeFormatter(project: studio.project)
        let c = fmt.components(clock.position)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(format: "%3d", c.bar)).foregroundColor(lcd)
                    Text(".").foregroundColor(lcd.opacity(0.5))
                    Text("\(c.beat)").foregroundColor(lcd)
                    Text(".").foregroundColor(lcd.opacity(0.5))
                    Text("\(c.sixteenth)").foregroundColor(lcd)
                    Text(String(format: " %03d", c.ticks)).foregroundColor(lcd.opacity(0.45)).font(Theme.mono(10, weight: .medium))
                }
                .font(Theme.mono(16, weight: .semibold))
                Text(formatClock(clock.position))
                    .font(Theme.mono(9.5, weight: .medium))
                    .foregroundColor(lcd.opacity(0.55))
            }
            .frame(width: 128, alignment: .leading)
            .padding(.leading, 12)

            divider

            VStack(spacing: 0) {
                ScrubField(value: studio.project.bpm, format: { String(format: "%.1f", $0) }, step: 1, range: 30...300,
                           font: Theme.mono(15, weight: .semibold), color: lcd,
                           onBegin: { studio.beginGesture("Tempo") },
                           onChange: { v in studio.live { p in p.bpm = v } },
                           onEnd: { studio.endGesture() })
                Text("BPM").font(.system(size: 8, weight: .heavy)).kerning(1).foregroundColor(lcd.opacity(0.45))
            }
            .frame(width: 62)
            .help("Drag or double-click to change tempo")

            divider

            Menu {
                ForEach([(2, 4), (3, 4), (4, 4), (5, 4), (6, 8), (7, 8)], id: \.0) { n, d in
                    Button("\(n)/\(d)") { studio.perform("Time Signature") { $0.beatsPerBar = n; $0.beatUnit = d } }
                }
            } label: {
                VStack(spacing: 0) {
                    Text("\(studio.project.beatsPerBar)/\(studio.project.beatUnit)")
                        .font(Theme.mono(14, weight: .semibold))
                        .foregroundColor(lcd)
                    Text("TIME").font(.system(size: 8, weight: .heavy)).kerning(1).foregroundColor(lcd.opacity(0.45))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 48)
            .padding(.trailing, 6)
        }
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: 0x070809).shadow(.inner(color: .black.opacity(0.9), radius: 3, y: 1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.03), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: lcd.opacity(0.08), radius: 8)
    }

    private var lcd: Color { studio.isRecording ? Color(hex: 0xFF7A7A) : Color(hex: 0x7FE7FF) }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1, height: 24)
    }
}

/// Trailing toolbar: edit tools, snap, zoom, master meter.
struct ToolsBar: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                ForEach(EditTool.allCases, id: \.self) { t in
                    IconButton(symbol: t.symbol, help: t.label, active: studio.tool == t, size: 12, width: 26, height: 22) { studio.tool = t }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))

            Menu {
                Picker("Snap", selection: $studio.snap) {
                    ForEach(SnapGrid.allCases) { g in Text(g.label).tag(g) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "squareshape.split.3x3").font(.system(size: 10.5, weight: .semibold))
                    Text(studio.snap.label).font(.system(size: 11, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Snap grid — hold ⌘ while dragging to bypass")

            HStack(spacing: 0) {
                IconButton(symbol: "minus.magnifyingglass", help: "Zoom Out", size: 11.5, width: 24, height: 22) { studio.viewport.zoom(by: 1 / 1.5, anchorX: studio.viewport.laneWidth / 2) }
                IconButton(symbol: "plus.magnifyingglass", help: "Zoom In", size: 11.5, width: 24, height: 22) { studio.viewport.zoom(by: 1.5, anchorX: studio.viewport.laneWidth / 2) }
                IconButton(symbol: "arrow.left.and.right.square", help: "Zoom to Fit (Z)", size: 11.5, width: 24, height: 22) { studio.zoomToFit() }
            }

            IconButton(symbol: "rectangle.bottomhalf.inset.filled", help: "Show Sample Editor", active: studio.showEditor, size: 12, width: 26, height: 22) {
                withAnimation(.easeInOut(duration: 0.2)) { studio.showEditor.toggle() }
            }

            MasterMeter(meters: studio.meters)
        }
    }
}

private struct MasterMeter: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var meters: MeterStore

    var body: some View {
        HStack(spacing: 6) {
            LevelMeter(left: meters.master.0, right: meters.master.1, segments: 18)
                .frame(width: 70, height: 10)
            Knob(value: Binding(get: { MiniFader.position(fromGain: studio.project.masterVolume) },
                                set: { v in studio.live { $0.masterVolume = MiniFader.gain(fromPosition: v) } }),
                 color: Color(hex: 0x3CE38A), size: 18, defaultValue: 0.8,
                 onBegin: { studio.beginGesture("Master Volume") }, onEnd: { studio.endGesture() })
                .help("Master: \(dbString(studio.project.masterVolume))")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
    }
}

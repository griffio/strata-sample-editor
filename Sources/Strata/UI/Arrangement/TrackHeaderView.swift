import SwiftUI

struct TrackHeaderView: View {
    @EnvironmentObject var studio: Studio
    let track: Track
    let index: Int
    @State private var name = ""
    @State private var resizeStart: Double?
    @FocusState private var nameFocused: Bool

    private var color: Color { Theme.trackColor(track.colorIndex) }
    private var selected: Bool { studio.selectedTrackID == track.id }

    var body: some View {
        HStack(spacing: 0) {
            // Colour spine
            ZStack {
                Rectangle().fill(color)
                if track.armed {
                    Rectangle().fill(Theme.record).opacity(studio.isRecording ? 1 : 0.85)
                }
            }
            .frame(width: 4)
            .shadow(color: (track.armed ? Theme.record : color).opacity(selected ? 0.8 : 0.0), radius: 4)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Text("\(index + 1)")
                        .font(Theme.mono(9.5, weight: .bold))
                        .foregroundColor(Theme.textTertiary)
                        .frame(width: 14, alignment: .leading)
                    TextField("Track", text: $name, onCommit: commitName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .focused($nameFocused)
                        .onChange(of: nameFocused) { focused in if !focused { commitName() } }
                    Spacer(minLength: 2)
                    PillToggle(label: "M", on: track.mute, color: Theme.mute, help: "Mute") {
                        studio.updateTrack(track.id, track.mute ? "Unmute" : "Mute") { $0.mute.toggle() }
                    }
                    PillToggle(label: "S", on: track.solo, color: Theme.solo, help: "Solo") {
                        studio.updateTrack(track.id, track.solo ? "Unsolo" : "Solo") { $0.solo.toggle() }
                    }
                    PillToggle(label: "", on: track.armed, color: Theme.record, help: "Arm for Recording", symbol: "circle.fill") {
                        studio.toggleArm(track.id)
                    }
                }
                if track.height >= 64 {
                    HStack(spacing: 9) {
                        Knob(value: Binding(get: { Double(track.pan) },
                                            set: { v in studio.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].pan = Float(v) } } }),
                             bipolar: true, color: color, size: 22, defaultValue: 0,
                             onBegin: { studio.beginGesture("Pan") }, onEnd: { studio.endGesture() },
                             accessibilityName: "\(track.name) pan", accessibilityText: panLabel)
                            .help(panLabel)
                        VStack(alignment: .leading, spacing: 1) {
                            MiniFader(value: Binding(get: { MiniFader.position(fromGain: track.volume) },
                                                     set: { v in studio.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].volume = MiniFader.gain(fromPosition: v) } } }),
                                      color: color, onBegin: { studio.beginGesture("Volume") }, onEnd: { studio.endGesture() },
                                      accessibilityName: "\(track.name) volume")
                            HStack {
                                Text(dbString(track.volume))
                                Spacer()
                                Text(panLabel)
                            }
                            .font(Theme.mono(8.5))
                            .foregroundColor(Theme.textTertiary)
                        }
                        TrackMeter(meters: studio.meters, trackID: track.id)
                            .frame(width: 9, height: 28)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? Color(hex: 0x1E2126) : Theme.panel)
        .overlay(alignment: .bottom) { resizeHandle }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairlineStrong).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { studio.selectedTrackID = track.id; studio.focus = .arrangement }
        .onAppear { name = track.name }
        .onChange(of: track.name) { name = $0 }
        .contextMenu { contextMenu }
    }

    private var panLabel: String {
        let p = Int((track.pan * 100).rounded())
        return p == 0 ? "C" : (p < 0 ? "L\(-p)" : "R\(p)")
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { name = track.name; return }
        if n != track.name { studio.updateTrack(track.id, "Rename Track") { $0.name = n } }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.top, 4)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { h in if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if resizeStart == nil { resizeStart = track.height; studio.beginGesture("Track Height") }
                        let h = min(260, max(44, (resizeStart ?? 92) + g.translation.height))
                        studio.live { p in if let i = p.trackIndex(track.id) { p.tracks[i].height = h } }
                    }
                    .onEnded { _ in resizeStart = nil; studio.endGesture() }
            )
    }

    @ViewBuilder private var contextMenu: some View {
        Menu("Color") {
            ForEach(0..<Theme.trackColors.count, id: \.self) { i in
                Button(Theme.colorNames[i]) { studio.updateTrack(track.id, "Track Color") { $0.colorIndex = i } }
            }
        }
        Menu("Height") {
            Button("Compact") { studio.updateTrack(track.id, "Track Height") { $0.height = 52 } }
            Button("Normal") { studio.updateTrack(track.id, "Track Height") { $0.height = 92 } }
            Button("Large") { studio.updateTrack(track.id, "Track Height") { $0.height = 150 } }
        }
        Divider()
        Button("Duplicate Track") { studio.duplicateTrack(track.id) }
        Button("Move Up") { studio.moveTrack(track.id, by: -1) }.disabled(index == 0)
        Button("Move Down") { studio.moveTrack(track.id, by: 1) }.disabled(index == studio.project.tracks.count - 1)
        Divider()
        Button("Select All Clips on Track") { studio.selectedClips = Set(track.clips.map(\.id)) }
        Divider()
        Button("Delete Track", role: .destructive) { studio.deleteTrack(track.id) }
    }
}

struct TrackMeter: View {
    @ObservedObject var meters: MeterStore
    let trackID: UUID

    var body: some View {
        let v = meters.tracks[trackID] ?? (0, 0)
        LevelMeter(left: v.0, right: v.1, vertical: true, segments: 14, gap: 1)
    }
}

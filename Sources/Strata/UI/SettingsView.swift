import SwiftUI

struct SettingsView: View {
    @ObservedObject private var devices = AudioDevices.shared
    @AppStorage("outputDeviceUID") private var outputUID = ""
    @AppStorage("metronomeLevel") private var metronomeLevel = 0.5
    @AppStorage("monitorLatencyHint") private var showLatency = true

    var body: some View {
        TabView {
            Form {
                Picker("Output device", selection: $outputUID) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(devices.outputs) { d in
                        Text(d.name).tag(d.uid)
                    }
                }
                Slider(value: $metronomeLevel, in: 0...1) { Text("Metronome level") }
                LabeledContent("Project format") { Text("48 kHz · 32-bit float · stereo") }
                LabeledContent("Grab buffer") { Text("Last 60 seconds of the active source") }
                Text("Strata records every source at 48 kHz internally and converts on the fly, so devices running at 44.1, 96 or 16 kHz can be mixed freely.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Audio", systemImage: "hifispeaker.2") }

            ShortcutsList()
                .padding()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 420)
        .preferredColorScheme(.dark)
    }
}

struct ShortcutsList: View {
    static let items: [(String, String)] = [
        ("Space", "Play / Pause"),
        ("↩", "Return to start (loop start)"),
        ("R", "Record (armed track) / capture to Library"),
        ("L", "Toggle loop"),
        ("K", "Toggle metronome"),
        ("S", "Split selected clips at playhead · add slice in editor"),
        ("V / B / T", "Pointer · Blade · Stretch tool"),
        ("⌥-drag edge", "Stretch clip (time-stretch)"),
        ("⌥-drag clip", "Duplicate clip"),
        ("⌘-drag", "Bypass snap"),
        ("⌘-scroll / pinch", "Zoom around the cursor"),
        ("⌥-scroll (editor)", "Vertical waveform zoom"),
        ("← / →", "Nudge selection by grid (⇧ for 1 ms)"),
        ("⌫", "Delete clips · delete audio in editor"),
        ("M", "Add slice marker"),
        ("P", "Preview editor selection"),
        ("Z", "Zoom to fit"),
        ("F", "Follow playhead"),
        ("⌘D", "Duplicate"),
        ("⌘E", "Split at playhead"),
        ("⌘T", "New track"),
        ("⌘I", "Import audio"),
        ("⇧⌘E", "Export mixdown"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Self.items, id: \.0) { key, action in
                    HStack(alignment: .firstTextBaseline) {
                        Text(key)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.accent)
                            .frame(width: 150, alignment: .leading)
                        Text(action).font(.system(size: 12)).foregroundColor(Theme.text)
                        Spacer()
                    }
                }
            }
            .padding(4)
        }
    }
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keyboard Shortcuts").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ShortcutsList()
        }
        .padding(22)
        .frame(width: 480, height: 520)
        .background(Theme.panel)
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            SourcePanel(capture: studio.capture, devices: AudioDevices.shared, meters: studio.meters)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            LibraryPanel()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }
}

// MARK: - Sources

private struct SourcePanel: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var capture: CaptureService
    @ObservedObject var devices: AudioDevices
    @ObservedObject var meters: MeterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: "Sources", trailing: AnyView(
                IconButton(symbol: "arrow.clockwise", help: "Refresh devices", size: 10, width: 20, height: 18) {
                    devices.refresh(); capture.refreshShareableApps()
                }))

            VStack(spacing: 2) {
                SourceRow(symbol: "macwindow.on.rectangle", title: systemTitle, subtitle: "What your Mac is playing",
                          selected: isSystemSelected, status: isSystemSelected ? capture.status : nil) {
                    capture.select(.system(bundleID: nil))
                } accessory: {
                    Menu {
                        Button("All Apps") { capture.select(.system(bundleID: nil)) }
                        if !capture.shareableApps.isEmpty { Divider() }
                        ForEach(capture.shareableApps) { app in
                            Button(app.name) { capture.select(.system(bundleID: app.id)) }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .help("Capture a single app")
                    .onAppear { if capture.shareableApps.isEmpty { capture.refreshShareableApps() } }
                }
                ForEach(devices.inputs) { d in
                    SourceRow(symbol: d.symbol, title: d.name, subtitle: d.detail,
                              selected: capture.source == .device(uid: d.uid),
                              status: capture.source == .device(uid: d.uid) ? capture.status : nil) {
                        capture.select(.device(uid: d.uid))
                    } accessory: { EmptyView() }
                }
            }

            if capture.source != .none {
                LiveSourceMonitor(capture: capture, meters: meters)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: capture.source)
    }

    private var isSystemSelected: Bool {
        if case .system = capture.source { return true }
        return false
    }

    private var systemTitle: String {
        if case .system(let id?) = capture.source { return capture.shareableApps.first { $0.id == id }?.name ?? "App Audio" }
        return "System Audio"
    }
}

private struct SourceRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool
    let status: CaptureService.Status?
    let action: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.18) : Color.white.opacity(0.05))
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(selected ? Theme.accent : Theme.textSecondary)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(statusText ?? subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            accessory()
            if selected, status == .running {
                Circle().fill(Color(hex: 0x3CE38A)).frame(width: 6, height: 6)
                    .shadow(color: Color(hex: 0x3CE38A), radius: 3)
            } else if status == .starting {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white.opacity(0.06) : (hover ? Color.white.opacity(0.035) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }

    private var statusText: String? {
        switch status {
        case .failed?: return "Unavailable"
        case .permissionDenied?: return "Permission needed"
        case .starting?: return "Connecting…"
        default: return nil
        }
    }

    private var statusColor: Color {
        switch status {
        case .failed?, .permissionDenied?: return Theme.record
        default: return Theme.textTertiary
        }
    }
}

/// Meter, scrolling scope, channel routing and capture actions for the active source.
private struct LiveSourceMonitor: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var capture: CaptureService
    @ObservedObject var meters: MeterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch capture.status {
            case .failed(let msg), .permissionDenied(let msg):
                VStack(alignment: .leading, spacing: 6) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .permissionDenied = capture.status {
                        Button("Open Privacy Settings") { openPrivacySettings() }
                            .controlSize(.small)
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.record.opacity(0.10)))
            default:
                EmptyView()
            }

            ScopeView(values: meters.scope, active: capture.isCapturing)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            LevelMeter(left: meters.input.0, right: meters.input.1, segments: 32)
                .frame(height: 9)

            HStack(spacing: 6) {
                if capture.sourceChannelCount > 1 {
                    Menu {
                        ForEach(0..<capture.sourceChannelCount, id: \.self) { ch in
                            Button("Input \(ch + 1) (Mono)") { capture.firstChannel = ch; capture.stereo = false }
                        }
                        Divider()
                        ForEach(Array(stride(from: 0, to: capture.sourceChannelCount - 1, by: 2)), id: \.self) { ch in
                            Button("Inputs \(ch + 1)–\(ch + 2) (Stereo)") { capture.firstChannel = ch; capture.stereo = true }
                        }
                    } label: {
                        Text(channelLabel).font(.system(size: 10.5, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                } else {
                    Text(capture.sourceChannelCount == 1 ? "Mono" : "Stereo")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                }
                if capture.sourceSampleRate > 0 {
                    Text(String(format: "%g kHz", capture.sourceSampleRate / 1000))
                        .font(Theme.mono(9.5)).foregroundColor(Theme.textTertiary)
                }
                Spacer()
                Knob(value: Binding(get: { MiniFader.position(fromGain: capture.inputGain) },
                                    set: { capture.inputGain = MiniFader.gain(fromPosition: $0) }),
                     color: Theme.accent, size: 18, defaultValue: 0.8)
                    .help("Input gain: \(dbString(capture.inputGain))")
                IconButton(symbol: capture.monitoring ? "headphones.circle.fill" : "headphones", help: "Monitor input through the output",
                           active: capture.monitoring, size: 12, width: 26, height: 22) { capture.monitoring.toggle() }
            }

            HStack(spacing: 6) {
                CaptureButton(title: studio.isRecording ? "Stop" : (studio.armedTrack != nil ? "Record to Track" : "Record"),
                              symbol: studio.isRecording ? "stop.fill" : "record.circle", color: Theme.record,
                              active: studio.isRecording, disabled: !capture.isCapturing) { studio.toggleRecord() }
                Menu {
                    ForEach([5.0, 10, 20, 30, 60], id: \.self) { s in
                        Button("Last \(Int(s)) seconds") { studio.grab(seconds: s) }
                    }
                } label: {
                    Label("Grab", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                } primaryAction: {
                    studio.grab(seconds: 10)
                }
                .menuStyle(.borderlessButton)
                .frame(height: 28)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
                .help("Pull the last seconds of this source into the Library — Strata is always listening")
                .disabled(!capture.isCapturing)
            }
        }
        .padding(.top, 2)
    }

    private var channelLabel: String {
        capture.stereo ? "In \(capture.firstChannel + 1)–\(capture.firstChannel + 2)" : "In \(capture.firstChannel + 1)"
    }

    private func openPrivacySettings() {
        let anchor: String
        if case .system = capture.source { anchor = "Privacy_ScreenCapture" } else { anchor = "Privacy_Microphone" }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct CaptureButton: View {
    let title: String
    let symbol: String
    let color: Color
    let active: Bool
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(disabled ? Theme.textTertiary : (active ? .white : color))
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? color : color.opacity(hover && !disabled ? 0.2 : 0.12))
            )
            .shadow(color: active ? color.opacity(0.6) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

/// Scrolling peak history of the monitored source (newest on the right).
private struct ScopeView: View {
    let values: [Float]
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.25, width: size.width, height: 0.5)), with: .color(.white.opacity(0.08)))
            guard !values.isEmpty else { return }
            let n = values.count
            let step = size.width / CGFloat(n)
            var upper: [CGPoint] = [], lower: [CGPoint] = []
            upper.reserveCapacity(n); lower.reserveCapacity(n)
            for (i, v) in values.enumerated() {
                let norm = LevelMeter.normalized(v)          // log scale reads better at a glance
                let h = norm * (mid - 2)
                let x = CGFloat(i) * step
                upper.append(CGPoint(x: x, y: mid - h))
                lower.append(CGPoint(x: x, y: mid + h))
            }
            var p = Path()
            p.addLines(upper + lower.reversed())
            p.closeSubpath()
            ctx.fill(p, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.9)]),
                                              startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
        }
        .overlay(alignment: .topLeading) {
            if !active {
                Text("waiting for audio…").font(.system(size: 9.5)).foregroundColor(Theme.textTertiary).padding(6)
            }
        }
    }
}

// MARK: - Library

private struct LibraryPanel: View {
    @EnvironmentObject var studio: Studio
    @State private var search = ""
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionCaption(text: "Library", trailing: AnyView(HStack(spacing: 2) {
                Text("\(studio.project.samples.count)")
                    .font(Theme.mono(9.5, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                IconButton(symbol: "square.and.arrow.down", help: "Import Audio… (⌘I)", size: 10.5, width: 22, height: 20) { studio.presentImportPanel() }
            }))
            .padding(.horizontal, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundColor(Theme.textTertiary)
                TextField("Filter samples", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
            .padding(.horizontal, 12)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 3) {
                    ForEach(filtered) { s in
                        LibraryRow(sample: s, selected: studio.librarySelection == s.id)
                    }
                    if studio.project.samples.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "tray").font(.system(size: 20, weight: .light))
                            Text("Recordings, grabs and imported files appear here.")
                                .font(.system(size: 10.5))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .padding(.top, 10)
        .frame(maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .opacity(targeted ? 1 : 0)
                .padding(4)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { DispatchQueue.main.async { studio.importAudio(urls: [url]) } }
                }
            }
            return true
        }
    }

    private var filtered: [Sample] {
        let all = studio.project.samples.reversed() as ReversedCollection<[Sample]>
        guard !search.isEmpty else { return Array(all) }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
}

private struct LibraryRow: View {
    @EnvironmentObject var studio: Studio
    let sample: Sample
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.35))
                WaveformThumbnail(buffer: sample.buffer, color: Theme.trackColor(sample.colorIndex))
                    .padding(.horizontal, 3).padding(.vertical, 3)
                if hover {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.45))
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                }
            }
            .frame(width: 58, height: 30)
            .onTapGesture { studio.previewSample(sample.id) }
            .help("Preview")

            VStack(alignment: .leading, spacing: 2) {
                Text(sample.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(formatDuration(sample.duration)).font(Theme.mono(9.5))
                    if !sample.slices.isEmpty {
                        Text("· \(sample.slices.count + 1) slices").font(.system(size: 9.5))
                    }
                }
                .foregroundColor(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.trackColor(sample.colorIndex).opacity(0.14) : (hover ? Color.white.opacity(0.04) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Theme.trackColor(sample.colorIndex).opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { studio.openInEditor(sampleID: sample.id) }
        .onHover { hover = $0 }
        .onDrag {
            let provider = NSItemProvider(object: DragPayload.sample(sample.id) as NSString)
            provider.suggestedName = sample.name
            return provider
        }
        .contextMenu {
            Button("Open in Editor") { studio.openInEditor(sampleID: sample.id) }
            Button("Preview") { studio.previewSample(sample.id) }
            Button("Place at Playhead") { studio.placeSample(sample.id, onTrack: studio.selectedTrackID, at: studio.snapTime(studio.positionSeconds)) }
            Button("Place on New Track") { studio.placeSample(sample.id, onTrack: nil, at: studio.project.loop.enabled ? studio.project.loop.start : 0) }
            Divider()
            Button("Duplicate") { studio.duplicateSample(sample.id) }
            Button("Export…") { studio.exportSample(sample.id) }
            Divider()
            Button("Delete", role: .destructive) { studio.deleteSample(sample.id) }
        }
    }
}

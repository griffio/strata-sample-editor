import SwiftUI

struct SampleEditorPane: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(spacing: 0) {
            if studio.isRecording && studio.recordingTrackID == nil {
                LiveCaptureView()
            } else if let sample = studio.editorSample {
                EditorToolbar(editor: editor, sample: sample)
                    .id(sample.id)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        WaveformOverview(studio: studio, editor: editor, sample: sample)
                            .frame(height: 26)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        WaveformEditorView(studio: studio, editor: editor, sample: sample,
                                           clip: editor.clipID.flatMap { studio.project.clip($0) })
                    }
                    Rectangle().fill(Theme.hairlineStrong).frame(width: 1)
                    EditorInspector(editor: editor, sample: sample)
                        .frame(width: 252)
                }
            } else {
                EditorEmptyState()
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Toolbar

private struct EditorToolbar: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var editor: EditorState
    let sample: Sample
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.trackColor(sample.colorIndex)).frame(width: 10, height: 10)
                TextField("Sample", text: $name, onCommit: { studio.renameSample(sample.id, to: name) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .frame(minWidth: 80, maxWidth: 180)
                Text(formatDuration(sample.duration))
                    .font(Theme.mono(10.5))
                    .foregroundColor(Theme.textSecondary)
                Text("48 kHz · 32-bit")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
                if editor.clipID != nil {
                    Text("CLIP")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(.black.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.loop))
                        .help("Opened from a timeline clip — shaded areas are outside the clip")
                }
            }
            Spacer(minLength: 8)

            ToolGroup {
                PreviewButton(editor: editor)
                IconButton(symbol: "repeat", help: "Loop Preview", active: editor.loopPreview) { editor.loopPreview.toggle() }
            }
            ToolGroup {
                IconButton(symbol: "minus.magnifyingglass", help: "Zoom Out (−)") { zoom(1 / 1.6) }
                IconButton(symbol: "plus.magnifyingglass", help: "Zoom In (=)") { zoom(1.6) }
                IconButton(symbol: "arrow.left.and.right.square", help: "Zoom to Fit (Z)") { studio.editorZoomToFit() }
                IconButton(symbol: "rectangle.dashed", help: "Zoom to Selection", disabled: studio.editRange == nil) { studio.editorZoomToSelection() }
            }
            ToolGroup {
                IconButton(symbol: "crop", help: "Trim to Selection", disabled: studio.editRange == nil) { studio.editTrimToSelection() }
                IconButton(symbol: "delete.left", help: "Delete Selection (⌫)", disabled: studio.editRange == nil) { studio.editDeleteSelection() }
                IconButton(symbol: "speaker.slash", help: "Silence", disabled: studio.editRange == nil) { studio.editSilence() }
                IconButton(symbol: "arrow.uturn.backward", help: "Reverse (selection or whole sample)") { studio.editReverse() }
                IconButton(symbol: "waveform.badge.plus", help: "Normalize to −0.3 dB") { studio.editNormalize() }
                IconButton(symbol: "chart.line.uptrend.xyaxis", help: "Fade In") { studio.editFadeIn() }
                IconButton(symbol: "chart.line.downtrend.xyaxis", help: "Fade Out") { studio.editFadeOut() }
                Menu {
                    ForEach([-12, -6, -3, -1, 1, 3, 6, 12], id: \.self) { db in
                        Button(String(format: "%+d dB", db)) { studio.editGain(Float(db)) }
                    }
                } label: {
                    Image(systemName: "dial.medium").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("Gain")
            }
            ToolGroup {
                IconButton(symbol: "square.and.arrow.down", help: "Place on Timeline at Playhead") { studio.placeEditorSelection() }
                IconButton(symbol: "square.and.arrow.up", help: "Export Sample…") { studio.exportSample(sample.id, selectionOnly: studio.editRange != nil) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Theme.panelRaised)
        .onAppear { name = sample.name }
        .onChange(of: sample.name) { name = $0 }
        .onChange(of: sample.id) { _ in name = sample.name }
    }

    private func zoom(_ f: Double) {
        editor.zoom(by: f, anchorX: editor.width / 2, totalFrames: sample.frameCount)
    }
}

private struct PreviewButton: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var editor: EditorState

    var body: some View {
        PreviewButtonInner(clock: studio.clock)
    }

    private struct PreviewButtonInner: View {
        @EnvironmentObject var studio: Studio
        @ObservedObject var clock: TransportClock
        var body: some View {
            IconButton(symbol: clock.previewFrame != nil ? "stop.fill" : "play.fill", help: "Preview Selection (P)",
                       active: clock.previewFrame != nil, activeColor: Color(hex: 0x3CE38A)) {
                studio.previewEditorSelection()
            }
        }
    }
}

struct ToolGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 1) { content }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Inspector

private struct EditorInspector: View {
    @EnvironmentObject var studio: Studio
    @ObservedObject var editor: EditorState
    let sample: Sample

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                if let cid = editor.clipID, let clip = studio.project.clip(cid) {
                    ClipInspector(clip: clip)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                slicing
            }
            .padding(14)
        }
        .background(Theme.panelRaised)
    }

    private var slicing: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: "Slice", trailing: AnyView(
                Text(sample.slices.isEmpty ? "none" : "\(sample.slices.count + 1) slices")
                    .font(Theme.mono(9.5)).foregroundColor(Theme.textSecondary)))
            HStack(spacing: 8) {
                Text("Sensitivity").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                Slider(value: $editor.sensitivity, in: 0...1).controlSize(.small)
            }
            HStack(spacing: 6) {
                InspectorButton(title: "Transients", symbol: "waveform.path.ecg", prominent: true) { studio.autoSlice() }
                Menu {
                    ForEach([2, 3, 4, 6, 8, 12, 16, 32], id: \.self) { n in
                        Button("\(n) Equal Slices") { studio.sliceEqually(n) }
                    }
                    Divider()
                    Button("1/4 Notes (Beat Grid)") { studio.sliceByGrid(beats: 1) }
                    Button("1/8 Notes") { studio.sliceByGrid(beats: 0.5) }
                    Button("1/16 Notes") { studio.sliceByGrid(beats: 0.25) }
                } label: {
                    Label("Divide", systemImage: "square.split.3x1")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .frame(height: 26)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
            }
            Toggle(isOn: $editor.snapToZeroCrossings) {
                Text("Snap to zero crossings").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            HStack(spacing: 6) {
                InspectorButton(title: "To Track", symbol: "rectangle.stack.badge.plus", disabled: sample.slices.isEmpty) { studio.slicesToTrack() }
                InspectorButton(title: "To Library", symbol: "tray.and.arrow.down", disabled: sample.slices.isEmpty) { studio.slicesToLibrary() }
            }
            InspectorButton(title: "Clear Slices", symbol: "xmark.circle", disabled: sample.slices.isEmpty) { studio.clearSlices() }
            Text("Click the ruler to play a slice · Double-click it to add a marker · ⌥-click a marker to remove · ⌥-drag a selection onto a track")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if let tempo = sampleTempoHint {
                Text(tempo).font(.system(size: 10, weight: .medium)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var sampleTempoHint: String? {
        let bars = sample.duration / studio.project.secondsPerBar
        guard bars > 0.2 else { return nil }
        return String(format: "≈ %.2f bars at %.0f BPM", bars, studio.project.bpm)
    }
}

private struct ClipInspector: View {
    @EnvironmentObject var studio: Studio
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionCaption(text: "Clip", trailing: AnyView(
                Text(MusicalTimeFormatter(project: studio.project).string(clip.start))
                    .font(Theme.mono(9.5)).foregroundColor(Theme.textSecondary)))
            row("Gain") {
                ScrubField(value: Double(20 * log10(max(clip.gain, 0.0001))), format: { String(format: "%+.1f dB", $0) }, step: 0.5,
                           range: -48...12, onBegin: { studio.beginGesture("Clip Gain") },
                           onChange: { db in studio.live { $0.updateClip(clip.id) { $0.gain = Float(pow(10, db / 20)) } } },
                           onEnd: { studio.endGesture() })
            }
            row("Fade In") {
                ScrubField(value: clip.fadeIn * 1000, format: { String(format: "%.0f ms", $0) }, step: 5, range: 0...max(0, (clip.duration - clip.fadeOut) * 1000),
                           onBegin: { studio.beginGesture("Fade In") },
                           onChange: { ms in studio.live { $0.updateClip(clip.id) { $0.fadeIn = ms / 1000 } } },
                           onEnd: { studio.endGesture() })
            }
            row("Fade Out") {
                ScrubField(value: clip.fadeOut * 1000, format: { String(format: "%.0f ms", $0) }, step: 5, range: 0...max(0, (clip.duration - clip.fadeIn) * 1000),
                           onBegin: { studio.beginGesture("Fade Out") },
                           onChange: { ms in studio.live { $0.updateClip(clip.id) { $0.fadeOut = ms / 1000 } } },
                           onEnd: { studio.endGesture() })
            }
            row("Stretch") {
                ScrubField(value: clip.stretch * 100, format: { String(format: "%.1f %%", $0) }, step: 1, range: 6.25...1600,
                           onBegin: { studio.beginGesture("Stretch") },
                           onChange: { v in studio.live { $0.updateClip(clip.id) { $0.stretch = v / 100 } } },
                           onEnd: { studio.endGesture() })
            }
            row("Length") {
                Text(String(format: "%@ · %.2f bars", formatDuration(clip.duration), clip.duration / studio.project.secondsPerBar))
                    .font(Theme.mono(11)).foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 4) {
                ForEach([("½", 0.5), ("1", 1.0), ("2", 2.0), ("4", 4.0), ("8", 8.0)], id: \.0) { label, bars in
                    Button {
                        studio.selectedClips = [clip.id]
                        studio.fitSelectedClips(toBars: bars)
                    } label: {
                        Text(label)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.text)
                    .help("Stretch to \(label) bar(s)")
                }
            }
            Text("Fit to bars").font(.system(size: 9.5)).foregroundColor(Theme.textTertiary)
            Picker("", selection: Binding(get: { clip.preservePitch ? clip.stretchMode.rawValue : "varispeed" },
                                          set: { v in
                                              studio.updateClip(clip.id, "Stretch Mode") { c in
                                                  if let m = StretchMode(rawValue: v) { c.preservePitch = true; c.stretchMode = m } else { c.preservePitch = false }
                                              }
                                          })) {
                Text("Beats").tag("beats")
                Text("Tonal").tag("tonal")
                Text("Varispeed").tag("varispeed")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("Beats: transient-tight · Tonal: smooth spectral · Varispeed: tape-style, pitch follows speed")
            Text(clip.preservePitch ? clip.stretchMode.help : "Tape-style: pitch follows speed")
                .font(.system(size: 9.5)).foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            Spacer()
            content()
        }
    }
}

struct InspectorButton: View {
    let title: String
    let symbol: String
    var prominent = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(disabled ? Theme.textTertiary : (prominent ? .black.opacity(0.85) : Theme.text))
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent && !disabled ? AnyShapeStyle(Theme.loop) : AnyShapeStyle(Color.white.opacity(hover && !disabled ? 0.12 : 0.07)))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

// MARK: - Empty & live states

private struct EditorEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundColor(Theme.textTertiary)
            Text("Sample Editor")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text("Select a sample in the Library or double-click a clip to slice, trim and shape it.")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-width live waveform while capturing a free take into the library.
private struct LiveCaptureView: View {
    @EnvironmentObject var studio: Studio
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Theme.record).frame(width: 10, height: 10)
                    .shadow(color: Theme.record, radius: pulse ? 8 : 2)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                Text("Capturing from \(studio.capture.sourceDisplayName)")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
                Text(formatClock(studio.recordingDuration))
                    .font(Theme.mono(12, weight: .semibold)).foregroundColor(Theme.record)
                Spacer()
                Button { studio.stopRecording() } label: {
                    Label("Stop & Keep", systemImage: "stop.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.record))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.panelRaised)
            Canvas { ctx, size in
                let peaks = studio.livePeaks
                guard !peaks.isEmpty else { return }
                // Grows left → right over a 10 s canvas, then compresses to fit.
                let canvasBins = max(peaks.count, Int(10 * AudioSpec.sampleRate) / Recorder.peakBin)
                let step = size.width / CGFloat(canvasBins)
                let stride = max(1, Int(1 / step))
                let mid = size.height / 2
                var path = Path()
                var upper: [CGPoint] = [], lower: [CGPoint] = []
                var slice: [Float] = []
                var k = 0
                while k < peaks.count { slice.append(peaks[k..<min(peaks.count, k + stride)].max() ?? 0); k += stride }
                for (i, v) in slice.enumerated() {
                    let x = CGFloat(i * stride) * step
                    let h = CGFloat(min(1, v)) * (mid - 6)
                    upper.append(CGPoint(x: x, y: mid - h - 0.5))
                    lower.append(CGPoint(x: x, y: mid + h + 0.5))
                }
                path.addLines(upper + lower.reversed())
                path.closeSubpath()
                ctx.fill(path, with: .linearGradient(Gradient(colors: [Theme.record.opacity(0.9), Color(hex: 0xFF8A65)]),
                                                     startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
                ctx.fill(Path(CGRect(x: 0, y: mid - 0.25, width: size.width, height: 0.5)), with: .color(.white.opacity(0.15)))
            }
            .background(Theme.base)
        }
        .onAppear { pulse = true }
    }
}

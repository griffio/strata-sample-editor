import SwiftUI
import UniformTypeIdentifiers

struct ArrangementView: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ArrangementCorner()
                    .frame(width: Theme.headerWidth, height: Theme.rulerHeight)
                RulerView(studio: studio, viewport: studio.viewport)
                    .frame(height: Theme.rulerHeight)
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairlineStrong).frame(height: 1) }

            if studio.project.tracks.isEmpty {
                EmptyArrangementView()
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(Array(studio.project.tracks.enumerated()), id: \.element.id) { i, track in
                            HStack(spacing: 0) {
                                TrackHeaderView(track: track, index: i)
                                    .frame(width: Theme.headerWidth)
                                TrackLaneView(studio: studio, viewport: studio.viewport, track: track, index: i)
                            }
                            .frame(height: track.height)
                        }
                        NewTrackDropRow()
                    }
                }
                .background(Theme.base)
            }
        }
        .overlay(alignment: .topLeading) {
            PlayheadOverlay(clock: studio.clock, viewport: studio.viewport)
                .padding(.leading, Theme.headerWidth)
                .clipped()
        }
        .background(Theme.base)
    }
}

/// Top-left corner above the track headers: track count, add-track and follow toggle.
private struct ArrangementCorner: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        HStack(spacing: 4) {
            Text("TRACKS")
                .font(.system(size: 10, weight: .bold))
                .kerning(0.9)
                .foregroundColor(Theme.textTertiary)
            Text("\(studio.project.tracks.count)")
                .font(Theme.mono(10, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            Spacer()
            IconButton(symbol: "arrow.right.to.line.compact", help: "Follow Playhead (F)", active: studio.followPlayhead,
                       size: 11, width: 24, height: 22) { studio.followPlayhead.toggle() }
            IconButton(symbol: "plus", help: "New Track (⌘T)", size: 12, width: 24, height: 22) { studio.addTrack() }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(hex: 0x1D2025), Color(hex: 0x16181C)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairlineStrong).frame(width: 1) }
    }
}

/// The 60 fps playhead line drawn over the ruler and all lanes.
struct PlayheadOverlay: View {
    @ObservedObject var clock: TransportClock
    @ObservedObject var viewport: TimelineViewport

    var body: some View {
        GeometryReader { geo in
            let x = viewport.x(clock.position)
            if x >= -6 && x <= geo.size.width + 6 {
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Theme.playhead)
                        .frame(width: 1.5)
                        .shadow(color: .white.opacity(0.55), radius: 3)
                    PlayheadCap()
                        .fill(Theme.playhead)
                        .frame(width: 13, height: 9)
                        .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                        .offset(y: 13)
                }
                .frame(width: 13, height: geo.size.height)
                .offset(x: x - 6.5)
            }
        }
        .allowsHitTesting(false)
    }
}

struct PlayheadCap: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Dropping a sample here creates a new track; clicking adds an empty one.
private struct NewTrackDropRow: View {
    @EnvironmentObject var studio: Studio
    @State private var targeted = false
    @State private var hover = false

    var body: some View {
        Button { studio.addTrack() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 13))
                Text(targeted ? "Drop to create a new track" : "New Track")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
            }
            .foregroundColor(targeted ? Theme.accent : (hover ? Theme.textSecondary : Theme.textTertiary))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundColor(targeted ? Theme.accent : Color.white.opacity(hover ? 0.14 : 0.08))
                    .padding(6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onDrop(of: [UTType.utf8PlainText, UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers, studio: studio, track: nil, time: studio.project.loop.enabled ? studio.project.loop.start : 0)
        }
    }
}

/// Shared SwiftUI drop handler for sample/region payloads and Finder files.
func handleDrop(_ providers: [NSItemProvider], studio: Studio, track: UUID?, time: Double) -> Bool {
    var handled = false
    for provider in providers {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                DispatchQueue.main.async { studio.importAudio(urls: [url], placeAt: time, onTrack: track) }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            handled = true
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String, let (id, range) = DragPayload.parse(s) else { return }
                DispatchQueue.main.async { studio.placeSample(id, onTrack: track, at: time, range: range) }
            }
        }
    }
    return handled
}

/// Shown when the project has no tracks yet.
private struct EmptyArrangementView: View {
    @EnvironmentObject var studio: Studio
    @State private var targeted = false

    var body: some View {
        ZStack {
            Theme.base
            GridBackdrop().opacity(0.6)
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.10)).frame(width: 84, height: 84)
                    Circle().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1).frame(width: 84, height: 84)
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent, Color(hex: 0xA47BFF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                VStack(spacing: 6) {
                    Text("Start your loop")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("Pick a source on the left and press Record, drop audio files here,\nor drag samples in from the Library.")
                        .font(.system(size: 12.5))
                        .multilineTextAlignment(.center)
                        .foregroundColor(Theme.textSecondary)
                        .lineSpacing(2)
                }
                HStack(spacing: 10) {
                    EmptyStateButton(title: "New Track", symbol: "plus") { studio.addTrack() }
                    EmptyStateButton(title: "Import Audio…", symbol: "square.and.arrow.down") { studio.presentImportPanel() }
                    EmptyStateButton(title: "Load Demo Kit", symbol: "sparkles", prominent: true) { studio.loadDemo() }
                }
                .padding(.top, 4)
            }
            .padding(40)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundColor(targeted ? Theme.accent : .clear)
                .padding(14)
        )
        .onDrop(of: [UTType.utf8PlainText, UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers, studio: studio, track: nil, time: 0)
        }
    }
}

private struct EmptyStateButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundColor(prominent ? .black.opacity(0.85) : Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Color(hex: 0x7FB0FF)], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.white.opacity(hover ? 0.12 : 0.07)))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(prominent ? 0 : 0.08)))
            .shadow(color: prominent ? Theme.accent.opacity(hover ? 0.5 : 0.3) : .clear, radius: 10)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct GridBackdrop: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 32
            var x: CGFloat = 0
            var i = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                         with: .color(Color.white.opacity(i % 4 == 0 ? 0.05 : 0.02)))
                x += step; i += 1
            }
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Color.white.opacity(0.02)))
                y += step * 2.5
            }
        }
        .mask(RadialGradient(colors: [.white, .clear], center: .center, startRadius: 40, endRadius: 520))
    }
}

import SwiftUI
import AppKit

struct StudioRootView: View {
    @StateObject private var studio: Studio
    @Environment(\.undoManager) private var undoManager
    @SceneStorage("editorHeight") private var editorHeight: Double = 300
    @State private var dragStartHeight: Double?

    init(document: ProjectDocument) {
        _studio = StateObject(wrappedValue: Studio(document: document))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 248, ideal: Theme.sidebarWidth, max: 360)
        } detail: {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ArrangementView()
                        .frame(maxHeight: .infinity)
                    if studio.showEditor {
                        splitHandle(total: geo.size.height)
                        SampleEditorPane(editor: studio.editor)
                            .frame(height: min(max(180, editorHeight), max(180, geo.size.height - 200)))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .background(Theme.base)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { TransportBar() }
            ToolbarItem(placement: .primaryAction) { ToolsBar() }
        }
        .overlay(alignment: .top) { ToastOverlay() }
        .environmentObject(studio)
        .focusedSceneObject(studio)
        .background(WindowAccessor { window in
            studio.window = window
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(hex: 0x0D0E11)
            studio.installKeyMonitor()
            DebugSnapshot.runIfRequested(studio: studio)
        })
        .onAppear { studio.undoManager = undoManager }
        .onChange(of: undoManager) { studio.undoManager = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow) === studio.window { studio.windowBecameKey() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow) === studio.window { studio.shutdown() }
        }
        .sheet(isPresented: $studio.showShortcuts) { ShortcutsSheet() }
        .alert(item: $studio.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .frame(minWidth: 1080, minHeight: 640)
        .preferredColorScheme(.dark)
    }

    private func splitHandle(total: Double) -> some View {
        ZStack {
            Rectangle().fill(Theme.base).frame(height: 7)
            Rectangle().fill(Theme.hairlineStrong).frame(height: 1)
            Capsule().fill(Color.white.opacity(0.18)).frame(width: 36, height: 3)
        }
        .contentShape(Rectangle())
        .onHover { h in if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if dragStartHeight == nil { dragStartHeight = editorHeight }
                    editorHeight = min(max(180, (dragStartHeight ?? 300) - g.translation.height), total - 200)
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }
}

/// Transient HUD message at the top of the window.
private struct ToastOverlay: View {
    @EnvironmentObject var studio: Studio

    var body: some View {
        Group {
            if let t = studio.toast {
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .padding(.top, 50)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Gives SwiftUI content access to its hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WindowWatcherView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowWatcherView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { DispatchQueue.main.async { self.onWindow?(w) } }
        }
    }
}

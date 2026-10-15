import SwiftUI
import AppKit

@main
struct StrataApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            StudioRootView(document: file.document)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { StrataCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AudioDevices.shared
    }
}

struct StrataCommands: Commands {
    var body: some Commands {
        NewItemCommands()
        ExportCommands()
        EditCommands()
        TransportCommands()
        TrackCommands()
        ClipCommands()
        SampleCommands()
        HelpCommands()
    }
}

private struct NewItemCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Audio…") { studio?.presentImportPanel() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(studio == nil)
        }
    }
}

private struct ExportCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Mixdown…") { studio?.exportMixdown() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Bounce Loop to Library") { studio?.bounceToLibrary() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Export Selected Sample…") {
                if let s = studio, let id = s.editor.sampleID { s.exportSample(id, selectionOnly: s.editRange != nil) }
            }
            .disabled(studio?.editor.sampleID == nil)
        }
    }
}

private struct EditCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select All Clips") { studio?.selectAllClips() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Duplicate") { studio?.duplicateSelectedClips() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split at Playhead") { studio?.split(at: studio?.positionSeconds ?? 0) }
                .keyboardShortcut("e", modifiers: .command)
            Button("Delete Selected Clips") { studio?.deleteSelectedClips() }
        }
    }
}

private struct TransportCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandMenu("Transport") {
            Group {
            Button("Play / Pause   (Space)") { studio?.togglePlay() }
                .keyboardShortcut(.space, modifiers: .option)
            Button("Stop") { studio?.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Button("Record   (R)") { studio?.toggleRecord() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Return to Start   (↩)") { studio?.returnToStart() }
            Button("Toggle Loop   (L)") { studio?.toggleLoop() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Loop Selected Clips") { studio?.loopSelection() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Toggle Metronome   (K)") { studio?.toggleMetronome() }
                .keyboardShortcut("k", modifiers: .command)
            }
            Divider()
            Button("Zoom In") { studio?.zoom(1.5) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { studio?.zoom(1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Zoom to Fit") { studio?.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

private struct TrackCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandMenu("Track") {
            Button("New Track") { studio?.addTrack() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Duplicate Track") { if let s = studio, let id = s.selectedTrackID { s.duplicateTrack(id) } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Arm Selected Track") { if let s = studio, let id = s.selectedTrackID { s.toggleArm(id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Delete Track") { if let s = studio, let id = s.selectedTrackID { s.deleteTrack(id) } }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
    }
}

private struct ClipCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandMenu("Clip") {
            Button("Slice at Transients") { studio?.sliceSelectedClipsAtTransients() }
            Button("Quantize Start") { studio?.quantizeSelectedClips() }
                .keyboardShortcut("u", modifiers: .command)
            Divider()
            Menu("Stretch to Fit") {
                Button("1 Bar") { studio?.fitSelectedClips(toBars: 1) }
                Button("2 Bars") { studio?.fitSelectedClips(toBars: 2) }
                Button("4 Bars") { studio?.fitSelectedClips(toBars: 4) }
                Button("8 Bars") { studio?.fitSelectedClips(toBars: 8) }
            }
            Button("Reset Stretch") { studio?.resetStretch() }
            Divider()
            Button("Open in Sample Editor") {
                if let s = studio, let id = s.selectedClips.first { s.openClipInEditor(id) }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

private struct SampleCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandMenu("Sample") {
            Group {
                Button("Auto-Slice at Transients") { studio?.autoSlice() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Add Slice Marker   (M)") { studio?.addSliceMarkerAtCursor() }
                Button("Clear Slices") { studio?.clearSlices() }
                Divider()
                Button("Slices to New Track") { studio?.slicesToTrack() }
                Button("Slices to Library") { studio?.slicesToLibrary() }
            }
            Divider()
            Group {
            Button("Trim to Selection") { studio?.editTrimToSelection() }
            Button("Normalize") { studio?.editNormalize() }
            Button("Reverse") { studio?.editReverse() }
            Button("Fade In") { studio?.editFadeIn() }
            Button("Fade Out") { studio?.editFadeOut() }
            }
            Divider()
            Button("Select All Audio") { studio?.editSelectAll() }
            Button("Preview   (P)") { studio?.previewEditorSelection() }
        }
    }
}

private struct HelpCommands: Commands {
    @FocusedObject private var studio: Studio?

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Load Demo Kit") { studio?.loadDemo() }
            Divider()
            Button("Keyboard Shortcuts") { studio?.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}

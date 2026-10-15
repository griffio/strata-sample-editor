import AppKit
import CoreGraphics

/// Developer aid: when launched with STRATA_SNAPSHOT=/path/prefix the app scripts a few
/// UI states and writes window captures (an app may always capture its own windows).
/// Optional: STRATA_DEMO=1 loads the demo kit first.
enum DebugSnapshot {
    #if DEBUG
    private static var started = false
    #endif

    static func runIfRequested(studio: Studio) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["STRATA_SNAPSHOT"], !started else { return }
        started = true
        let steps = (env["STRATA_STEPS"] ?? "base").split(separator: ",").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Discard documents restored from earlier scripted runs.
            for doc in NSDocumentController.shared.documents where !doc.windowControllers.contains(where: { $0.window === studio.window }) {
                discard(doc)
            }
            if env["STRATA_DEMO"] == "1" && studio.project.tracks.isEmpty { studio.loadDemo() }
            if let w = studio.window, env["STRATA_SIZE"] != nil {
                let parts = env["STRATA_SIZE"]!.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { w.setFrame(NSRect(x: 40, y: 40, width: parts[0], height: parts[1]), display: true) }
            }
            run(steps: steps, index: 0, studio: studio, prefix: prefix)
        }
        #endif
    }

    #if DEBUG

    private static func run(steps: [String], index: Int, studio: Studio, prefix: String) {
        guard index < steps.count else {
            if ProcessInfo.processInfo.environment["STRATA_QUIT"] == "1" {
                // Leave no autosaved Untitled documents behind for the next launch.
                NSDocumentController.shared.documents.forEach(discard)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
            return
        }
        let step = steps[index]
        // Simulate the event boundary real input provides (closes automatic undo groups).
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
        switch step {
        case "play": studio.play()
        case "stop": studio.stop()
        case "select":
            if let t = studio.project.tracks.first, let c = t.clips.first { studio.selectedClips = [c.id]; studio.openClipInEditor(c.id) }
        case "slice":
            if let s = studio.project.samples.first { studio.openInEditor(sampleID: s.id); studio.autoSlice() }
        case "stretch":
            if let t = studio.project.tracks.dropFirst(3).first, let c = t.clips.first {
                studio.selectedClips = [c.id]
                studio.updateSelectedClips("Stretch") { $0.stretch = 1.5 }
            }
        case "zoomin": studio.viewport.zoom(by: 3, anchorX: 200)
        case "editorzoom": studio.editor.zoom(by: 40, anchorX: 300, totalFrames: studio.editorSample?.frameCount ?? 1)
        case "empty": break
        case "testsource": studio.capture.debugStartTestSignal()
        case "rec": studio.startRecording()
        case "recstop": studio.stopRecording()
        case "grab": studio.grab(seconds: 2)
        case "arm": if let t = studio.project.tracks.first { studio.toggleArm(t.id) }
        case "wait": break
        case "loopprev":
            if let s = studio.editorSample, s.sliceRanges.count > 6 {
                studio.editor.selection = s.sliceRanges[1]
                studio.editor.loopPreview = true
                studio.previewEditorSelection()
                NSLog("%@", "[snapshot] looping \(s.sliceRanges[1])")
            }
        case "reselect":
            if let s = studio.editorSample, s.sliceRanges.count > 6 {
                studio.editor.selection = s.sliceRanges[5]
                NSLog("%@", "[snapshot] reselected \(s.sliceRanges[5])")
                for delay in [0.1, 0.4, 0.8] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        NSLog("%@", "[snapshot] +\(delay)s preview pos=\(studio.engine.previewPosition.map(String.init) ?? "stopped")")
                    }
                }
            }
        case "undostate":
            let um = studio.undoManager
            NSLog("%@", "[snapshot] canUndo=\(um?.canUndo ?? false) action=\(um?.undoActionName ?? "-") docEdited=\(NSDocumentController.shared.documents.first?.isDocumentEdited ?? false) docs=\(NSDocumentController.shared.documents.count) windowEdited=\(studio.window?.isDocumentEdited ?? false) changeCountUntitled=\(NSDocumentController.shared.documents.first?.fileURL == nil) autosave=\(NSDocumentController.shared.documents.first?.autosavedContentsFileURL?.lastPathComponent ?? "-")")
        case "size":
            NSApp.activate(ignoringOtherApps: true)
            studio.window?.makeKeyAndOrderFront(nil)
            if let w = studio.window, let spec = ProcessInfo.processInfo.environment["STRATA_SIZE"] {
                let parts = spec.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 {
                    let screen = w.screen?.visibleFrame ?? .zero
                    w.setFrame(NSRect(x: screen.minX + 40, y: screen.maxY - parts[1] - 40, width: parts[0], height: parts[1]), display: true)
                }
            }
        case "fit": studio.zoomToFit()
        case "selslice":
            if let s = studio.editorSample, s.sliceRanges.count > 4 { studio.editor.selection = s.sliceRanges[3] }
        case "edzoom":
            if let s = studio.editorSample {
                studio.editor.framesPerPixel = Double(s.frameCount) / Double(studio.editor.width) / 2.6
                studio.editor.scrollFrame = Double(s.frameCount) * 0.22
            }
        case "tonal":
            if studio.project.tracks.count > 4, let c = studio.project.tracks[4].clips.first {
                studio.selectedClips = [c.id]
                studio.updateSelectedClips("Stretch") { $0.stretch = 1.25; $0.stretchMode = .tonal }
                studio.openClipInEditor(c.id)
            }
        case "stretchbeats":
            if studio.project.tracks.count > 3, let c = studio.project.tracks[3].clips.last {
                studio.updateClip(c.id, "Stretch") { $0.stretch = 0.5 }
            }
        case "slicetrack": studio.slicesToTrack()
        case "devsource":
            studio.capture.debugStartTestSignal(sourceUID: AudioDevices.shared.inputs.first { $0.isVirtual }?.uid)
        case "undo":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let um = studio.undoManager
                NSLog("%@", "[snapshot] before undo: um=\(um != nil) level=\(um?.groupingLevel ?? -9) name=\(um?.undoActionName ?? "-") canUndo=\(um?.canUndo ?? false) byEvent=\(um?.groupsByEvent ?? false)")
                studio.undoManager?.undo()
                NSLog("%@", "[snapshot] after undo: slices=\(studio.project.samples.first?.slices.count ?? -1) tracks=\(studio.project.tracks.count)")
            }
        case "saveas":
            let url = URL(fileURLWithPath: prefix + "-project.strata")
            if let doc = NSDocumentController.shared.documents.first {
                doc.save(to: url, ofType: doc.fileType ?? "com.griffio.strata.project", for: .saveAsOperation) { err in
                    NSLog("%@", "[snapshot] saved to \(url.path) error=\(String(describing: err))")
                }
            }
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            capture(studio: studio, to: "\(prefix)-\(index)-\(step).png")
            NSLog("%@", "[snapshot] step=\(step) playing=\(studio.isPlaying) pos=\(String(format: "%.3f", studio.positionSeconds)) master=\(studio.meters.master) engineRunning=\(studio.engine.isRunning)")
            run(steps: steps, index: index + 1, studio: studio, prefix: prefix)
        }
    }

    /// Closes a scripted-run document without saving and removes its autosave.
    private static func discard(_ doc: NSDocument) {
        guard doc.fileURL == nil else { doc.close(); return }
        if let url = doc.autosavedContentsFileURL { try? FileManager.default.removeItem(at: url) }
        doc.updateChangeCount(.changeCleared)
        doc.autosavedContentsFileURL = nil
        doc.close()
    }

    static func capture(studio: Studio, to path: String) {
        guard let w = studio.window else { return }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif
}

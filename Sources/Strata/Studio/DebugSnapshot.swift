import AppKit
import CoreGraphics

/// Developer aid: when launched with STRATA_SNAPSHOT=/path/prefix the app scripts a few
/// UI states and writes window captures (an app may always capture its own windows).
/// Optional: STRATA_DEMO=1 loads the demo kit first.
enum DebugSnapshot {
    static func runIfRequested(studio: Studio) {
        let env = ProcessInfo.processInfo.environment
        guard let prefix = env["STRATA_SNAPSHOT"] else { return }
        let steps = (env["STRATA_STEPS"] ?? "base").split(separator: ",").map(String.init)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if env["STRATA_DEMO"] == "1" && studio.project.tracks.isEmpty { studio.loadDemo() }
            if let w = studio.window, env["STRATA_SIZE"] != nil {
                let parts = env["STRATA_SIZE"]!.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { w.setFrame(NSRect(x: 40, y: 40, width: parts[0], height: parts[1]), display: true) }
            }
            run(steps: steps, index: 0, studio: studio, prefix: prefix)
        }
    }

    private static func run(steps: [String], index: Int, studio: Studio, prefix: String) {
        guard index < steps.count else {
            if ProcessInfo.processInfo.environment["STRATA_QUIT"] == "1" { exit(0) }
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

    static func capture(studio: Studio, to path: String) {
        guard let w = studio.window else { return }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

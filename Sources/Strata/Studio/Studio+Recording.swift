import Foundation

extension Studio {
    var armedTrack: Track? { project.tracks.first { $0.armed } }

    func setRecording(track: UUID?, recording: Bool = true) {
        isRecording = recording
        recordingTrackID = recording ? track : nil
        if !recording { livePeaksReset() }
    }

    func livePeaksReset() {
        livePeaks = []
        recordingDuration = 0
    }

    func recordingStartPublished(_ seconds: Double) { recordingStart = seconds }

    func livePeaksPublish(_ peaks: [Float], start: Double, duration: Double) {
        livePeaks = peaks
        recordingStart = start
        recordingDuration = duration
    }

    func toggleRecord() {
        isRecording ? stopRecording() : startRecording()
    }

    /// Records onto the armed track in sync with the timeline, or — with no armed track —
    /// captures a free take straight into the library.
    func startRecording() {
        guard capture.isCapturing else {
            alert = StudioAlert(title: "No Input Source",
                                message: "Choose an input device or System Audio in the Sources panel, then press Record again.")
            return
        }
        let rec = capture.beginRecording()
        recorder = rec
        recordFirstFrame = nil
        recordLoopTarget = nil
        livePeaksReset()

        if let track = armedTrack {
            setRecording(track: track.id)
            let sr = AudioSpec.sampleRate
            var startSeconds = positionSeconds
            if !isPlaying {
                if project.loop.enabled && (startSeconds < project.loop.start || startSeconds >= project.loop.end - 0.05) {
                    startSeconds = project.loop.start
                }
                if project.countIn {
                    let preroll = project.secondsPerBar
                    engine.setCountIn(clickUntil: Int64(startSeconds * sr))
                    engine.seek(toFrame: Int64(((startSeconds - preroll) * sr).rounded()))
                } else {
                    seek(to: startSeconds)
                }
                recordStartFrame = Int64((startSeconds * sr).rounded())
                play()
            } else {
                recordStartFrame = engine.positionFrame
            }
            recordWrapCount = engine.shared[7]
            recordWrapTicks = 0
            if project.loop.enabled {
                let ls = Int64(project.loop.start * sr), le = Int64(project.loop.end * sr)
                if recordStartFrame >= ls && recordStartFrame < le { recordLoopTarget = le }
            }
            recordingStartPublished(Double(recordStartFrame) / sr)
        } else {
            setRecording(track: nil)
            recordingStartPublished(0)
        }
    }

    func stopRecording() {
        guard isRecording, let rec = recorder else { return }
        capture.endRecording()
        let trackID = recordingTrackID
        finishRecording(rec, trackID: trackID, limitToLoop: false)
    }

    /// Called from the 60 Hz tick while recording.
    func pollRecording() {
        guard let rec = recorder else { return }
        let sr = AudioSpec.sampleRate
        if recordingTrackID != nil {
            if recordFirstFrame == nil, let host = rec.hostTimeOfFirstFrame {
                let latencyTicks = HostClock.ticks(capture.inputLatency)
                recordFirstFrame = engine.timelineFrame(atHostTime: host &- latencyTicks)
            }
            guard let first = recordFirstFrame else { return }
            let keptStart = max(first, recordStartFrame)
            let drop = Int(keptStart - first)
            let have = rec.frameCount - drop
            updateLive(rec, drop: drop, start: Double(keptStart) / sr, frames: max(0, have))
            if let target = recordLoopTarget {
                // Finish on frame count, or shortly after the transport wraps (covers
                // sources that deliver fewer samples than the output clock).
                if engine.shared[7] != recordWrapCount { recordWrapTicks += 1 }
                if have >= Int(target - keptStart) || recordWrapTicks > 12 {
                    capture.endRecording()
                    finishRecording(rec, trackID: recordingTrackID, limitToLoop: true)
                }
            }
        } else {
            updateLive(rec, drop: 0, start: 0, frames: rec.frameCount)
        }
    }

    private func updateLive(_ rec: Recorder, drop: Int, start: Double, frames: Int) {
        let peaks = rec.peaksSnapshot()
        let dropBins = drop / Recorder.peakBin
        livePeaksPublish(dropBins < peaks.count ? Array(peaks[dropBins...]) : [], start: start,
                         duration: Double(frames) / AudioSpec.sampleRate)
    }

    private func finishRecording(_ rec: Recorder, trackID: UUID?, limitToLoop: Bool) {
        let sr = AudioSpec.sampleRate
        recorder = nil
        defer { setRecording(track: nil, recording: false); engine.setCountIn(clickUntil: nil) }

        if let tid = trackID {
            let first = recordFirstFrame ?? recordStartFrame
            let keptStart = max(first, recordStartFrame)
            let drop = Int(keptStart - first)
            let limit = limitToLoop ? recordLoopTarget.map { Int($0 - keptStart) } : nil
            guard var buffer = rec.finish(drop: drop, limit: limit), buffer.frameCount > Int(sr * 0.05) else { return }
            if let l = limit, buffer.frameCount < l {
                buffer = SampleBuffer.concatenate([buffer, SampleBuffer(frameCount: l - buffer.frameCount)])
            }
            let name = "Take \(takeCounter)"
            takeCounter += 1
            let color = project.tracks.first { $0.id == tid }?.colorIndex ?? 0
            let sample = Sample(name: uniqueSampleName(name), buffer: buffer, colorIndex: color,
                                origin: "Recorded from \(capture.sourceDisplayName)")
            let clip = Clip(sampleID: sample.id, name: sample.name, start: Double(keptStart) / sr,
                            sourceStart: 0, sourceLength: buffer.frameCount)
            DispatchQueue.global(qos: .userInitiated).async { buffer.preparePeaks() }
            perform("Record") { p in
                p.samples.append(sample)
                if let i = p.trackIndex(tid) {
                    p.tracks[i].clips.append(clip)
                    p.tracks[i].sortClips()
                    if limitToLoop { p.tracks[i].armed = false }
                }
            }
            selectedClips = [clip.id]
            openInEditor(sampleID: sample.id, clipID: clip.id)
            showToast(limitToLoop ? "Loop take recorded — playing back" : "Recorded \(formatDuration(buffer.duration))")
        } else {
            guard let buffer = rec.finish(), buffer.frameCount > Int(sr * 0.05) else { return }
            let name = "Capture \(takeCounter)"
            takeCounter += 1
            addSample(buffer, name: name, origin: "Recorded from \(capture.sourceDisplayName)")
            showToast("Captured \(formatDuration(buffer.duration)) to Library")
        }
    }

    /// Retroactive capture: pulls the last `seconds` of the monitored source into the library.
    func grab(seconds: Double) {
        guard capture.isCapturing || capture.history.availableSeconds > 0 else {
            alert = StudioAlert(title: "Nothing to Grab", message: "Select a source first — Strata keeps the last 60 seconds of it ready to grab.")
            return
        }
        guard let buffer = capture.history.snapshot(seconds: seconds) else { return }
        addSample(buffer, name: "Grab", origin: "Grabbed from \(capture.sourceDisplayName)")
        showToast("Grabbed \(formatDuration(buffer.duration)) from \(capture.sourceDisplayName)")
    }
}

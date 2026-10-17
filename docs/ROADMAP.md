# Sample editor roadmap

Feature ideas for the sample editor, roughly ordered by effort within each group.
Ticked items are shipped; the commit is noted alongside.

## Quick wins

- [x] **1. Tempo detection** — *0851496*
  Detect the tempo of the sample or selection from the inspector. Loops snap to an exact
  whole power-of-two number of bars; ½× / 2× resolve half/double time; Set Project and
  Match Clips apply it. The estimator scores pulse trains (so syncopation such as a kick
  every 1.5 beats doesn't win) and gives non-loops a free estimate with no bar count.
- [ ] **2. Fade shapes**
  `SampleBuffer.FadeShape` already supports linear and exponential curves; the UI only
  uses equal-power. Expose a shape menu on the fade buttons.
- [x] **3. Keyboard editing** — *0851496*
  With the editor focused: ← / → jump between slices (⇧ extends from the anchored edge),
  Tab / ⇧Tab step through transients, [ / ] move the active edge one zero crossing.
- [ ] **4. Clip indicators and selection stats**
  Mark samples at or above full scale in the waveform (the peak pyramid already holds
  per-bin min/max); show peak dBFS, RMS and DC offset for the selection.
- [ ] **5. Strip silence / split at silence**
  Auto-trim dead air from grabs and recordings, or drop slice markers at the gaps.
- [ ] **6. Utility processing**
  Invert polarity, remove DC, swap L/R, sum to mono (each a `transforming(range:)` call);
  a choice of normalize target instead of the fixed −0.3 dB.
- [ ] **7. Export slices to a folder**
  Write each slice as its own file (`Break 124 · 01.wav`, …) to a user-chosen folder,
  which the sandbox permits via the open panel.
- [ ] **8. Typed selection values**
  Start / end / length fields in samples, ms or beats, and a bars ruler at the project
  tempo so selections can snap to the beat grid.

## Medium

- [x] **9. Cut / copy / paste / insert silence** — *0851496*
  Standard Edit menu actions in the editor, plus Insert Silence and New Sample from
  Clipboard. Pastes are one de-clicked splice; clips spanning the insertion point are
  split around the new audio so the arrangement sounds the same.
- [ ] **10. Make a loop seamless**
  Crossfade the tail into the head over N ms, with an audition of just the seam.
- [ ] **11. Snap to transients**
  Cache detected onsets separately from slice markers and snap selection edges and
  markers to them while dragging (⌘).
- [ ] **12. Per-clip pitch and reverse (non-destructive)**
  Tonal mode can use `AVAudioUnitTimePitch.pitch` directly; Beats mode resamples after
  the WSOLA stretch. Pitch must join the stretch-cache key.
- [ ] **13. Spectrogram view**
  vDSP FFT tiles computed lazily per zoom level, like the peak pyramid, for spotting hum,
  clicks and breaths.
- [ ] **14. Drag a selection to Finder as WAV**
  Add an `NSFilePromiseProvider` alongside the existing ⌥-drag-to-track.

## Bigger projects

- [ ] **15. Pads mode**
  Slices on a 4×4 grid, played from the keyboard and MIDI, with choke groups, one-shot or
  gate, and per-pad gain/pitch; record performances to the armed track as quantized clips.
  Needs a preallocated polyphonic voice pool in the render callback, which today has a
  single preview voice.
- [ ] **16. Slice-based tempo following and groove**
  REX-style playback: each slice starts on its grid position, so tempo changes re-place
  slices instead of stretching them; groove quantize and groove extraction build on it.
  Can be done when the `RenderGraph` is built (one `RenderClip` per slice) without
  touching the audio thread.
- [ ] **17. Audio Unit effects**
  Offline "render through effect" on a selection is mid-sized (the same offline pattern
  `TimeStretcher` uses); live per-track inserts are harder because all tracks mix inside
  one `AVAudioSourceNode`.
- [ ] **18. Cheaper undo for long recordings**
  Each destructive edit copies the whole buffer and undo keeps every copy (about 230 MB
  per step for a 10-minute stereo take). Immutable shared chunks would make edits cost
  only their own size.

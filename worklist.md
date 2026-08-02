# UI Worklist

Outcome of a design review of the caption UI (macOS + iOS), 2026-08-01. Ordered by
perceptual payoff per line of diff. Rationale is recorded alongside each item because
most of these decisions came out of real usage constraints that aren't visible in the
code.

## Framing constraints

These shaped the whole list and are worth keeping in mind before changing anything:

- **The reading pattern is "ignore 20–30 seconds, then catch up."** Scrollback is the
  feature, not a side effect. The design target is *re-entering a block of transcript and
  reconstructing who said what quickly* — a scanning task. That's why paragraph rhythm and
  speaker separation are primary work rather than cosmetics, and why a reduced "glance mode"
  would be a downgrade.
- **Full session scrollback is load-bearing, especially on macOS.** It's used to caption
  client meetings, staying present through the meeting and mining the transcript for notes
  afterward. So: never cap retained lines or pass a `recentLimit` in the main view, keep the
  caption list lazy (don't group lines into container views that force a session to render
  eagerly), and favor work that helps *extract from* past transcript over work that reduces
  what's shown.
- **The bottom band on iOS is deliberate.** It's thumb clearance, and on a MagSafe dash
  mount it keeps the last caption line above the hand on the wheel. Don't reclaim it for
  more text. On iOS the goal is a *quieter* control bar at the same height, not a shorter one.
- **Themes:** `darkBlue` / `darkGreen` are in use ~90% of the time. Any hardcoded color
  (level meter, speaker bars) has to clear all four backgrounds — a green bar on
  `darkGreen` is the obvious casualty.
- **Font size is user-adjustable 20–72** (`PreferencesView.swift:30`), so every spacing
  value must be a multiple of `fontSize`, never a fixed point size.
- **Speaker separation has been overcorrected in both directions before.** It used to break
  per line and per sentence, which was distracting; the accumulator then merged runs so
  completely that adjacent speakers formed one continuous stripe that merely changed color.
  The target is a continuous bar within a speaker's turn and a clean break between turns.

---

## Tier 1 — small, self-contained, judge on device immediately

- [x] **Volatile text contrast.** `.secondary` → ~0.9 opacity at `CaptionDisplayView.swift:32`.

  *Why:* `.secondary` in dark mode is roughly 55% opacity, so the freshest text — the thing
  just said — is the hardest thing on screen to read. That inverts the app's priority. It's
  most painful in bright sunlight, where reflections wash the dark background toward gray
  and crush contrast from the top down. Alternatives if plain opacity feels wrong: full
  brightness with a subtle italic, or a thin animated underline — i.e. move the "provisional"
  signal off the contrast channel entirely.

- [x] **Top scroll edge effect.** `.scrollEdgeEffectStyle(.soft, for: .top)` on the caption
      `ScrollView`.

  *Why:* Text currently scrolls under the translucent toolbar and gets sliced mid-glyph,
  with the previous line ghosting through the glass. Worse on iOS, where the toolbar pills
  float directly over content. Fallback if `.soft` isn't enough is a manual mask gradient
  over the top ~40pt. Don't make the toolbar background opaque — that pushes captions down,
  and unlike the bottom, top space isn't reserved for anything.

- [x] **Line spacing and paragraph rhythm.** `lineSpacing ≈ fontSize * 0.16` inside a
      wrapped utterance; `≈ fontSize * 0.5–0.6` between utterances. Shipped at `0.16` /
      `0.5`; the inter-utterance value is the one most likely to want tuning after a look
      on device.

  *Why:* `LazyVStack(spacing: 0)` with no `lineSpacing` means the gap *inside* a wrapped
  utterance is identical to the gap *between* two utterances — the only cue separating
  thoughts is the capital letter. That's what makes it read as a wall. Note that on-device
  emits no `speakerID`, so it gets no speaker-based separation at all and this gap carries
  the entire job. Check the multipliers at both 20 and 72.

- [x] Center the empty state ("Ready for captions" currently strands at the top of a tall
      phone screen). Trivial; fold into whichever change touches `CaptionDisplayView`.

## Tier 2 — moderate, no blockers

- [ ] **Level meter: flat hot color.** Replace the green→yellow→orange gradient in
      `AudioLevelBar` with a single hue chosen to clear all four theme backgrounds.

  *Why:* The color channel already carries deliberate meaning — gray = audio present but VAD
  says no speech, color = VAD hot. That encoding is good and should be preserved. But the
  positional gradient *within* the hot state looks like a scale it isn't: a half-filled bar
  ending in orange implies "getting hot" when it only means "half filled."

- [ ] **Level meter: make the server-mode hot signal mean something.** Drive it from
      **token arrival from Soniox** instead of `speechDetected: smoothedLevel > 0.01`
      (`AudioCaptureSession.swift:282`).

  *Why:* Today the same visual encoding means two different things by backend, and in server
  mode it means almost nothing — a near-zero noise gate that's on whenever the room isn't
  silent. Worse, it can't show the failure that matters: hit a dead zone, the websocket
  stalls, no captions arrive, and the meter still looks healthy because the mic is still
  picking up audio fine. Wiring it to token flow makes it an end-to-end health signal
  covering capture + network + auth, and it's what tells you to hit the Local/Soniox toggle.
  Resulting encoding is consistent across modes: **length = am I capturing audio, color =
  is the backend producing anything.** A gray-but-moving bar then reads unambiguously as
  "audio fine, backend dead." This is the main reason the meter exists — confidence that an
  alternate input is actually delivering data.

- [ ] **Level meter as the panel seam.** Move it to a ~3pt full-bleed strip at the boundary
      between caption area and control bar.

  *Why:* `captureControlsBackground` already draws a `Divider()` at that edge
  (`LarmindonRootView.swift:376`, `:380`) — a hairline over `.thinMaterial` against a
  near-black custom background, effectively invisible. So this *replaces* an element rather
  than adding one, fixes the weak panel seam, and frees the horizontal space the 10pt capsule
  currently takes in the status row. Independent of the input chip merge; not blocked by it.

- [x] **Speaker bars.** Drop the right-hand bar. ~6pt horizontal inset. Rounded ends. One
      continuous bar per speaker block, with the gap between blocks outside the bar.

  *Pulled forward from Tier 2*, because the Tier 1 utterance spacing broke the bars at every
  line and that read as a regression — a speaker's turn fragmented into a dashed column.

  *Implementation note:* done without grouping lines into container views, which would have
  put a whole speaker turn inside one `LazyVStack` child and defeated laziness — on-device
  reports no speaker, so every line would land in a single block and render eagerly. Instead
  the list stays flat and each line carries two bottom paddings: one *inside* the bar overlay
  (so same-speaker utterances stay joined through the gap) and one *outside* it (so the bar
  breaks at a speaker change). Bar ends are square mid-block and rounded only at block
  boundaries; a capsule per line would pinch at every junction and undo the merge.

  *Why:* Two bars is double the chroma for single-duty information, and they visually cage
  the text. On iPhone they currently sit hard against the screen edge where the display
  curvature clips them. The bar's own vertical inset is what stops adjacent same-color runs
  from merging; the block gap is what separates speakers — right now consecutive runs butt
  together into one continuous stripe that merely changes color. Prior treatment was
  per-line/per-sentence separation (too noisy); the accumulator overcorrected the other way.

  *Complication:* `volatileCaptions` is an array (`volatile-0`, `volatile-1`, …), each with
  its own `speakerID`, so a speaker run can span the finalized→volatile boundary and one
  block can contain both solid and dimmed text. Opacity must stay per-line inside a block,
  not per-block. Also, `scrollSignature` only watches `lineCount` / last id / last text, so a
  speaker-only regrouping won't trigger a re-pin — probably fine, worth watching on device.

- [ ] **Explicit `bottomClearance`.** A `safeAreaInset` under the caption scroll view; 0 on macOS.

  *Why:* The dash-mount clearance is currently a byproduct of however tall `captureControls`
  happens to render, so any future change to that stack silently changes the driving
  ergonomics. Making it a stated value (fixed, or a preference tunable for the mount) pins
  the behavior and survives whatever the control bar becomes.

## Tier 3 — needs a decision

- [ ] **Speaker palette rework.** ~8 hues cycling, cool-first (blues/greens/purples, then
      reds/oranges/pinks), assigned by **order of appearance in the session** rather than ID
      modulo, with a second visual channel (doubled thin bar, dashed segment) for speakers 9+.

  *Why:* Soniox supports up to 15 speakers, but reliable hue discrimination on a 3pt bar in
  peripheral vision is more like 6–8 — chasing 15 unique hues yields colors that are distinct
  in a swatch grid and confusable in use. What matters is that speakers active in the *same
  stretch* differ, not that speaker 14 is globally unique. Cool-first ordering also means the
  common 2–3 speaker case never uses alert colors. Base16 is a good source palette.
  **Open:** per-theme contrast decisions, especially green-on-`darkGreen`.

- [ ] **`Local` rename + dynamic server segment.** Rename the `.onDevice` title to "Local",
      and derive the server segment's title from the active provider instead of the literal
      `"Soniox"` at `UserPreferences.swift:102`.

  *Why:* "Local" is 5 characters against "On-device"'s 9, which matters on iPhone where the
  pill competes with three toolbar buttons in one row. And the picker is conceptually a
  binary local/server toggle whose second segment is named for the active provider
  (`Local | Soniox`, `Local | Azure`) — it never grows a third segment, and the fast
  dead-zone toggle stays one tap.

  *Smaller than it first looked.* `TranscriptionMode` is already `.onDevice` / `.server`, so
  the type-level split exists — this is a title change plus reading the active provider,
  not a refactor. See the seams note under Long term.

- [ ] **Extracting from scrollback.** Today macOS has one affordance: a
      "Copy Full Transcript to Clipboard" command (`LarmindonApp.swift:51`). iOS has none.

  *Why:* the meeting workflow is "stay present, mine the transcript for notes afterward,"
  and full-transcript copy is a blunt instrument for it — after a 90-minute meeting you want
  the three paragraphs where a process was explained, not all of it. Each utterance is a
  separate `Text` with `.textSelection(.enabled)`, and SwiftUI scopes selection per view, so
  dragging a selection *across* utterances almost certainly doesn't work (quick to confirm
  on device — if it does work, most of this item evaporates).

  *Options, roughly increasing in effort:* copy-a-block on right-click / long-press, since
  speaker blocks are now a real structural unit; a selection mode that yields a contiguous
  range across utterances; timestamps on blocks so a copied excerpt can be located later; or
  session export to a file. **Open:** which of these actually fits how the notes get taken —
  worth describing the current manual process before building anything.

- [x] **Speaker markers in the copied transcript.** `[Speaker N]` at the start of each
      speaker turn, blank line between turns, in `CaptionStore.fullTranscript`.

  *Why:* the notes workflow is "Copy Full Transcript to Clipboard" → paste into a text editor
  with better search than this app has. Without markers, a Soniox transcript arrives as
  undifferentiated lines and there's no way to tell or find who said what. One marker per
  turn rather than per line, so it stays readable as prose and `[Speaker 2]` is a useful
  search target. On-device reports no speaker, so its output is unchanged.

## Long term

- [ ] **Azure Speech Services backend.** Configurable URL and key pointing at a
      self-hosted/owned Azure instance. **Deferred — medium to long term, not near-term
      work.**

  *Why:* this is the backend that would make the app usable for **work and client** material,
  where sending audio to a third-party API isn't acceptable but an Azure instance under our
  own control is. That's a different bar than the personal use Soniox covers, and it's the
  reason this is worth building even though Soniox is very good.

  *Open when it happens:* whether diarization is available and in what shape, and what the
  level meter's token-arrival hot signal maps to on a different protocol.

### Keeping the multi-provider seams open

Azure is deferred, so the near-term obligation is only **don't make it harder later**. Good
news: the seams already exist and are mostly right.

Already generic, don't undo:

- `TranscriptionMode` is `.onDevice` / `.server` — the mode axis is already provider-neutral
- `ServerProviderID` is a real enum registry (`UserPreferences.swift:107`)
- `ProviderCredentialStore` is keyed by `ServerProviderID`, not Soniox-specific
- `TranscriptionPreference.activeServerProviderStorageKey` exists, and `PreferencesView`
  already renders a Provider picker over `ServerProviderID.allCases`
- `TranscriptionSource` is a clean protocol (`results`, `levelUpdates`, `name`, `start`,
  `stop`) that a second provider satisfies without changes
- `CaptionSession.activeServerProvider` is tracked and already flows into diagnostics

The actual gap: **the active-provider preference is written but never read.** Everything
downstream hardcodes `.soniox` instead. These are the sites, and they're the corner to
avoid deepening:

- `UserPreferences.swift:102` — `TranscriptionMode.server.title` returns the literal `"Soniox"`
- `CaptionSession.swift:206` — `activeServerProvider = .soniox` rather than the stored value
- `CaptionSession.swift:418` and `makeSource`'s `.server` branch — credential lookup and
  source construction both assume Soniox
- `LarmindonRootView.swift:361` — `isSelectedModeConfigured` checks the Soniox credential
- `PreferencesView.swift:161`, `:175`, `:185` — save / remove / check credential

**How to apply:** when touching any of these, read the active provider from the stored
preference rather than adding another `.soniox` literal. Doing that incrementally means
Azure becomes "add an enum case and a `TranscriptionSource` conformance" rather than a
refactor. No need to do it as a dedicated project.

## Spectrum window (macOS)

Design discussion 2026-08-02, nothing built yet. A separate macOS window — **not** a pane —
showing a live spectral view of the captured audio, with the captioning window otherwise
untouched. iOS is explicitly out of scope: no room for it.

Treat this as a **feature**, not a debug instrument. Two use cases drive it, and they pull in
slightly different directions:

1. **Curiosity / analysis** — watching how the spectrum shifts as different people talk in a
   meeting. This is the stated motivation and the one that sets the DSP requirements.
2. **Ambient awareness** — "is someone talking right now," for when the hearing aid isn't in
   and it isn't otherwise obvious. This one sets the *presentation* requirements, and it's the
   one likely to get used daily.

There's a third payoff that falls out for free: the spectrum shows immediately whether a given
input is actually delivering the 4–8 kHz consonant band or a muddy 300–3400 Hz phone-quality
feed. That's the band fricatives live in, so it's the difference between captions being a
backstop and being load-bearing — and it's a question the level meter structurally cannot
answer.

### Build it in the app, not as a separate app

The FFT is the easy part. Getting audio out of an arbitrary macOS input device is the hard
part, and this repo has already paid for it — see the macOS capture constraints in CLAUDE.md,
every one of which came out of a real diagnostics bundle. A standalone app re-litigates all of
them, and then has to *contend* for the device: two processes on one input works for many
devices but not reliably for aggregates or anything exclusive-mode, and leaves two independent
device configurations to drift apart.

The decisive argument is that Larmindon knows things a generic analyzer can't — VAD, and in
server mode actual speaker labels. That's what makes speaker tinting possible at all.

### The capture code is already duplicated — converge it here

`SharedMacOSAudioDeviceCapture` (`AudioCaptureSession.swift:306`) and
`MacOSDirectAudioDeviceCapture` (`LiveSpeechAnalyzerTranscriptionSource.swift:501`) are
near-identical twins: same fields, same `ioQueue` / `ioProcID` / `isRunning`, same `deinit`,
same `captureFormat(deviceID:)` shape, down to duplicated sample-rate helpers
(`sharedMacOSNominalSampleRate` vs `macOSInputDeviceNominalSampleRate`). The only real
difference is how the buffer leaves — a closure vs. the `AudioTapSink` struct. "Shared" there
means "used by the shared/server path," not "shared between consumers."

So the refactor this feature needs is **not pure new cost**: it pays down a duplication that
already exists and currently means every macOS capture bug has to be fixed twice.

**Rule: extract, don't rewrite.** Move the existing IOProc logic across as literally as
possible and keep `MacOSAudioCaptureStrategy.forDevice` semantics identical. This is the code
CLAUDE.md says not to undo.

### Capture lifetime becomes reference-counted

- [ ] **Lift capture out from under `TranscriptionSource`.** Today audio only flows while a
      transcription session runs, because the source owns capture. The spectrum window needs
      audio without captioning.

  *Opt-in is the hard requirement:* capture runs **only** when captions are started **or** the
  spectrum window is open. Never otherwise. Lifetime is the union of demand from those two
  independent consumers.

  *Track named reasons, not an anonymous count.* Two payoffs: the UI can say "microphone is
  live because the spectrum window is open," and a stuck reason is diagnosable instead of being
  a refcount that's mysteriously 1. A leaked reason means the mic stays hot indefinitely —
  exactly the failure this design is guarding against.

  *Ordering rule to write down,* because "capture settings take effect at session start" gets
  ambiguous with two possible starters: **whoever starts capture first establishes the device
  and buffer size; the second consumer joins the existing capture.** The `activeInputDeviceID`
  restart guard carries over unchanged.

  *Wanted in `CoreTests`:* open plot → start captions → close plot → capture continues; then
  stop captions → device actually released.

### The tap seam already exists

Both paths converge on the same shape — `AudioTapSink.handle`
(`LiveSpeechAnalyzerTranscriptionSource.swift:816`) and `SharedAudioCaptureSink.handle`
(`AudioCaptureSession.swift:207`). Each already does one measurement pass, yields a level
snapshot, copies the buffer, yields the copy downstream. A third consumer goes at exactly that
point.

`copyPCMBuffer()` has already run for the transcription path, so the analyzer can yield *that
same reference* — one extra `continuation.yield` on the realtime thread, no additional copy.
Use `.bufferingNewest(2)` so drops are automatic and stale frames are discarded rather than
queued. When the window is closed, don't create the stream at all: zero cost in the common
case, which matters on battery during a long meeting.

**No FFT on the audio thread.** Non-negotiable — the visualization must never backpressure
capture or put transcription at risk.

### A spectrogram, not just an instantaneous spectrum

- [ ] **Scrolling spectrogram** (time on x, frequency on y, magnitude as color) as the primary
      view, with the instantaneous magnitude-vs-frequency plot secondary.

  *Why:* a live spectrum plot changes completely every phoneme. Within one speaker, the
  difference between /s/ and /ɑ/ is far larger than the average difference between two people,
  so watching it live shows mostly phonetics and buries speaker identity. What actually
  separates speakers is **F0** — visible as harmonic comb spacing — and **formant structure**,
  and formants move with whatever vowel is being spoken. Both only become legible *over time*.
  A spectrogram makes turn-taking visible as a texture change and pitch directly readable as
  the spacing of the horizontal harmonic stack. Same instinct as the scrollback rule: the
  history is the information.

  The FFT work is identical for both, so build one analyzer and two renderers. Motion is also
  what gets caught in peripheral vision, which serves use case 2.

### DSP parameters worth deciding up front

- **Accumulate into a fixed analysis frame.** Callback size is user-configurable
  (`AudioCaptureBufferFrames`) and won't match the FFT size. Ring-buffer into a fixed frame
  regardless of what arrives.
- **2048 @ 48 kHz** ≈ 43 ms, 23.4 Hz bins — resolves adult F0 harmonics (85–255 Hz spacing)
  while staying responsive. 4096 resolves pitch better but smears transitions; that tradeoff is
  the time-frequency uncertainty principle, not a tuning bug.
- **Hann window, 50% overlap.** Without windowing, speech spectra are leakage mush.
- **dB magnitude, floor ~-80 dB.** Linear magnitude shows nothing but the bottom few hundred Hz.
- **Log (or mel) frequency axis, ~50 Hz–16 kHz.** A linear axis spends three-quarters of its
  width on 6–24 kHz where speech has almost nothing, and crushes all the formant action against
  the left edge. This and the dB decision are the two that most determine whether the view is
  readable at all.
- **Cap analysis at ~20–30 spectra/sec,** decoupled from UI updates. Faster is wasted and only
  burns battery.
- Use vDSP/Accelerate; don't hand-roll the FFT.
- **Format handling:** the direct Core Audio path already delivers mono Float32
  (`AudioCaptureSession.swift:339`, `LiveSpeechAnalyzerTranscriptionSource.swift:531`), but the
  AVAudioEngine path taps with a `nil` format and gets whatever the bus is — so the analyzer
  still needs the Int16 and multichannel handling that `AudioLevelMeter.measure` already does.
- **Rendering:** blit one column into a retained bitmap per hop. Redrawing 500×256 cells as
  `Canvas` rectangles every frame will crawl.

### Plot-only mode has no VAD — this is the real gap

- [ ] **A cheap speech detector inside the analyzer.**

  *Why:* VAD today is a byproduct of the transcription pipeline — the `SpeechDetector` is built
  alongside the transcriber (`LiveSpeechAnalyzerTranscriptionSource.swift:226`), and server mode
  fakes it with `smoothedLevel > 0.01` (`AudioCaptureSession.swift:282`). With no transcriber
  there is no `speechDetected` at all, so use case 2 — the ambient-awareness one — is precisely
  the mode where the signal is missing. Spinning up the whole SpeechAnalyzer stack just for this
  is disproportionate.

  *Nearly free once the FFT exists:*
  - **Band-limited energy** (~300 Hz–3.5 kHz) rather than broadband RMS. This is exactly why the
    level meter is useless for the question: it can't tell a talking person from a fan.
  - **Spectral flatness** (geometric ÷ arithmetic mean of the magnitudes). Low = tonal/harmonic
    = voice; high = noise-like = hiss.
  - **4–8 Hz envelope modulation** — the syllable rate. The robust one, and what separates
    speech from a steady tonal hum that flatness alone would false-positive on. Falls out of the
    frame-energy series already being computed.

  Flatness + band energy is probably enough for v1; modulation is the upgrade, not the starting
  point. The speech/no-speech state should be readable without interpreting the DSP.

### Keeping speaker tinting open

Tinting spectrogram columns by speaker — or keeping a per-speaker running average spectrum,
where phoneme noise cancels over seconds and real between-speaker differences emerge — is a
**nice-to-have, not near-term**. But two things are cheap now and expensive to retrofit:

1. **Timestamp every analysis frame** on the same clock as caption events. Tinting later
   becomes a lookup rather than a re-architecture.
2. **Keep spectrogram history as magnitudes, not pixels.** Soniox speaker labels land *after*
   the audio, so retroactive coloring is the normal case, not the exception. Store
   `(timestamp, [Float])` columns and treat the bitmap as an invalidatable render cache.

No speaker plumbing today — just don't throw away what makes it possible.

### Presentation

Since it's a feature and half its job is peripheral awareness: small, always-on-top option,
legible from across the room and out of the corner of the eye. High contrast. Follows the
theme constraints in Framing above — any hardcoded color has to clear all four backgrounds.

**Decided 2026-08-02:**

- **Passive glancing, no active signaling.** No Dock badge, no notifications. There are almost
  always multiple monitors, so the window is simply in view. Revisit only if it turns out not
  to get noticed in practice.
- **Shares the captioning device preference.** No separate input selection in this window.
  Consistent with the first-starter-establishes-the-device rule above.

**Still open:** whether the instantaneous spectrum earns its space once the spectrogram exists.

### History retention and memory

**Bound the ring; then memory is a non-issue and full-resolution storage is affordable.**
Scrollback is explicitly *not* wanted here — unlike the caption transcript, where it's the
whole point — so retention only needs to cover what's on screen plus resize headroom.

A 2048-point real FFT yields 1024 magnitude bins. Per column: **4 KB** at Float32,
1 KB reduced to 256 log-spaced bands, 256 B if those are quantized to UInt8 dB.

At 50% overlap on 48 kHz the hop is 1024 samples = 21.3 ms, so **~47 columns/sec**:

- *Unbounded:* 188 KB/s → **11 MB/min → ~676 MB/hour** at full resolution. A 90-minute client
  meeting is a gigabyte. Even the quantized form is ~42 MB/hour. Not viable — this would be the
  first thing in the app to misbehave under the actual workload.
- *Bounded ring, full resolution Float32:* 30 s ≈ 5.6 MB, **60 s ≈ 11 MB**, 120 s ≈ 22 MB.

**Plan: preallocated ring at ~60 s, all 1024 bins as Float32.** Don't quantize and don't
downsample to display bands — retaining full-resolution magnitudes means window resize, a
changed dB floor, a retuned color ramp, or switching between log and mel axes are all re-renders
from retained data instead of waiting for new audio to scroll past. Worth 11 MB. Preallocation
also means zero allocation churn across a 90-minute meeting, which matters more than the byte
count.

*Size the ring by duration, not column count,* deriving columns from the actual hop rate — a
96 kHz device otherwise doubles the column rate and the same ring covers half the time. Capping
analysis at 20–30/sec (see DSP parameters) makes the rate device-independent anyway.

*Convenient coincidence:* at ~47 columns/sec and one column per pixel, a 1000px-wide spectrogram
shows ~21 seconds — naturally in the same range as the 20–30 second "ignore, then catch up"
window in Framing above. A ring of 2–3× the visible width covers resize headroom without much
thought.

*No conflict with speaker tinting.* Soniox labels land a second or two behind the audio, so a
60 s ring has an order of magnitude of margin for retroactive coloring. And the per-speaker
average spectrum idea doesn't touch the ring at all — it's a running sum and count per speaker,
a few KB total regardless of meeting length.

## Blocked

- [ ] **Input chip merge.** `InputSelectionMenu(labelTitle: routeManager.currentInputName)`
      at `LarmindonRootView.swift:308`, deleting `inputNameLabel` and its whole row.
      iOS mirror at `InputPickerControl.swift:71`.

  *Why:* "are we getting audio and from where" is currently expressed five ways — green dot,
  "Listening · On-device", the level meter, `Input: System Loopback`, and the `Input ⌄`
  button. The clutter is the redundancy, not the meter. `InputSelectionMenu` already takes a
  `labelTitle:` parameter, so on macOS this is a one-line call-site change.

  *Blocked on:* the `Input: Unknown` bug on iOS — the chip would read `Unknown ⌄`, which is
  worse than the current label because it's now the control itself. That's in turn behind a
  known picker device-handling bug. Needs a session where testing by talking at the phone is
  possible.

  *Also:* in the iOS `compactLandscape` layout the controls sit in a 240–300pt column and the
  current `Label` survives via `minimumScaleFactor(0.75)` + `lineLimit(2)`. A `Menu` label
  won't scale down automatically — long device names need explicit truncation there.

## Conditional / undecided

- [ ] **Speaker naming.** Tap a bar, type a name, persists for the session; labels appear
      only for named speakers.

  *Why:* At 2–3 speakers, `Speaker 3` is noise — color already says everything and the number
  says nothing. Labels only pay rent at higher speaker counts, which is exactly where you
  can't remember which number is whom anyway. So labels should *follow* naming, not precede
  it. If added: `fontSize * 0.32`, uppercase, slightly tracked, in the speaker's color, at
  the top of the block.

- [ ] **Peak / clip detection.** Track `max(abs(sample))` alongside RMS in the existing
      passes; drive a separate clip tick from it.

  *Why:* Only worth it if distortion has actually been a problem. `normalizedRMS` returns
  `rms * 8` clamped to 1 (`AudioLevels.swift:87`), so the bar pins at full at an RMS of
  0.125 — nowhere near digital full scale. It saturates long before anything distorts and
  can't distinguish "loud" from "actually clipping," so a clip indicator built on the
  current value would be lying.

## Dropped

- **High-contrast light theme.** Considered for the bright-sunlight case, since light-on-dark
  is the worse choice outdoors (reflections wash the dark background toward gray). Dropped:
  darkBlue/darkGreen are in use ~90% of the time, the real sunlight complaint is volatile
  dimness, and the current `light` preset is system default rather than a sunlight-tuned
  pairing so it wouldn't have helped anyway. Easy to revisit.
- **Glance mode** (last 2–3 utterances, larger type, minimal chrome). Dropped: scrollback is
  the point. Being able to ignore 20–30 seconds while navigating traffic and then catch up
  is a deliberate advantage of the current layout, and a mode that discards it is a downgrade.

## Diagnostics (done, off the original list)

Added while diagnosing a "no captions appearing" report that turned out to be zero tokens
from Soniox. The bundle could prove audio *flowed* but not that it *contained anything*,
so answering the question required asking the user what the level meter had been doing.

- [x] **Signal level in `capture_aggregate`.** `rms_dbfs`, `peak_dbfs`, and
      `silent_callbacks`, cumulative over the session.

  *Why:* Callback and frame counts can't distinguish 441,000 frames of speech from 441,000
  frames of silence. `peak_dbfs` answers "did anything ever arrive," and `silent_callbacks`
  separates a device delivering digital zeros (loopback with nothing playing, muted input)
  from one delivering a very quiet room (mic gain too low). Values are unscaled, unlike the
  meter — `normalizedRMS` applies a ×8 display gain and clamps, so it saturates at an RMS of
  0.125 and can't represent anything above that.

- [x] **Device names in `capture_route`.** `active_input_name` and `preferred_input_name`
      alongside the existing hashed IDs.

  *Why:* `DiagnosticRedaction.identifier` FNV-hashes device IDs, so a bundle showed
  `device-ecb307f9ac8c5fe2` with no way to tell the built-in mic from loopback from a USB
  interface — which is the first thing you need when captures come back silent. **Note the
  tradeoff:** this is a deliberate partial relaxation of the redaction design, since device
  names can be personal ("<name>'s AirPods"). The hashed IDs are unchanged and still there.
  Reverse it if bundles ever get shared beyond this project.

- [x] `AudioLevelMeterTests` covering unscaled RMS/peak, transient capture, digital silence
      vs. quiet signal, Int16/Float parity, display-gain clamping, and dBFS formatting.

## Minor observations

- The Stop button treatment should split by platform: on iOS a large, saturated,
  thumb-reachable button is correct — it may need to be hit without looking. On macOS it's
  the loudest object in the window for a state you're already in; desaturating it costs
  nothing, since `comfortableControlHeight` is only 32pt there and the bulk comes from width.
- The debug toolbar button uses `sidebar.trailing`, which reads as a layout toggle rather
  than diagnostics. `waveform.badge.magnifyingglass` or `ladybug` would be clearer.
- Consider capping the caption measure on macOS (`maxWidth` ≈ 880, left-aligned). At full
  window width some lines run well past comfortable reading length.

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
- **The bottom band on iOS is deliberate.** It's thumb clearance, and on a MagSafe dash
  mount it keeps the last caption line above the hand on the wheel. Don't reclaim it for
  more text. On iOS the goal is a *quieter* control bar at the same height, not a shorter one.
- **Themes:** `darkBlue` / `darkGreen` are in use ~90% of the time. Any hardcoded color
  (level meter, speaker bars) has to clear all four backgrounds — a green bar on
  `darkGreen` is the obvious casualty.
- **Font size is user-adjustable 20–72** (`PreferencesView.swift:30`), so every spacing
  value must be a multiple of `fontSize`, never a fixed point size.

---

## Tier 1 — small, self-contained, judge on device immediately

- [ ] **Volatile text contrast.** `.secondary` → ~0.9 opacity at `CaptionDisplayView.swift:32`.

  *Why:* `.secondary` in dark mode is roughly 55% opacity, so the freshest text — the thing
  just said — is the hardest thing on screen to read. That inverts the app's priority. It's
  most painful in bright sunlight, where reflections wash the dark background toward gray
  and crush contrast from the top down. Alternatives if plain opacity feels wrong: full
  brightness with a subtle italic, or a thin animated underline — i.e. move the "provisional"
  signal off the contrast channel entirely.

- [ ] **Top scroll edge effect.** `.scrollEdgeEffectStyle(.soft, for: .top)` on the caption
      `ScrollView`.

  *Why:* Text currently scrolls under the translucent toolbar and gets sliced mid-glyph,
  with the previous line ghosting through the glass. Worse on iOS, where the toolbar pills
  float directly over content. Fallback if `.soft` isn't enough is a manual mask gradient
  over the top ~40pt. Don't make the toolbar background opaque — that pushes captions down,
  and unlike the bottom, top space isn't reserved for anything.

- [ ] **Line spacing and paragraph rhythm.** `lineSpacing ≈ fontSize * 0.16` inside a
      wrapped utterance; `≈ fontSize * 0.5–0.6` between utterances.

  *Why:* `LazyVStack(spacing: 0)` with no `lineSpacing` means the gap *inside* a wrapped
  utterance is identical to the gap *between* two utterances — the only cue separating
  thoughts is the capital letter. That's what makes it read as a wall. Note that on-device
  emits no `speakerID`, so it gets no speaker-based separation at all and this gap carries
  the entire job. Check the multipliers at both 20 and 72.

- [ ] Center the empty state ("Ready for captions" currently strands at the top of a tall
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

- [ ] **Speaker bars.** Drop the right-hand bar. ~6pt horizontal inset. `Capsule` instead of
      `Rectangle`. 2pt vertical inset within a block, plus `fontSize * 0.5` gap between blocks.

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

- [ ] **`Local` rename + dynamic server segment.** `TranscriptionMode` → `.local` /
      `.server(provider)`, with the second segment labeled by the active backend.

  *Why:* "Local" is 5 characters against "On-device"'s 9, which matters on iPhone where the
  pill competes with three toolbar buttons in one row. More importantly: many server backends
  can be *configured* but only one is active, so the picker is really a binary local/server
  toggle whose second segment is named for the active provider (`Local | Soniox`,
  `Local | Whisper`). It never grows a third segment, and the fast dead-zone toggle stays one
  tap. **Open:** do this now, or when a second backend actually exists? Lean is now — cheaper
  before there's migration to worry about, and the rename is happening anyway.

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

## Minor observations

- The Stop button treatment should split by platform: on iOS a large, saturated,
  thumb-reachable button is correct — it may need to be hit without looking. On macOS it's
  the loudest object in the window for a state you're already in; desaturating it costs
  nothing, since `comfortableControlHeight` is only 32pt there and the bulk comes from width.
- The debug toolbar button uses `sidebar.trailing`, which reads as a layout toggle rather
  than diagnostics. `waveform.badge.magnifyingglass` or `ladybug` would be clearer.
- Consider capping the caption measure on macOS (`maxWidth` ≈ 880, left-aligned). At full
  window width some lines run well past comfortable reading length.

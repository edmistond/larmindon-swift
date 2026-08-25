# Evaluation plan — larmindon-swift

Companion to `larmindon-core/eval-plan.md`, which owns the corpus, the panel and
stream manifests, the `en-v1` text normalizer, the emission-log schema, and the
`score` binary. **Everything in that document applies here and is not repeated.**
This document covers the things that are hard specifically because this app runs
on Apple's audio stack.

The core plan assumes a fake capture backend is close to free — in
`larmindon-core` it already exists as `examples/replay_wav.rs`. Here it is the
central problem, because the interesting behaviour lives *in* the pipeline a
file-fed source would bypass.

## 1. Three questions, three different places they can be answered

| question | iOS Simulator | macOS | iOS device |
| --- | --- | --- | --- |
| does it compile / does non-audio logic work | ✅ | ✅ | ✅ |
| does our own DSP front-end behave | ❌ | ✅ **primary** | ✅ |
| does Apple voice processing help or hurt | ❌ | ❌ **impossible** | ✅ **only** |
| Soniox token/segment handling | ✅ (fake transport) | ✅ | ✅ |

Two hard constraints set this table:

- **SpeechAnalyzer does not run in the iOS Simulator.** The simulator build
  proves compilation, nothing more.
- **Voice processing is never enabled on macOS** — see the macOS audio capture
  section of `CLAUDE.md`. It is a duplex unit spanning input and output, the
  rate mismatch fails `engine.start()` with -10875, and the aggregate device it
  creates used to retrigger capture in a loop. The preference is iOS-only on
  purpose and must stay that way.

The consequence is worth stating plainly, because it is the single most
awkward fact in this plan: **the observation that motivates the whole thing —
voice processing helping on-device SpeechAnalyzer in room audio and hurting
Soniox speaker ID — cannot be measured on the machine the harness runs on.** It
is a physical-device experiment or it is nothing.

## 2. The capture-fidelity ladder

A file-fed capture source is not one thing; it is a rung on a ladder, and which
rung is required depends entirely on which question is being asked. Building the
cheap rung and using it to answer an expensive rung's question is the main way
this effort could produce confidently wrong numbers.

**Rung 0 — file → sink.** Read an `AVAudioFile`, produce `AVAudioPCMBuffer`s,
push them into the same sink the tap feeds (`AudioCaptureSession.handle(_:)`,
the `onBuffer` path at `Sources/SpeechPipeline/AudioCaptureSession.swift:342`),
paced by an injectable clock. Bypasses the input node, the route, and voice
processing entirely.

- Valid for: our own DSP front-end (§4), Soniox token handling, accumulator and
  finalization logic, latency of everything downstream of capture.
- Invalid for: anything about voice processing, AGC-on-the-device, mic
  characteristics, or route selection. Do not let a rung-0 number stand in for a
  rung-2 claim.
- Runs on macOS and in CI. This is the workhorse.

**Rung 1 — virtual input device (macOS only).** Loopback or BlackHole presents a
virtual input; the harness plays the file into it and the app captures it as an
ordinary device. This exercises `MacOSDirectAudioDeviceCapture`, the Core Audio
IOProc path, format negotiation, and device selection — the parts of
`AudioCaptureSession` that rung 0 skips, and the parts that have historically
broken.

- Note it exercises `MacOSAudioCaptureStrategy.forDevice`, *not* the
  `AVAudioEngine` default-input path, since a virtual device is not the system
  default unless it's made so. Test both by toggling the system default.
- Still cannot test voice processing, because macOS never enables it.

**Rung 1b — USB line-level input to the iPhone (hardware confirmed).** A
**Cubilux CB-5** is on hand and confirmed working as a Larmindon input on iOS,
so the route enumerates, is selectable in-app, and carries line-level audio.
That makes this the most promising rig for the §3 experiment: same file, same
levels, no room, no drift between runs, and no acoustic alignment problem.

One question remains open, and it is narrower than "does this work" — it is
**does voice processing behave the same on a USB route as on the built-in mic**.
VPIO applies to input routes generally, but Apple tunes the built-in mic path
with hardware-level processing a USB route does not get, and the AEC reference
differs. So validate transfer before relying on it:

- run the same Tier 2 stream VP-on and VP-off over the CB-5, and again over the
  built-in mic with an acoustic source (rung 2)
- check that the *direction and rough magnitude* of the VP effect agree across
  the two routes

If they agree, rung 1b becomes the primary VP rig and rung 2 drops to periodic
recalibration. If they diverge, rung 1b is still the right repeatability check
for everything except VP, and rung 2 becomes mandatory for VP claims
specifically. Either way the validation is a single afternoon and it determines
the cost of every VP question after it — which is why it sits early in §8.

Practical notes for this rung: fix the interface's input gain and record it in
the run header (a changed gain trim silently rescales every level-dependent
result); confirm whether iOS is applying any input-gain automation to the route
by checking `AVAudioSession.inputGain`; and keep the leader tone from rung 2 in
the generated files anyway, since it costs nothing and makes rung 1b and rung 2
runs alignable by the same code path.

**Rung 2 — acoustic rig (iOS device).** A speaker playing the file in a room,
the device miking it. This is the only unimpeachable test of a room-audio claim,
and it is the least repeatable thing here, so it needs to be *made* repeatable:

- fixed geometry — speaker and device positions marked and recorded, distance
  and angle written into the run header
- calibrated playback level, set once with an SPL meter at the device position
  and re-checked per session
- the room named in the run header, with at least two rooms (small/damped and
  large/reverberant) rather than one
- a fixed leader tone in every generated file so the emission log can be aligned
  to the source timeline despite acoustic and buffering delay — without this,
  every latency number from rung 2 is uninterpretable

Rung 2 runs are expensive and non-hermetic. Use them to *calibrate* rung 0/1b —
establish that the cheap rungs rank changes the same way — and then use the
cheap rungs day to day, re-validating on a schedule rather than per change.

**Rung 3 — real usage.** 20 minutes of genuine recorded use with hand-typed
ground truth. Same argument as in the core plan: this is the validity check that
LibriSpeech cannot be.

## 3. The voice-processing × backend experiment

The claim to be tested, from extensive iOS use:

- on-device SpeechAnalyzer in room audio: VP **on** is significantly better
- Soniox: VP **on** noticeably degrades quality, especially speaker ID

This is a 2×2 (`{onDevice, server}` × `{VP on, VP off}`) run over the same audio,
and it is the first thing the harness should be built to answer, because a
confirmed result changes the app's behaviour (§3.1) rather than just producing a
number.

Design notes:

- Run it at rung 2 (or 1b if validated), on the device, on Tier 2 long-form
  streams from the core plan — not Tier 1 clips. Speaker ID cannot be scored on
  7-second single-speaker utterances, and the two-speaker Tier 2 streams carry
  real speaker ground truth.
- Score speaker ID separately from WER. The hypothesis is specifically that VP
  degrades diarization *more* than it degrades word accuracy, which means a
  pooled metric would hide the effect. Report WER and DER/label-purity side by
  side.
- Plausible mechanism, worth recording as a prediction to check: VPIO's AEC,
  noise suppression, and AGC are tuned to preserve a single near-field talker,
  which is exactly what helps a single-speaker on-device model in a noisy room
  and exactly what would suppress the secondary-speaker cues a diarizer needs.
  If that's right, the degradation should grow with the number of speakers and
  shrink at high SNR — both testable, and both cheap once the rig exists.
- Log **both** `requestedVoiceProcessingEnabled` and
  `activeVoiceProcessingEnabled` plus `voiceProcessingSkippedReason` into the
  run header. `AudioCaptureSession` already tracks all three. On macOS the
  active value is always false with a skip reason, which is precisely the
  metadata that stops a macOS run being misread later as a VP-on result.

### 3.1 Per-backend scoping of the preference

Independently of the measurement, the app should stop making this a global
toggle the user must remember to flip when switching backends.

`VoiceProcessingPreference` (`Sources/Core/UserPreferences.swift:156`) is a
single key, `voiceProcessingEnabled`, default `true`. Make it per-mode:

- keys `voiceProcessingEnabled.onDevice` and `voiceProcessingEnabled.server`,
  with a one-time migration writing the old global value into both so nobody's
  current setting silently changes
- defaults follow the finding once confirmed: on for `onDevice`, off for
  `server`
- resolution happens at session start, in `LarmindonRootView` where the
  `@AppStorage` values are already read and passed into `CaptionSession.start(...)`
  — the established pattern from `CLAUDE.md`, and it keeps the existing
  "capture settings apply at Stop → Start" contract intact
- `PreferencesView` shows the toggle for the active mode; `MicrophonePanelView`
  already surfaces requested vs active and needs no change
- switching mode mid-session requires a restart to re-resolve, consistent with
  every other capture setting

Do the migration and the plumbing *before* the experiment, not after. It makes
the 2×2 a matter of setting two defaults rather than hand-toggling between
conditions, which is the difference between a rerunnable experiment and a
one-off.

## 4. A custom DSP front-end

Apple exposes few VAD and AGC levers, so heavier optimization for noisy rooms
means our own processing between capture and SpeechAnalyzer. Two things make
that more attractive than it first looks:

- `larmindon-core` already has `agc.rs` (14K) and `vad.rs` (25K), tuned against
  real usage. The design work is largely done; this is a port or an FFI binding,
  not a from-scratch build.
- **macOS currently gets no voice processing at all.** Our own front-end is the
  only route to parity there, so the work pays for itself on the desktop app
  regardless of what the iOS experiment concludes.

Testing it is the *easy* case: it sits downstream of capture and upstream of
SpeechAnalyzer, so rung 0 exercises it fully, on macOS, in CI, with the same
degradation matrix the Rust core uses. Feed a degraded file in at rung 0, score
the output, compare curves against the Rust implementation on identical audio —
which the shared emission format makes a direct comparison rather than an
argument.

The decision it must eventually answer on device is not "does our DSP work" but
**"our DSP + VP off vs Apple VP on"**, and possibly both together. Structure the
front-end so it can be bypassed by configuration, so all three arms are one
launch parameter apart.

## 5. Driving a physical device headlessly

Yes — and without UI automation. Verified on this machine: Xcode 26.6,
`devicectl` 518.33, iPhone 15 Pro Max paired and `available` over the network.

`xcrun devicectl device` provides the whole loop:

| step | command |
| --- | --- |
| install | `devicectl device install app --device <UDID> <path>.app` |
| launch with config | `devicectl device process launch --device <UDID> --console --environment '{"LARMINDON_EVAL":"tier2-two-speaker-a","LARMINDON_VP":"off"}' <bundle-id>` |
| retrieve results | `devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier <bundle-id> --source Documents/eval --destination ./runs/` |
| machine-readable output | `--json-output <path>` on any subcommand |

`scripts/redeploy-device.sh` already handles signing, profile refresh, and
device selection, so the eval runner should call it rather than reimplementing
build and install.

Design the eval mode to be driven by **launch environment / arguments, not UI
state**. That removes the need for XCUITest entirely and makes each run
hermetic: the app reads the panel ID, backend, and VP setting from the
environment, runs, writes `Documents/eval/<run-id>/emissions.jsonl`, and exits.
XCUITest on device (`xcodebuild test -destination 'platform=iOS,id=<UDID>'`) stays
available if a genuinely UI-level behaviour ever needs checking, but it is
slower and more brittle and this doesn't need it.

`devicectl device notification post` can trigger an in-app run without a
relaunch, which is useful for a rung-2 session where relaunching between the
four arms of the 2×2 wastes rig setup time.

**What no amount of automation solves: audio input.** iOS has no virtual audio
device — Loopback is macOS-only, and nothing equivalent exists on iOS. Audio has
to physically enter the device, over USB (rung 1b) or acoustically (rung 2).
The automation makes the *rig* repeatable and the results collectable; it does
not make the signal path virtual. Budget for that: the VP experiment involves
physical setup, and the useful thing software can do is guarantee that the same
files, levels, and conditions are replayed identically each time.

## 6. Getting results off the device

The diagnostics infrastructure already does most of this:
`DiagnosticStore.writeSnapshot(to:)` (`Sources/Debug/DiagnosticStore.swift:365`)
produces a consistent copy while the writer holds the DB in WAL mode. Reuse it —
write `emissions.jsonl` alongside a diagnostics snapshot into
`Documents/eval/<run-id>/`, and pull the directory with `devicectl device copy
from`. No share sheet, no manual step, and the diagnostics rows explain any run
whose numbers look wrong.

## 7. Soniox here

The core plan's allocation applies: Soniox is strong in noise, weak on flaky
networks and overlapping speakers, so the SNR sweep is not where the effort
goes.

This repo is already ahead on the free half.
`Tests/CoreTests/FakeWebSocketTransport.swift` plus the `WebSocketTransport`
protocol is exactly the seam needed for network-fault testing at zero API cost:
mid-utterance close, delayed frames, out-of-order finals, reconnect mid-segment,
and the `finish()` → `finished: true` → close shutdown sequence that
`SonioxTranscriptionSource.stop()` is deliberately re-entrancy-safe around.
That last one is a documented sharp edge with a stated failure mode and no test.
Extend those tests first — it is the highest-value work in this document per
hour spent, needs no audio, no device, and no money.

Paid Soniox time goes to overlapping-speaker Tier 2 streams and to the `server`
arm of the VP 2×2. Use a separate evaluation API key so test spend is visible on
its own; at $0.12/hr a 5-minute stream is about a cent, and the exposure worth
guarding against is an unattended loop, not any single run.

## 8. Build order

1. **Soniox transport-fault tests** against `FakeWebSocketTransport` (§7). Free,
   no device, targets a known weak spot.
2. **Per-backend VP preference** with migration (§3.1). Small, ships a real
   usability fix, and is a precondition for running the experiment cleanly.
3. **Rung 0 file-fed capture source** + `--emit-jsonl` writing the core plan's
   schema, on macOS. Unlocks CI-able quality measurement for everything
   downstream of capture.
4. **Headless device runner** — `redeploy-device.sh` + `devicectl` launch with
   environment + `copy from` (§5).
5. **Rung 1b VP-transfer validation** over the CB-5 (§2). Hardware is in hand,
   so this is one afternoon, and it decides whether the VP experiment is
   repeatable-electrical or physical-acoustic — which sets the cost of every
   subsequent VP question.
6. **The VP × backend 2×2** (§3) on whichever rig §5 validated.
7. **DSP front-end**, evaluated at rung 0 against the Rust implementation on
   identical audio (§4), with the on-device three-arm comparison last.

# Input picker puts the hearing aid into streaming mode

**Status:** parked on 2026-09-29, until the Soniox finish, reconnect, Opus and crash fixes
have had a few days of on-device testing. Nothing here is implemented. As of 2026-09-30 this
is a battery problem as well as an annoyance (see "Battery cost"), and it should be fixed,
not just worked around.

## Symptom

On iOS, tapping **Input** puts the Phonak hearing aid into streaming (phone-call) mode even
when it isn't the selected input. It stays that way after the picker closes while captions
are running.

## Evidence

From diagnostics bundle `larmindon-diagnostics-7D20A0FF…`, 2026-09-29 18:49–18:50 local,
`audio_route/capture_route` events:

| Time | What happened | Session | Input → output |
|---|---|---|---|
| 18:49:38 | Soniox capture running | `Record` / `Measurement` | iPhone mic → none |
| 18:49:51 | Input tapped; app reconfigures the live session | `PlayAndRecord` / `VoiceChat`, `.allowBluetoothHFP` | **Phonak (HFP) → Phonak (HFP)**, preferred input none |
| 18:49:55 | Capture restarts with preferred input = Phonak | same | Phonak → Phonak |
| 18:50:26 | Preferred input back to iPhone mic | same | **iPhone mic → Phonak (HFP)** |

- **The route flipped to the aid at 18:49:51**, as soon as the picker was set up and before
  any choice.
- **At 18:50:26 the aid was still the output** while the iPhone mic was the input.
- **Unexplained:** the preferred input became the Phonak at 18:49:55. David didn't intend to
  pick it. It could be a mis-tap, or the picker reporting the route it landed on as the
  selection. The bundle can't tell these apart; see "Diagnostics first" below.

Normal capture never showed this. With voice processing off and a non-Bluetooth input,
capture uses `Record` / `Measurement` with no Bluetooth options, so there's no HFP route.

## Why it happens

**What comes with iOS:**
- The aid's mic is only reachable through Bluetooth HFP, a two-way call link. Any route
  through it puts the aid into call mode.
- The picker can only list the aid if the session allows HFP input.
- With HFP allowed and no preferred input, iOS tends to route to the connected Bluetooth
  device. That's observed behavior, not a documented rule.
- As far as I recall, Apple only allows `setPreferredInput` after the session is active, so
  a brief detour to the default route may be unavoidable. Not confirmed on a device.

**What Larmindon adds:**
1. `configureForInputSelection` ([AudioRouteManager.swift:84](Sources/AudioRouting/AudioRouteManager.swift:84))
   activates `PlayAndRecord` / `VoiceChat` / `.allowBluetoothHFP` *before* applying any
   preferred input. The picker button calls it with a default configuration
   ([InputPickerControl.swift:100](Sources/AudioRouting/InputPickerControl.swift:100)), so
   the saved selection isn't reapplied and iOS picks the aid.
2. It does this **even while capture is already running** on a non-Bluetooth input in
   `Record` / `Measurement`, switching the live session to a call-style one.
3. After the picker closes, the session is released only when captions are stopped
   (`releaseAudioSessionWhenDismissed: !session.store.isRunning`,
   [LarmindonRootView.swift:342](Sources/UI/LarmindonRootView.swift:342)). The Microphone
   panel's picker ([MicrophonePanelView.swift:328](Sources/UI/MicrophonePanelView.swift:328))
   never releases it. While running, `PlayAndRecord` keeps the HFP output link open until
   the next Start.
4. With the voice-processing preference on, capture itself uses the same call-style session
   (`IOSAudioSessionCapturePolicy`,
   [AudioRouteManager.swift:368](Sources/AudioRouting/AudioRouteManager.swift:368)), so it
   has the same exposure.

## Battery cost

A call-style session costs more than the `Record` / `Measurement` session that capture
needs, beyond the annoyance of the aid going into streaming mode:

- **The phone's audio hardware runs both directions.** `PlayAndRecord` keeps an output path
  running next to the input, and `VoiceChat` asks iOS for its voice-call processing. Capture
  needs neither while the input isn't Bluetooth and voice processing is off.
- **The Bluetooth link runs as a two-way call.** While the aid is on HFP, the phone keeps a
  call-grade audio link to it. That costs phone battery, and the aid's own battery too.
  Streaming mode is typically the hardest use for a hearing aid's battery.

How long it lasts:

- **Captions running:** from the first use of the picker until the next Start (Larmindon
  addition 3 above). In a long meeting that can be hours.
- **Captions stopped, Microphone panel open:** bundle `larmindon-diagnostics-74F83876…`,
  2026-09-30 08:00:44 local, shows `PlayAndRecord` / `VoiceChat` with the iPhone mic as
  input and nothing capturing. That comes from `prepareMicrophoneControls` calling
  `configureForInputSelection`. `releaseMicrophoneControls` deactivates it when the panel
  closes, so this case is limited to the time the panel is open. It still puts a connected
  aid into streaming mode for that time.

Candidate fixes 1 and 3 below are therefore battery fixes as well. To measure them, compare
the `cpu_user_ms`, `cpu_system_ms`, `wakeups` and `task_energy` resource-sample fields
(added in d5ccaef) across a running session before and after using the picker. Bluetooth
radio energy probably isn't billed to the app's `task_energy`, so for the link to the aid,
the aid's own battery drain is the better signal.

## Diagnostics first

Before changing behavior, log the picker so the next bundle settles the 18:49:55 question:

- `input_picker_presented` with the preferred input, current route and session
  category/mode *before* reconfiguring, and again after.
- `input_picker_dismissed` with the preferred input and route, plus whether
  `onInputSelectionChanged` is about to restart capture.

A preferred-input change between those two events with no deliberate tap points at the
picker or at `inputSelectionDidChange`, rather than a mis-tap.

## Candidate fixes, least intrusive first

1. **Restore the capture setup when the picker closes.** If the chosen input isn't
   Bluetooth HFP and voice processing is off, return to `Record` / `Measurement` so the HFP
   output link drops. Do the same for the Microphone panel's picker.
2. **Reapply the saved input immediately after activating** in `configureForInputSelection`,
   by passing the current `MicrophoneCaptureConfiguration` instead of the default. That
   shortens any detour to the aid.
3. **Don't reconfigure a running session** unless the current category can't list Bluetooth
   inputs. Present the picker against the live session where possible.
4. **Experiment on a device:** does a plain `Record` session with `.allowBluetoothHFP` (no
   `VoiceChat`, no output side) still list the aid in `AVInputPickerInteraction`? If so, the
   picker never needs a call-style session, and the aid may not enter call mode until it's
   actually chosen.

## How to verify

This can only be checked on hardware with the aid connected. For each case, watch whether
the aid goes into streaming mode, and export a bundle to check the `capture_route` inputs,
outputs and category.

- **Captions stopped:** open the picker, dismiss without choosing.
- **Captions running on the iPhone mic:** open the picker, dismiss without choosing.
- **Captions running on the iPhone mic:** choose the iPhone mic explicitly.
- **Deliberately choose the aid**, then switch back to the iPhone mic. The aid should leave
  streaming mode once it's no longer the input.

# Larmindon: context for a coding agent

Last grounded against the checkout on **2026-10-12**, starting at `3f7d107`;
extended the same day at `4331033` from further sessions.
This is a topic reference assembled from earlier development/debugging sessions
and checked against current source and tests. It is intentionally separate from
`AGENTS.md`: read the sections relevant to the task, then open the linked code.
Source, tests, and current repository instructions take precedence if they drift
from this snapshot. Historical observations below are not fresh device measurements.

Example instruction to another agent:

> Read README.md for setup and context_dump.md's topic index. For this issue,
> read only the lifecycle and Soniox sections, inspect their source/test pointers,
> and distinguish existing behavior from proposed architecture before changing code.

## Topic index

| If you are investigating… | Start here |
| --- | --- |
| Build failures, signing, tools, or tests | [Build and validation](#build-and-validation) |
| Stop/Start hangs, stale text, cancelled startup | [Session lifecycle](#session-lifecycle) |
| Missing audio, wrong microphone, VP, hearing aids | [Capture and routing](#capture-and-routing) |
| Server errors, reconnection, missing words | [Soniox transport and delivery](#soniox-transport-and-delivery) |
| Upload bandwidth, codecs, delayed captions | [Wire encoding and timing](#wire-encoding-and-timing) |
| Which repo docs are current, author-specific tooling | [Repository map and conventions](#repository-map-and-conventions) |
| Scroll jitter, scrollback, Clear, sharing, main-screen controls | [Caption presentation](#caption-presentation) |
| Theme colors, adding a theme, day/night pairing | [Appearance and themes](#appearance-and-themes) |
| Status indicators that disagree with the microphone | [Capture status and watchdogs](#capture-status-and-watchdogs) |
| Background stops, interruptions, widget launches | [iOS lifecycle and launching](#ios-lifecycle-and-launching) |
| Diagnostic ZIPs, SQLite, privacy | [Diagnostics and SQLite](#diagnostics-and-sqlite) |
| Battery/CPU problems | [Performance investigations](#performance-investigations) |
| New providers, shared capture, custom DSP | [Provider boundary and future DSP](#provider-boundary-and-future-dsp) |
| Why a seemingly odd workaround exists | [Historical regression anchors](#historical-regression-anchors) |

## Repository map and conventions

Tracked planning documents, roughly in order of how current they are. Each records
rationale alongside its items; treat unbuilt items as proposals.

| Document | What it is |
| --- | --- |
| [`input-picker-hfp-brief.md`](input-picker-hfp-brief.md) | Open bug: the iOS input picker puts a hearing aid into streaming mode. Parked, not fixed |
| [`status-indicator-brief.html`](status-indicator-brief.html) | Capture-status and corner-controls design; mostly implemented (see [Caption presentation](#caption-presentation)) |
| [`maintenance-and-modularization-plan.html`](maintenance-and-modularization-plan.html) | Phased cleanup plan; phases 01/02 landed |
| [`background-captions-plan.md`](background-captions-plan.md) | 2026-08-15 feasibility review: background capture, Picture-in-Picture, test gates |
| [`eval-plan.md`](eval-plan.md) | Evaluation proposal. Defers to `larmindon-core/eval-plan.md`, a separate repository not in this checkout |
| [`worklist.md`](worklist.md) | 2026-08-01 UI design review. Older; check items against code before acting |

A QUIC relay brief (`larmindon-quic-relay-brief.html`) was discussed in sessions but
never committed; see [Provider boundary](#provider-boundary-and-future-dsp).

Author-specific tooling: `AGENTS.md` imports `@/Users/edmistond/.codex/RTK.md`, an
absolute path on the author's machine, and `AGENTS.md`/`CLAUDE.md` assume the `rtk`
proxy, the `blinken` guess ledger, and a commit after every agent turn. Those are the
author's workflow; another contributor's agent can ignore missing `rtk`/`blinken` and
follow its own commit conventions. The gate (`./scripts/check.sh`) is the part that
matters for everyone.

Git refs: `working` is a tag the author moves by hand to a known-good rollback commit.
Do not move or delete it, and do not create a `working` branch (the refname becomes
ambiguous). Unpacked `larmindon-diagnostics-<launch UUID>/` bundles and `*.trace`
files in the repo root are gitignored local evidence.

## Build and validation

The app is SwiftUI for iOS/iPadOS 26+ and macOS 26+. The target OS floor and
development toolchain are different things: exact development pins are in
[`scripts/checks-toolchain.json`](scripts/checks-toolchain.json), currently Xcode
27.0/27A266a, Swift 6.4, Tuist 4.200.1, SwiftLint 0.65.1, and iOS Simulator 26.5.
SwiftPM's manifest tools version is 6.2; the Xcode targets retain Swift 6 language
checking. Do not infer a tool upgrade from the runtime deployment floor.

- [`Project.swift`](Project.swift) is the source of truth for the ignored Tuist
  workspace/project. `Larmindon` is the iOS app with an embedded widget;
  `Larmindon-macOS` is the Mac app; `LarmindonKit` contains the shared code.
- [`Package.swift`](Package.swift) exposes `LarmindonKit` and `CoreTests`, excluding
  `Sources/App`. SwiftPM alone cannot prove that the app entry point or widget builds.
- `CoreTests` is the Xcode test scheme. On iOS it uses the blank
  [`LarmindonTestHost`](Tests/Host/LarmindonTestHost.swift) for window-scene/layout
  tests, without starting capture or diagnostics. Mac SwiftPM tests are unhosted.
- Run `./scripts/check.sh` for the full local gate. Focused `lint`, `format`,
  `test`, and `build` modes are documented in the README. The full gate includes
  check-runner regression tests, Debug **and Release** Mac tests, iOS hosted tests,
  and unsigned Mac/iOS app/widget builds. Reports live under `.build/checks/`.
- Formatting is check-only in routine runs. Swift warnings are errors. Tool
  installation is explicit; `setup` installs only the pinned, verified linter.
  Avoid editing Git-visible inputs during a gate run: the runner fingerprints them.
- The lint baseline has three reviewed complexity exemptions. Recorded scores
  describe the baseline, not a fresh measurement; read the unfiltered metrics
  report when changing those functions. Never regenerate the baseline to hide debt.
- The Release test step is **macOS SwiftPM only** (`swift test -c release
  -Xswiftc -enable-testing` in [`check.py`](scripts/check.py)). iOS hosted tests and
  app builds are Debug, so an iOS-only optimizer problem still needs an on-device
  `redeploy-device.sh --release` run.
- Tuist resolves source globs at generation time. A new source or test file is
  invisible to ad-hoc `xcodebuild` until `tuist generate` runs again; the gate
  regenerates on its own. A fresh git worktree has no `.build/check-tools`; run
  `./scripts/check.sh setup` there.

Signing is separate from this gate. `Project.swift` still contains the author's
team; a contributor needs their own signing configuration for device/Xcode runs.
The deployment scripts accept `DEVELOPMENT_TEAM`, otherwise requiring a single
Apple Development identity. Regenerate before deploying: those scripts build the
workspace already on disk. Device pairing/reachability is not build, signing,
installation, or live-microphone validation.

[`redeploy-device.sh`](scripts/redeploy-device.sh) defaults to Debug; `--release`
composes with a device name/UDID and `--refresh-profile`. Keep matching Release
dSYMs for profiling. [`show-ios-profile.sh`](scripts/show-ios-profile.sh) has no
device-selector interface and inspects the Debug product only.
[`deploy-macos-release.sh`](scripts/deploy-macos-release.sh) installs a signed
local Release app at `~/Larmindon_macOS.app`; it does not publish or notarize it.
It also does not quit or relaunch the app: a copy that was already running keeps the
old code until it is quit, and Spotlight/LaunchServices may list stale builds from
DerivedData or `.build`. Launch the deployed copy explicitly.

Device discovery: `redeploy-device.sh` finds devices through `xcodebuild
-showdestinations` and installs with `devicectl`. Wireless pairing uses
local-network Bonjour, so a phone that is reachable over Tailscale (ping works) can
still be invisible; client-isolating Wi-Fi does the same. If `xcrun devicectl list
devices` shows it unavailable, use USB.

Crash evidence when a launch has no end marker: list crash reports with `xcrun
devicectl device info files --device <UDID> --domain-type systemCrashLogs` (older
ones are under `Retired/`), copy them off with `devicectl device copy from`, and
symbolicate with `atos` against the matching `LarmindonKit.framework.dSYM` from
the Release device build. The diagnostics database lost the final events before
both crashes investigated in 2026-09, so do not expect it to contain the crash.

## Session lifecycle

Start with [`CaptionSession`](Sources/SpeechPipeline/CaptionSession.swift),
[`TranscriptionSource`](Sources/SpeechPipeline/TranscriptionSource.swift), and
[`CaptionSessionTeardown`](Sources/SpeechPipeline/CaptionSessionTeardown.swift).
`CaptionSession` is the main-actor coordinator for source construction, capture,
route ownership, tasks, errors, and presentation state. Its injectable
`sourceFactory` permits lifecycle tests without a microphone or paid service.

The critical Stop → Start contract came from a real five-second restart delay:

1. Stop cancels result/level consumption and detaches active ownership. The visible
   running state clears promptly, except during intentional interruption recovery.
2. Local microphone teardown is serialized through `localStopTask`. Capture must
   stop, and any provider owning its own microphone must finish, before the route
   is released. An old Stop must never deactivate the replacement session's route.
3. `BackgroundFinishingTranscriptionSource` is an opt-in for sources with no capture
   ownership. Soniox conforms; it may finish independently after local teardown.
4. Soniox's five-second watchdog bounds retired-provider draining. It is a
   shutdown deadline, **not a restart cooldown**. The background task captures
   the retired provider, not replacement session state.
5. Generation checks guard asynchronous starts, results, levels, errors, and
   watchdogs. Cancellation alone cannot prevent late completions from injected
   or platform operations that do not cooperate with cancellation.

Capture startup assumes ownership before calling a driver that may acquire a tap
and then throw. Failure/cancellation must clean up partial resources. Do not move
that ownership assignment after a successful return.

Tests: [`CaptionSessionRestartTests`](Tests/CoreTests/CaptionSessionRestartTests.swift),
[`AudioCaptureSessionTests`](Tests/CoreTests/AudioCaptureSessionTests.swift), and
[`SonioxTranscriptionSourceTests`](Tests/CoreTests/SonioxTranscriptionSourceTests.swift).
Use `AsyncGate`, `ManualDelay`, injected drivers/transports, and controlled clocks
for lifecycle ordering; fixed sleeps are a poor substitute for an explicit gate.

The current UI stops consuming results before provider shutdown. Consequently,
graceful server draining does **not** promise that every last word reaches the
visible transcript after Stop. An evaluation recorder needing final emissions
would require an explicit drain contract and its own consumer.

## Capture and routing

There are still **two live capture implementations**:

```text
AudioRouteManager -> session-owned AudioCaptureSession -> SonioxTranscriptionSource
AudioRouteManager -> LiveSpeechAnalyzerTranscriptionSource's private capture -> SpeechAnalyzer
```

[`AudioCaptureSession`](Sources/SpeechPipeline/AudioCaptureSession.swift) publishes
copied `CapturedAudioFrame`s through a newest-32 buffer and levels through a
newest-16 buffer. `CapturedAudioFrame` now includes `capturedAt: ContinuousClock.Instant`;
older session notes describing it as buffer-only are obsolete. This timestamp is
callback-delivery time, including device I/O latency, rather than an exact hardware
sample clock. It still lacks sequence/sample-position/discontinuity metadata.
`@unchecked Sendable` around mutable audio buffers requires an ownership audit
before adding multiple consumers or concurrent mutation.

[`LiveSpeechAnalyzerTranscriptionSource`](Sources/SpeechPipeline/LiveSpeechAnalyzerTranscriptionSource.swift)
reserves locale assets, prepares parallel `SpeechTranscriber`/`SpeechDetector`
modules, converts into the compatible analyzer format, and owns its engine/direct
Mac capture. It requests the current supported locale, falling back to `en_US`.
Fast/volatile results drive previews; `SpeechResultFinalization` and stable range
keys prevent duplicate committed text. Detector output updates VAD/levels; it
does not currently delete audio or directly improve the recognizer's input.

Routing facts to preserve:

- [`AudioRouteManager`](Sources/AudioRouting/AudioRouteManager.swift) and
  [`MicrophoneCapabilities`](Sources/AudioRouting/MicrophoneCapabilities.swift)
  distinguish requested preferences from the actual available/active route.
  A selectable microphone position or polar pattern depends on the current input.
- iOS capture policy uses `.playAndRecord`/`.voiceChat` with HFP and speaker options
  when VP is requested or the input is Bluetooth HFP. Otherwise it uses
  `.record`/`.measurement`. The input picker separately activates a call-style
  session even while idle; turning VP off does not eliminate that picker behavior.
- [`InputPickerControl`](Sources/AudioRouting/InputPickerControl.swift) wraps
  `AVInputPickerInteraction` with fallback menus and route preparation/release.
  Session activation can put hearing aids into streaming mode. See the historical
  [input-picker/HFP brief](input-picker-hfp-brief.md); its battery discussion is an
  investigation lead, not a universal hardware measurement.
  Mechanics: `AudioRouteManager.configureForInputSelection` activates
  `.playAndRecord`/`.voiceChat` with `.allowBluetoothHFP` *before* applying the
  preferred input. The main picker releases that session on dismiss only while
  captions are stopped; during a run it stays active until the next Start. Closing
  the Microphone panel calls `releaseMicrophoneControls`, which likewise releases
  only when idle. The brief says this should be fixed, not worked around.
- On Mac, system-default input uses `AVAudioEngine`; explicitly selected
  non-default inputs use direct Core Audio IOProc capture, including physical,
  virtual, and aggregate inputs. Selection uses stable UIDs and does not change
  the system-default input.
- [`AudioEngineInputConfigurator`](Sources/SpeechPipeline/AudioEngineInputConfigurator.swift)
  disables VP on Mac because duplex input/output formats can be incompatible.
  Inputs rejecting VP may fall back to unprocessed capture. Report active state,
  not just the saved toggle. Configuration and engine start must not have an
  intervening suspension that lets HAL invalidate the selected format.
- The capture-buffer preference is a request, not proof of callback size. Inspect
  `observedCallbackFrameLength` and diagnostics on the actual route.

Tests: `MicrophoneCapabilitiesTests`, `AudioEngineInputConfiguratorTests`,
`AudioInterruptionPolicyTests`, and `ServerAudioLevelReporterTests` under
[`Tests/CoreTests`](Tests/CoreTests). Hardware route behavior remains a device test.

## Soniox transport and delivery

Start with [`SonioxTranscriptionSource`](Sources/SpeechPipeline/SonioxTranscriptionSource.swift),
[`SonioxRealtimeClient`](Sources/SpeechPipeline/SonioxRealtimeClient.swift),
[`SonioxRealtimeModels`](Sources/SpeechPipeline/SonioxRealtimeModels.swift), and
the [`Networking`](Sources/Networking) directory. The source handles caption
adaptation/reconnection; the actor client implements the wire protocol; transport
and connection seams permit offline testing.

- Current configuration uses `stt-rt-v5`, strict English hints, diarization on,
  language identification off, and endpoint detection off. Those are current app
  choices, not a claim about the newest provider model or globally best settings.
- Credentials come from [`ProviderCredentials`](Sources/Core/ProviderCredentials.swift)
  in Keychain. Every connection sends `Authorization: Bearer …` at WebSocket
  upgrade; startup JSON excludes `api_key`. Authentication can fail in a provider
  error frame after open. Test both header propagation and terminal error mapping.
- Finish sends an **empty text frame**, then awaits `finished`. Older context
  describing an empty binary frame is wrong for the current implementation; that
  caused the server to treat it as an empty audio chunk rather than finish promptly.
- Each reconnect gets a fresh client and transport, increments connection identity,
  resets the encoder/container, and rejects late events from retired connections.
  Reusing the old transport risks a late close shutting down its replacement.
- Recoverable transport/provider failures keep microphone capture alive during
  reconnection, especially for background iOS operation. Defaults are a 20-second
  no-message stall detector, ten-second replacement connect timeout, ten-minute
  maximum outage, and exponential backoff capped at 30 seconds. Path changes can
  shorten backoff. Non-retryable auth/configuration failures end delivery.
- Audio arriving while disconnected is dropped and measured by frame duration.
  There is no replay backlog or resumable Soniox stream. A send failure is also
  counted as dropped audio. Final pending words can be flushed at connection loss;
  non-final preview words are discarded. Recovery cannot reconstruct missing audio.
- Capture-queue overflow is a **separate** loss. When the sender falls behind, the
  newest-32 frame stream discards the oldest frames; that is counted only as a
  cumulative `dropped_buffers` in `capture_aggregate` (written every 100 callbacks),
  with no time ranges, and is not part of `dropped_disconnected_ms`.
- Whether Stop drained is recorded in `run_completed.finish_outcome`
  (`finished`/`finish_timeout`/`not_finished`) and `soniox_finish_timeout` events.
  Before `20cb890`, roughly 82 of 99 stops in one week's bundle timed out.
- Soniox streams continuously, including silence, on purpose. Billing is by stream
  duration, so a VAD gate saves only bytes, and would need keepalives (the server
  closes after ~20 s without audio), an explicit finalize at each gate close, a
  pre-roll buffer, and new lag math. No keepalive or finalize exists in the code.
- `SonioxSentenceAccumulator` groups final tokens into sentences/speaker segments
  and combines the unfinished sentence with the mutable preview. A token marked
  final is not necessarily already a visible finalized UI chunk.
- [`BoundedCaptionResults`](Sources/SpeechPipeline/BoundedCaptionResults.swift)
  keeps a 64-event newest buffer. Evicting a partial/status update is permitted;
  evicting finalized speech produces a terminal failure rather than silently
  presenting a complete transcript. User-requested cancellation is not a failure.

Tests: `SonioxRealtimeClientTests`, `SonioxReconnectTests`,
`URLSessionWebSocketTransportTests`, `BoundedCaptionResultsTests`, and
`TranscriptionFailureReporterTests` in [`Tests/CoreTests`](Tests/CoreTests).
Mocked tests prove the local contract, not service acceptance with a real key.

## Wire encoding and timing

[`SonioxWireEncoder`](Sources/SpeechPipeline/SonioxWireEncoder.swift),
[`OggOpusMuxer`](Sources/SpeechPipeline/OggOpusMuxer.swift), and the preference
enums in [`UserPreferences`](Sources/Core/UserPreferences.swift) define:

| Option | Current behavior |
| --- | --- |
| PCM, default | Resample to 16 kHz, 16-bit mono little-endian; roughly 32 KB/s |
| Opus | Apple encoder, Ogg container, 16 kHz input, 20 ms packets; VBR targets 24/32/50/80 kbps, default 32 |
| FLAC | Apple encoder, native FLAC header/STREAMINFO; 16 or 24 kHz mono, default 16; 20 ms blocks |

If a compressed encoder cannot initialize, the factory falls back to PCM. The UI
does not show this; the only signal is `encoding` ≠ `requested_encoding` on
`run_started`, `soniox_connected`, and `run_completed`. Container headers must be
resent on every connection. Compressed formats use `audio_format: auto`; unlike
raw PCM, sample rate/channel count are carried in the container rather than JSON.
Opus writes one packet per Ogg page so nothing waits on batching; the page header
makes 24 kbps about 4.3 KB/s on the wire. The bitrate steps skip 48 and 64 kbps
because Apple's encoder does not offer them, and VBR is requested but not
guaranteed: compare `bit_rate`/`bit_rate_strategy` with `bit_rate_requested`.

The encoder interface reports emitted audio duration. Dividing compressed byte
counts by PCM bytes/second gives incorrect provider lag. Partial packets/blocks
can remain buffered; current Stop does not flush all encoder-held audio. Include
this tail-loss risk when evaluating missing final words. That buffering is measured
as `encoder_hold_*` (`8cecf37`): audio fed in minus the encoder's emitted duration,
sampled after every captured buffer. With 10 ms buffers, expect means of about 0 ms
for PCM, ~11.5 ms for Opus (20 ms packets plus a 104-frame lookahead, logged as
`pre_skip_frames`), and ~25 ms for FLAC (Apple releases a block only after the
next fills). Histogram buckets are 5 ms apart below 50 ms so these separate.

[`SonioxRunMetrics`](Sources/SpeechPipeline/SonioxRunMetrics.swift) and the source
record one `run_id` per caption session and a `connection` number within it.
`run_started`, `audio_send_window`, `soniox_update`, `caption_stale_started` /
`caption_stale_ended`, and `run_completed` expose conversion/send costs, upload
volume, encoder hold, drops, provider progress, and capture-to-token ages. Windows
are normally ten seconds.

Important interpretation rules:

- `processing_lag_ms` measures positions on the provider audio timeline; it is
  not end-to-end wall-clock caption age. Capture ages map provider timestamps back
  through a bounded per-connection timeline.
- Capture age starts at callback delivery, not at acoustic arrival. It excludes
  earlier hardware latency and does not measure when SwiftUI paints the words.
- Missing mappings are never reported as zero: `kbps` uses the string
  `unavailable`, and an empty histogram emits only `<prefix>_count: "0"` with its
  quantile fields omitted. Treat a missing field as unmeasured. Histogram
  quantiles are bucket bounds, not exact per-sample quantiles.
- `queue_age_*` is tap delivery to the sender loop picking the buffer up, where a
  slow uplink shows first. `send_max_ms` is URLSession accepting the message, not
  server receipt. `kbps` is over audio time, not wall time. `source_format`
  (capture rate/channels) is on `audio_send_window`/`run_completed`; `run_started`
  carries the encoder's output `sample_rate`. Stop-drain ages are excluded from live
  distributions; disconnected periods are separately accounted.
- A three-second processed-age stale threshold in metrics differs from the
  user-facing capture-status stall threshold and network no-message timeout.
- FLAC preserves the PCM it encodes; it cannot restore information lost earlier
  to routing, resampling, or microphone processing. 24 kHz versus 16 kHz changes
  the input bandwidth as well as encoding, so it does not isolate codec effects.
  An informal impression that 16 kHz FLAC beat PCM therefore points at delivery
  (FLAC's smaller upload falls behind less), provider decoding, or run variation;
  check `dropped_buffers`, `queue_age_max_ms`, and stale time per run first.
- Earlier real-use reports of degraded atypical-speech recognition with low-rate
  Opus motivated selectable bitrates and retaining PCM as default. They are not a
  controlled current accuracy benchmark. Compression ratios vary with noise.

For a codec comparison, hold samples, voice processing, endpointing, source rate,
and release cadence fixed; verify lossless decode against the PCM input. Measure
recognition quality, missing captions, buffering, and age together. A smaller
upload or attractive latency number alone cannot establish an improvement.

Tests: [`SonioxOpusEncoderTests`](Tests/CoreTests/SonioxOpusEncoderTests.swift),
[`SonioxFLACEncoderTests`](Tests/CoreTests/SonioxFLACEncoderTests.swift),
[`OggOpusMuxerTests`](Tests/CoreTests/OggOpusMuxerTests.swift), and
[`SonioxRunMetricsTests`](Tests/CoreTests/SonioxRunMetricsTests.swift).

## Caption presentation

[`CaptionStore`](Sources/Core/CaptionStore.swift) separates immutable finalized
chunks from a replaceable volatile tail, including speaker IDs. Preserve stable
chunk IDs and final text when changing rendering. Soniox reports speakers;
on-device results currently do not. Text exports insert `[Speaker N]` markers
for speaker runs; unlabeled results remain plain text.

The main-screen controls now live in an iOS bottom capture band and a Mac toolbar.
[`CaptureControls`](Sources/UI/CaptureControls.swift) presents low-update status;
full meters remain in the Microphone panel. Older designs/screenshots showing the
main level bar or a large labeled mode picker are historical.

Main-screen invariants. These are user requirements for reading captions live, not
styling preferences:

- The input chip always names the current input (`showsCurrentInputName: true`);
  other apps can take over a Bluetooth input and show theirs only briefly. The
  on-device/Soniox switch stays one tap away; Settings and the Microphone panel stay
  reachable.
- Clear removes a misheard or profane phrase before others read it. It stays on
  screen (iOS bottom-right corner; Mac toolbar beside Start/Stop, never in a menu),
  one tap, no confirmation; it dims when there is nothing to clear but never hides.
  The Undo toast never repeats the cleared text and has no countdown bar or ring.
- No continuous animation (battery): the status ring and label change only when
  `captureStatus` changes, with a 0.2 s ease, and `CaptionSession` writes
  `captureStatus` only when its value differs. Avoid `repeatForever`, symbol
  effects, or meter-driven visuals on the main screen.
- Status never relies on color alone: Stopped has no ring, Starting/No audio a
  dashed ring, Listening a thin ring, Captioning a thick accent ring, No captions a
  thick orange ring with a `!` badge. A text label always accompanies it, and
  Start/Stop exposes it as its accessibility value. The mode switch is icon-only
  (`iphone.gen3`/`macbook.gen2` versus `cloud`), so the label names the provider.
- Corner buttons are full circles whose centers sit inside the screen, clipped by
  both edges, with the glyph at the circle's true center. A quarter disc on the
  corner has no visual center and was reverted (`6af5d54` → `ce3a4dc`). The band
  ignores bottom/horizontal safe areas to reach the corners, then pads content
  above the home indicator; `minimumBandHeight` keeps controls off the newest
  caption. Widths ≥ 600 pt use the row arrangement.
- Start/Stop keeps the pre-redesign colors in every theme (accent to start, red
  while running); Clear is a neutral gray `trash`. Toolbar space freed by the icon
  mode switch is reserved for a future `sparkles.2` control (speaker ID/naming);
  nothing occupies it yet.

[`CaptionDisplayView`](Sources/UI/CaptionDisplayView.swift) and
[`CaptionScrollState`](Sources/UI/CaptionScrollState.swift) encode hard-won scroll
behavior:

- Short transcripts stay at the top; bottom following begins when content overflows.
- Use measured content/container heights and insets, not offset alone.
- Reattachment measures proximity to the **latest text**, excluding decorative
  trailing padding, with tolerance based on the rendered font's line advance.
- Deliberate upward drags/flicks detach. Downward scrolling can reattach; elastic
  rebound and text reflow must not immediately detach it again.
- Pending programmatic scroll requests are consolidated/superseded; avoid fighting
  user tracking, interaction, or deceleration.
- Errors occupy a normal conditional row in `LarmindonRootView`, preserving the
  scroll view's identity. An empty error safe-area inset previously caused jitter.

Clear is immediate and does not stop capture. `CaptionSession` retains the last
cleared finalized chunks for five seconds; Undo prepends them before any newly
finalized text with original IDs. It does not restore the old volatile preview.

[`TranscriptExport`](Sources/Core/TranscriptExport.swift) snapshots value arrays
for `Transferable`. Avoid making the share-sheet representation await the main
actor: the iOS share UI can block that actor while requesting the representation.
The `.txt` renders lazily in `FileRepresentation` through `nonisolated
CaptionStore.transcript(for:)`. Keep the explicit `SharePreview` icon: without it
the sheet thumbnails the file, loading it before appearing. Both together fixed a
multi-second iOS freeze sharing even a two-line transcript (`d9b7f17`). Exports are
named `Larmindon Transcript yyyy-MM-dd HH.mm.txt` in a per-export UUID temp folder;
the Mac "Copy Full Transcript to Clipboard" command uses the same renderer.

The Microphone panel's Levels and Transcript sections are separate leaf views so
per-buffer writes do not re-render the polar-pattern `Canvas`.

Tests: `CaptionScrollStateTests`, `CaptionDisplayLayoutTests`,
`CaptureBandLayoutTests`, `CaptionSessionClearUndoTests`, `CaptionStoreTests`, and
`TranscriptExportTests` under [`Tests/CoreTests`](Tests/CoreTests). Hosted layout
tests are useful evidence; gesture feel, font/device variations, and physical
screen rendering still need manual validation.

## Appearance and themes

All theme data is in [`UserPreferences.swift`](Sources/Core/UserPreferences.swift).
`AppTheme` is the identity and storage key; its `palette` returns one `ThemePalette`
literal per theme (title, color scheme, tint, background, control background, text,
six speaker accents) as hex via `Color(hex:)`. Adding a theme is one enum case plus
one literal and a redeploy. There is deliberately no asset catalog (`LarmindonKit`
has no resource bundle, and these are named palettes rather than light/dark
variants) and no JSON (deferred until user-importable themes are actually planned).

- A `nil` surface means "defer to the platform". Light and Dark keep the system
  accent, window background, label color, and `.thinMaterial` capture band; do not
  fill those nils with concrete colors.
- Case raw values are what `@AppStorage` persists, read back as
  `AppTheme(rawValue:) ?? default`. Renaming a case silently resets a user's saved
  theme; titles can change freely.
- `ThemeSelection` is `.fixed(theme)`, which forces that theme's scheme, or
  `.followSystem(light:dark:)`. The Light/Dark pickers list `themes(for:)` filtered
  by palette color scheme, so a new theme lands in the right picker automatically.
  A legacy `appearancePreference` key is migrated once.
- Speaker colors cycle through `speakerAccents` (numeric ID N uses index
  (N−1) % count; other IDs a stable hash). Leave red out of accents: it means
  error/Stop. Volatile caption text uses 0.9 opacity rather than `.secondary`
  because dimmed newest text was unreadable in sunlight.
- Palettes follow the upstream specs cited in comments (Rosé Pine, Dracula).
  Alucard's control band deliberately uses the warm line-highlight `#E2DECA` rather
  than the cool Selection gray, which looked wrong on its cream background.
- Theme choice is also a power variable on OLED: light palettes cost more.

Tests: `UserPreferencesTests` iterates `allCases` for accent count, unique titles,
platform deferral in Light/Dark, and custom backgrounds elsewhere; its exact
`themes(for:)` ordering assertion is the one a new theme forces you to edit. No test
checks contrast; legibility is judged by eye on a device.

## Capture status and watchdogs

[`CaptureStatusTracker`](Sources/SpeechPipeline/CaptureStatus.swift) is a pure
state machine fed by explicit instants. It distinguishes audio arriving from
recognizer activity. Thresholds currently include two seconds without audible
audio, one second of audible input before Listening, a ten-second Captioning hold,
a ten-second server-result stall, and a two-second minimum dwell.

Any ordinary Soniox result can prove the connection is alive, including an empty
periodic update. Only word-bearing Apple results count as recognizer activity;
Apple silence must not imply a dead recognizer. Reconnection/interruption is
stalled, and a restored server connection needs fresh results to prove recovery.

- The No-audio and stall clocks start at `captureDidStart`, after the source has
  finished starting, so a slow model load or Soniox connect reads Starting.
- There is no true digital-silence signal here: a buffer is silent when the
  smoothed `rawInputLevel` is below `silenceLevel` = 0.001 (about −78 dBFS RMS). A
  real but very quiet input could read No audio. `status-indicator-brief.html`
  says `isDigitalSilence` is used; the code does not do that.
- No audio outranks Captioning, so Soniox's empty updates cannot make a dead input
  look alive. The two-second dwell is skipped when leaving Starting/Stopped, going
  to Stopped, or stalling for reconnect/interruption. On-device never enters No
  captions from silence alone.
- Each change logs `state/capture_status_changed` (from, to, requested_mode). A
  one-second ticker evaluates thresholds that elapse without any input event.

This differs from the three-second **no callback** startup watchdog in
`CaptionSession`. Every received level snapshot, even an unchanged zero snapshot,
marks audio delivery before display deduplication/throttling. That corrected a
false no-audio warning in session-owned capture. Clearing that warning must not
clear an unrelated provider failure. Status describes activity, not whether the
recognized words are correct.

Tests: [`CaptureStatusTrackerTests`](Tests/CoreTests/CaptureStatusTrackerTests.swift)
and watchdog cases in `CaptionSessionRestartTests`.

## iOS lifecycle and launching

[`Project.swift`](Project.swift) declares audio background mode so an active
caption session can survive switching apps/locking. This is not permission to
start arbitrary new capture in the background. Soniox reconnect keeps the existing
capture alive; interruption recovery is a separate audio-session policy.

[`AudioInterruptionPolicy`](Sources/AudioRouting/AudioInterruptionPolicy.swift)
and `CaptionSession` handle interruption-ended resume hints, media-services reset,
bounded recovery/backoff, and Stop cancelling recovery. Explicit Stop must disarm
future resume. Recovery preserves the running UI state while showing a stall.
[`CaptionFailureNotifier`](Sources/Core/CaptionFailureNotifier.swift) can notify
when captions stop unexpectedly, where an on-screen error may go unseen. Permission
preparation happens from a foreground live session. Notifications are not proof
of a particular OS kill reason.

The circular [`widget`](Widgets/LarmindonWidgets.swift) launches the app using
[`CaptionLaunchLink`](Sources/Core/CaptionLaunchLink.swift): exactly
`larmindon://captions/start`, with no credentials, query, fragment, port, or userinfo.
`LarmindonRootView` waits for scene activation/readiness, dismisses sheets, and
uses `startIfIdle` with saved settings. Existing starting/running/stopping or
interrupted work must remain intact; duplicate links are consumed, not queued
as a restart after Stop. No App Group or transcription in the widget is involved.

Tests: `CaptionLaunchTests`, `CaptionSessionInterruptionTests`, and
`AudioInterruptionPolicyTests`. Validate Lock Screen placement/unlocking, actual
capture, and provider startup on a physical device.

## Diagnostics and SQLite

[`Diagnostics`](Sources/Debug/Diagnostics.swift) records events automatically;
[`DiagnosticStore`](Sources/Debug/DiagnosticStore.swift) serializes durable SQLite
storage through an actor. [`AppEnvironmentDiagnosticMonitor`](Sources/Debug/AppEnvironmentDiagnosticMonitor.swift)
adds lifecycle/path observations and samples resources every 30 seconds while
captioning. [`ProcessEnergyReading`](Sources/Debug/ProcessEnergyReading.swift)
reads process CPU/wakeup/available energy counters; these are not whole-phone
power measurements.

The database lives at `Application Support/Larmindon/diagnostics.sqlite` in the
app's storage. Storage uses WAL/NORMAL, batches at 50 events or two seconds,
flushes on backgrounding, and prunes events older than seven days at launch.
A 2,000-event ring remains available if persistence fails. Recent unflushed
events can be lost; logging is not a complete crash recorder.

Captured evidence includes lifecycle/start/stop, requested/active routes and VP,
formats/callbacks/drops/levels, provider errors/reconnects/pings, token counts and
progress, network path, and thermal/battery/charging/low-power/resource context.
On iOS resource context also includes app state, available memory, and brightness.

Resource and energy fields (`resources/sample` every 30 s while captioning, plus
lifecycle events):

- Cumulative `cpu_user_ms`, `cpu_system_ms`, `wakeups` (interrupt + platform-idle)
  and, on arm64, `task_energy`. Difference consecutive samples. `task_energy` is a
  raw kernel counter whose unit has not been checked on a device: compare it
  relatively. Bluetooth/radio energy is likely not billed to it.
- `battery_percent` and `battery_state` (`unplugged`/`charging`/`full`/
  `plugged_in`/`unknown`); iOS also logs `battery_state_changed`. iOS reports the
  level in 5% steps. A falling percent while `charging` means draw exceeded the
  charger or heat throttled charging; check `thermal_state`. `plugged_in` is macOS
  holding charge below 100%. A Mac without a battery emits no battery fields.
- Samples run only between session start and stop. A gap between runs is by
  design; it does not show the app was suspended.

Version/identity distinctions matter:

- `DiagnosticEvent.sessionID` is **one app launch**, not one caption run.
  Soniox's `fields.run_id` is one caption session, spanning reconnects.
- Event-envelope schema and export format are currently **3**. SQLite
  `PRAGMA user_version` is **2**; these version numbers describe different formats.
- SQLite `events` has `id`, `ts`, `session_id`, `category`, `name`, JSON `fields`,
  `seq`, `mono_us`, and `schema_version`; `sessions` stores launch/end metadata.
- Use event `sequence` / SQLite `seq` for within-launch recording order and
  `monotonicMicroseconds` / `mono_us` for within-launch elapsed time. Wall-clock
  `timestamp` / `ts` is for correlating human observations and can step.
- Old rows may have NULL sequence/monotonic columns; fall back to `id` for order,
  not fabricated timings. Persistence failures surface counts in events/manifest.
- An unset launch end marker means no graceful exit was recorded. It cannot alone
  distinguish a crash, force quit, or jetsam. Previously unended launches are
  reported once, rather than repeatedly replayed into every later launch.

Example read-only queries against an **exported snapshot**:

```sql
SELECT session_id, started_at, ended_at, end_reason FROM sessions ORDER BY started_at;
SELECT id, seq, mono_us, category, name, fields
FROM events WHERE session_id = 'LAUNCH-UUID' ORDER BY id;
SELECT id, name, fields FROM events
WHERE json_extract(fields, '$.run_id') = 'SONIOX-RUN-UUID' ORDER BY id;
```

Microphone → Diagnostics Export produces a ZIP with `manifest.json`, recent
current-launch `events.jsonl`, and a retained SQLite snapshot if available.
Snapshot export uses `VACUUM INTO`; copying just the live SQLite file can omit WAL
contents. `includesDatabase` and failure counters tell you whether evidence is
missing. SQLite row iteration must throw on step errors even after earlier rows
succeeded, rather than returning a deceptively successful partial query.

Normal events/exports omit raw audio and credentials; transcript events use counts
and timing. Opting into transcript export adds `transcript.txt` separately.
There is no universal redaction layer for arbitrary newly added `fields` or error
strings: preserve privacy at every logging call site, including public OSLog
messages. A diagnostic ZIP still contains device/route/environment metadata.

Tests: `DiagnosticsTests`, `DiagnosticStoreTests`, `SQLiteStatementRowsTests`,
`BatteryReadingTests`, and `ProcessEnergyReadingTests` under
[`Tests/CoreTests`](Tests/CoreTests).

## Performance investigations

A previous physical-iPhone Instruments review found a quiet foreground
Soniox-selected **transcription-off** baseline, while active runs contained
substantial SwiftUI/AttributeGraph work and sample-scanning under
[`AudioLevelMeter.measure`](Sources/Core/AudioLevels.swift). Those runs were
identified as Debug binaries; their CPU percentages are not a current Release
baseline. Current main-screen status controls and wire encodings also postdate
that measurement.

The meter measures every sample before publication throttling; a slow UI update
rate does not itself reduce metering computation. (Level-only UI writes are capped
at 20/s against ~60 snapshots/s at the default 768 frames; speech/VAD/callback-size
changes publish immediately.) An unoptimized build shows up as innermost samples in
generic stdlib helpers (`Range.formIndex(after:)`, `abs<A>`, `IndexingIterator.next()`)
under `AudioLevelMeter.measure`. Graph stacks suggest where to
look but do not prove redundant rendering, bad scrolling, or a battery bug.
Whole-device power spikes with no matching app execution remained unexplained;
do not assign them to the app solely because it was foregrounded. An illuminated
display, routing, radio, and charging state are separate variables.

For a new investigation, inspect the `.trace` TOC first with `xctrace`, choose
actual available schemas, and export **each run separately**, especially raw
signposts. Record exact binary/build identity and matching dSYMs. Compare sustained
Release runs with identical input, route/VP, brightness/theme, and network; exclude
30–60 seconds of startup. Test transcription-off idle separately from a connected
server receiving microphone silence, and check that capture/network activity ends
after Stop. Separate measured behavior, source explanation, and hypotheses.
Record theme and `screen_brightness` with any power comparison: light palettes
(Light, Rosé Pine Dawn, Alucard) cost more on OLED than near-black dark themes.

## Provider boundary and future DSP

The [maintenance plan](maintenance-and-modularization-plan.html) is a historical
phased design document: phases 01/02 landed; provider generalization, unified
capture, processing workers, and enforced module boundaries remain proposals.
Some introductory status text is stale; inspect code rather than treating every
diagram or proposed type name as implemented.

`TranscriptionSource` is useful but incomplete for adding a second server:
`CaptionSession.performStart` still downcasts to `SonioxTranscriptionSource` to
attach shared capture. Soniox's no-argument `start()` explicitly fails. There is
no Azure implementation or provider-neutral audio-input adapter. Prove a second
fake provider through orchestration before committing to a real backend.

Custom DSP, an audio recorder, QUIC/BEAM relay, a rich evaluation event schema,
and a single live-capture pipeline are **not implemented here**. Earlier sessions
explored them as experiments, not product requirements. Current UI events discard
many provider audio-range/confidence/revision details; diagnostics are not an
evaluation recording format.

The relay idea, for context: iOS → Network.framework QUIC (20 ms PCM datagrams
plus reliable control/result streams) → an Elixir relay on Fly.io with a bounded
reorder/playout buffer that zero-fills gaps → the Soniox WebSocket. Its purpose was
to separate an acoustic hypothesis (lossy codecs remove speech cues) from a
transport hypothesis (cellular stalls plus queues turn PCM into lag). "Phase 0" was
to instrument the direct path and compare PCM, Opus, and FLAC first; that phase is
what landed (FLAC, per-run metrics, encoder hold). Relay-side events (QUIC, gap
ledger, clock probes) have no producer, and the brief is not in the repository.

Also discussed but not built: automatic codec switching by network type (would
need a mid-session reconnect), a debug mode sending each buffer as both PCM and
FLAC (doubles provider cost), log levels or a per-frame benchmark mode
(`logging_mode` is always `operational`), render-time caption ages, and a WER scorer.

The proposed direction was one capture owner, explicit frame timing/ownership and
loss accounting, bounded recorder fan-out, a bypassable processing worker, then
provider adapters. Multiple readers of an `AsyncStream` are not broadcast fan-out.
Do not put expensive denoising on the real-time callback or synchronous main-actor
conversion path. Prove bypass parity before testing enhancement. Keep Apple VP and
local recognition available as comparison/fallback choices.

For speech-in-noise experiments, label audio by its actual capture stage and
active VP/route state. App-received audio may already be processed; calling it
"raw" loses provenance. Do not make VAD destructively remove speech as the first
experiment. Compare recognition, diarization, revision churn, missing words,
latency, and device CPU/thermal/battery behavior with repeated controlled inputs.
Earlier VP-on/VP-off preferences differed by backend; no universal winner was
established. Consult [`eval-plan.md`](eval-plan.md) as a proposal to review, not a
completed harness or measured result.

## Historical regression anchors

These commits connect earlier session findings to inspectable repository history.
Use them to understand a change's reason; current tests/code define present behavior.

| Commit | Why it matters |
| --- | --- |
| `5a582f3` | Rapid restart while retired Soniox teardown finishes; local ownership remains serialized |
| `545e169` | Session-owned capture must satisfy the no-callback watchdog even for unchanged levels |
| `6aa48ae`, `fe9eeb1` | Short-transcript jitter, then font-aware/rebound-safe scroll reattachment |
| `089d99a`, `7e62b9b` | Pinned local gates, check-only formatting, warnings as errors, iOS layout host |
| `ba3c11f`, `f1fbfcb`, `4d7f3bc`, `b37f20a` | Partial startup cleanup, terminal recognition errors, checked SQLite reads, bounded final delivery |
| `973d265` | Device deployment supports optimized Release builds and profiling symbols |
| `20cb890` | Soniox finish requires an empty text frame; older binary-frame notes are obsolete |
| `050e441`, `3e866ae`, `6a8d78d` | Reconnect without stopping capture; stale connection isolation and duration-based audio-loss accounting |
| `2436641`, `20554d3` | Release-only Soniox start crash workaround and optimized tests in the gate |
| `42ec9f3` | WebSocket ping continuation can be resumed only once |
| `147d4a0`, `6bcda6b` | Five-second Clear Undo and low-update capture status |
| `6af5d54`, `ce3a4dc` | Corner glyph alignment attempt, then full circles tucked into the corners |
| `268d72e`, `d9b7f17` | Debug panel merged into Microphone panel; share export off the main actor |
| `b7422dd`, `9d6e1e5` | One `ThemePalette` per theme; Alucard warm control-band fallback |
| `948634f`, `f76de2d`, `8cecf37` | Event ordering/monotonic schema, per-run caption age/uplink evidence, encoder-hold measurement |
| `706369b` | Lossless FLAC upload option alongside PCM and Opus |
| `1d75e74` | Bearer header on initial/reconnect WebSockets; no credential in startup JSON |

In particular, preserve `@inline(never)` on the internal Soniox source initializer
until an optimized reproducer demonstrates that the compiler issue is gone. The
historical failure occurred on the first retain after inlining into source
construction; Debug and sanitizer success did not rule it out. Its signature was
`swift_unknownObjectRetain` → `objc_msgSend` on a null class immediately after
`makeSource` returned. It appeared only once the reconnect and Opus merges were
both on main (each branch alone was fine), so unrelated edits could reintroduce it.
[`SonioxLaunchTests`](Tests/CoreTests/SonioxLaunchTests.swift) exercises the real
source-factory route, and the gate runs it in Release. The same suite checks the
single-resumption guard used for WebSocket ping completion/cancellation races.

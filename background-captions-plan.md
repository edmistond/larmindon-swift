# Background Captions & Deterministic Test Gates

Plan from a feasibility review on 2026-08-15, covering two iOS features (background
capture, Picture-in-Picture) and the automated test gating around them. Rationale is
recorded alongside each item, same as `worklist.md` — most of these decisions come from
what the current code already does, which isn't obvious from the file names.

## Framing

- **The app is not App Store distributed.** Prior art, review scrutiny, and
  justification for the `audio` background mode are non-issues.
- **Two features, very different cost.** Background capture is mostly one plist key
  plus interruption handling. PiP is a new subsystem. They are independent, except
  that PiP depends on background capture existing first.
- **Device verification is unavoidable for both.** SpeechAnalyzer doesn't run in the
  iOS Simulator, and sample-buffer PiP doesn't behave there either. The simulator
  proves compilation; `scripts/redeploy-device.sh` is how the real check happens.

---

## Feature 1 — Background captions

### Why it currently stops

`Project.swift:19` (`iOSInfoPlist`) declares no `UIBackgroundModes` at all. Nothing in
the app tears captions down on backgrounding — there is no `scenePhase` handling
anywhere in `Sources/`. iOS is simply suspending the process a second or two after it
leaves the foreground.

The audio session category is already compatible. `IOSAudioSessionCapturePolicy`
(`AudioRouteManager.swift:299`) selects `.record`/`.measurement` for most inputs and
`.playAndRecord`/`.voiceChat` for Bluetooth HFP or voice processing; both continue
recording in the background once the mode is declared.

### Step 1 — Declare the background mode

Add to `iOSInfoPlist` in `Project.swift:19`:

```swift
"UIBackgroundModes": .array([.string("audio")]),
```

Then `tuist generate`. iOS target only — the macOS target extends `sharedPrivacyPlist`
separately and is untouched.

This alone produces the behavior, because the session is already active and recording
at the moment of backgrounding, which is the condition iOS requires.

### Step 2 — Make the interruption decision a pure type

New `IOSAudioInterruptionPolicy`, placed beside `IOSAudioSessionCapturePolicy` in
`AudioRouteManager.swift:299`.

*Why:* the policy struct next to it is already unit-tested in
`MicrophoneCapabilitiesTests.swift`. Following the same shape means the recovery logic
gets a deterministic CI gate without a device, an audio session, or a running app.

Shape:

- **Inputs:** interruption type (`.began` / `.ended`), `AVAudioSession.InterruptionOptions`
  (notably `.shouldResume`), whether a session was running when it began, and the
  attempt count so far.
- **Output:** an enum — `.hold`, `.restart`, `.retry(after:)`, `.giveUp(reason:)`.

The policy decides; it does not touch `AVAudioSession`. That separation is the whole
point — it is what makes the decision testable.

### Step 3 — Observe the notifications where the session already lives

`AudioRouteManager` owns `AVAudioSession` and already observes
`routeChangeNotification` (`AudioRouteManager.swift:239`). Add beside it:

- `AVAudioSession.interruptionNotification`
- `AVAudioSession.mediaServicesWereResetNotification`

Expose `onAudioInterruption: ((AudioInterruptionEvent) -> Void)?` — the same callback
shape as the existing `onRouteChange` and the macOS-only `onInputAvailabilityChange`.

*Why:* there is currently **no interruption observer anywhere in `Sources/`.** In the
foreground that's tolerable — a phone call kills the engine, captions visibly stop, you
press Start. Backgrounded, it fails silently and you don't find out until you switch
back, possibly having lost the part of the conversation you were relying on. This is
the piece that separates "works" from "trustworthy."

### Step 4 — Handle it in `CaptionSession`

Add `handleAudioInterruption(_:)` mirroring `handleAudioInputAvailabilityChange`
(`CaptionSession.swift:607`).

- **Recovery is a full `stopActive` + `start(kind:mode:)`,** reusing the existing
  generation-guarded transition machinery (`transitionGeneration`,
  `CaptionSession.swift:114-125`). Do *not* invent a partial-restart path that reaches
  into the engine — the existing path is already correct about cancellation and
  re-entrancy, and that correctness was expensive to get.
- **Bounded retry with backoff.** When a call ends, reactivating the session can fail
  transiently while the other app still holds the mic. One attempt is not enough.
- **Keep `store.isRunning` true across a recovery,** so returning to the app doesn't
  show a spurious Stopped state for a recovery that succeeded.
- The existing silent-capture watchdog (`CaptionSession.swift:515`) is a useful
  backstop but not a substitute: it fires on "no audio since start," which is a
  different condition from "audio stopped mid-session."

### Step 5 — Diagnostics

New `audio_interruption` events: `began`, `ended`, `restart_ok`, `restart_failed`,
with the option flags and attempt count as fields.

*Why:* every previous audio bug in this repo was solved from a diagnostics bundle. A
failure that happens while the app is backgrounded is **only** diagnosable that way —
there is no other observer present.

### Step 6 — Surface a failure you can't see (decision needed)

If recovery gives up while you're in another app, nothing tells you.

- **Minimum:** set `lastError` + `speechAnalyzerState` so the state is visible on
  return to the app.
- **Better:** a local notification on give-up. Silently-dead captions are the exact
  failure mode that makes the whole feature untrustworthy — if you can't tell the
  difference between "nobody is talking" and "it died four minutes ago," you end up
  checking the app constantly, which defeats the point.

*Status: undecided.*

### Step 7 — Device verification checklist

The simulator proves it compiles, nothing more. On device, walk:

- 5+ minutes in another app, transcript intact on return
- Incoming phone call, and an outgoing one
- Siri invocation
- AirPods / Bluetooth connect and disconnect **while backgrounded**
- Screen lock
- Another audio app grabbing the mic

### Explicitly do not

- **Don't add `scenePhase` teardown.** There is none today, which is why this change is
  small. Adding lifecycle handling to "be tidy" would reintroduce exactly the bug being
  fixed.

### Known risks, not blockers

- **Jetsam.** A long backgrounded session holding full scrollback is a plausible
  memory kill, and the transcript would be lost. Full scrollback is load-bearing
  (`worklist.md` framing constraints), so the answer is never to cap it — but
  transcript persistence becomes more pressing once sessions can run for an hour
  behind other apps. Separate work item.
- **Battery and thermals.** On-device SpeechAnalyzer running unattended for long
  stretches is real CPU. Worth measuring, not worth pre-optimizing.

**Complexity: low.** The plist key is minutes; interruption handling is the bulk and is
self-contained.

---

## Feature 2 — Picture-in-Picture (deferred)

Feasible, meaningfully more work. Recommend shipping background capture first and
living with it before committing to this — backgrounding alone may cover most of "I
need to check something in another app."

### The only available approach

There is no SwiftUI-native PiP on iOS 26. `AVPictureInPictureController` requires
either an `AVPlayerLayer` or an `AVSampleBufferDisplayLayer`. Captioning apps use the
latter: you own the layer, render captions into `CVPixelBuffer`s yourself, wrap them as
`CMSampleBuffer`s, and enqueue. **PiP is showing a video stream you draw frame by frame.**

Pieces:

- A renderer turning the last N `CaptionLine`s into a pixel buffer (Core Text or
  `UIGraphicsImageRenderer` into a `CVPixelBufferPool`), driven off `CaptionStore`
  changes and coalesced to ~10fps. Volatile text updates per token; a redraw per token
  is wasteful.
- An `AVPictureInPictureSampleBufferPlaybackDelegate` reporting a live stream (infinite
  time range, so no scrubber appears), with monotonically increasing presentation
  timestamps.
- `canStartPictureInPictureAutomaticallyFromInline = true` for auto-start on
  backgrounding.
- Restore handling, so tapping the PiP window returns to the app.

No special entitlement is required. (The multitasking-camera-access entitlement is for
camera during PiP, which doesn't apply.)

### Risks to settle before committing

1. **Possible collision with the capture policy.** PiP generally requires an audio
   session category supporting background audio; the commonly working configurations
   are `.playback` or `.playAndRecord`. The default capture path uses `.record`. If
   `isPictureInPicturePossible` returns false, the fix is switching to `.playAndRecord`
   while keeping `.measurement` mode — a legal combination — but that touches
   `IOSAudioSessionCapturePolicy`, which was tuned against real capture failures. Needs
   device verification, not reasoning.
2. **Legibility.** The PiP window is small; realistically 2–3 lines at a readable size.
   That makes it a glance surface by construction. Acceptable as an *addition* — the
   main window keeps full scrollback and nothing is capped — but worth deciding whether
   a 2-line overlay is actually useful, or whether the honest answer is "make
   backgrounding work and switch back to read."
3. **Device-only verification,** same bucket as SpeechAnalyzer.

**Complexity: moderate.** ~300–400 lines across renderer, controller wrapper, and
lifecycle. No exotic APIs; the polish time goes into text rendering looking good at
that size.

### Rejected alternative

**Live Activities / Dynamic Island.** Much cheaper, but ActivityKit update budgets make
it unsuitable for text changing several times a second.

---

## Test gating

### What already exists

- `FakeTranscriptionSource` (`Sources/SpeechPipeline/FakeTranscriptionSource.swift`),
  already routed by `CaptionSession.makeSource` (`CaptionSession.swift:411`) via
  `TranscriptionSourceKind.fake`.
- `FakeWebSocketTransport` plus recorded Soniox fixtures
  (`Tests/CoreTests/Fixtures/soniox_token_evolution.jsonl`).
- Pure-function tests over layout and policy decisions: `CaptionRootLayoutTests`,
  `AudioLevelMeterTests`, `SpeechResultFinalizationTests`, and
  `IOSAudioSessionCapturePolicy` coverage inside `MicrophoneCapabilitiesTests`.

The pattern this codebase already favors — **extract the decision into a pure type,
test the type** — is the right one to keep extending.

### Gap 1 — The fake source isn't reachable on iOS

`.fake` is startable only from `DebugPanelView:80`, and `DebugPanelView` is a
macOS-only `Window` (`LarmindonApp.swift:22-39`). On iOS there is no path to it.

Fix: expose it via a **launch argument**, not a UI toggle. Launch arguments need no
interaction, which is what makes automation possible.

### Gap 2 — The fake source isn't deterministic

It free-runs on a 750ms timer over a hardcoded script
(`FakeTranscriptionSource.swift:12-25`), and **none of its lines carry a `speakerID`.**
So speaker bars, block merging, and the three spacing tiers in `CaptionDisplayView` —
a substantial chunk of the caption rendering — are never exercised by it.

Fix: injectable script loaded from a JSON fixture (matching the existing
`soniox_token_evolution.jsonl` pattern), speaker IDs included, and a deterministic
clock or externally-driven step mode.

### Gap 3 — The Apple source can't accept injected audio

`SonioxTranscriptionSource.start(audioFrames:)` takes an injected frame stream
(`CaptionSession.swift:207`), but `LiveSpeechAnalyzerTranscriptionSource` owns its own
`AVAudioEngine` internally (`LiveSpeechAnalyzerTranscriptionSource.swift:24`) and
`start()` takes no arguments.

Making the Apple source accept injected frames the way the Soniox one does is the
single change that unlocks file-driven testing of on-device mode — and it's worth
doing on design-symmetry grounds regardless.

### How much of the Rust/Tauri replay approach ports

More than expected. The blocker is SpeechAnalyzer specifically, not the pipeline.

- **Server mode is already gated and needs no device.** Soniox is just a WebSocket;
  `FakeWebSocketTransport` and the recorded fixtures already exercise token evolution
  deterministically. Extending those fixtures is cheaper than building anything new.
- **On-device mode can be gated on the Mac.** `LarmindonKit` is multiplatform and macOS
  has SpeechAnalyzer. Once Gap 3 is closed, a macOS unit test can push a fixture WAV
  through a real analyzer and assert on output — the direct analogue of the Rust setup,
  running on the dev machine rather than a device. Assert loosely (expected words
  present, or a word-error-rate threshold); transcription output drifts across OS
  updates and exact-string assertions would rot.

### XCUITest target

Once Gaps 1 and 2 are closed, an XCUITest target running the simulator against the fake
source gates: captions appearing, scroll pinning to bottom, scroll-up unpinning, font
size changes, landscape layout. Screenshots as `XCTAttachment`s for eyeballing.

**Avoid automated pixel-diff snapshot testing.** It breaks on every OS point release;
re-baselining would cost more than it catches. Screenshots for human review, pure
functions for automated assertions.

*Status: scope undecided — whether this lands in this round or waits until the fake
source is deterministic and its value is visible.*

---

## Sequencing

1. **Background captions** (Steps 1–7). Independent of everything else, small.
   Interruption policy unit-tested from the start — nearly free given the existing
   pattern.
2. **Fake source determinism + iOS reachability** (Gaps 1, 2). Small, unlocks the rest.
3. **Injected frames for the Apple source** (Gap 3). Small, unlocks WAV-driven testing
   and improves the design.
4. **XCUITest target.** Only once 2 is done.
5. **Picture-in-Picture.** Only after living with background captions.

## Open decisions

- Local notification on unrecoverable background failure? (Step 6)
- XCUITest target in this round, or held until the fake source is deterministic?
- Is a 2–3 line PiP overlay actually useful, given legibility is the whole point?

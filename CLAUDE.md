# Larmindon (Swift)

SwiftUI-native live captioning app for **macOS and iOS 26+ only** — never targets any
earlier OS version. Uses Apple's built-in **SpeechAnalyzer / SpeechTranscriber** APIs for
on-device transcription. (Native rewrite of an earlier captioning app.)

## Source control: git

This repo uses **plain git**. It was on jujutsu for a while; that was removed on
2026-08-15 — the workflow had things to like but too much friction overall. There is no
`.jj` directory, so `jj` commands will fail here.

**Checkpoint every turn** — after making changes, `git add` the relevant paths and
`git commit`. Don't wait to be asked. Prefer many small checkpoints over one large one:
builds get tested on real hardware, so being able to roll back one bad change without
losing the good ones matters.

## Tooling: use `rtk`

Prefer **`rtk`** (Rust Token Killer) as a proxy for shell tool calls to save tokens — e.g.
`rtk grep`, `rtk git ...`. The Claude Code hook rewrites most commands transparently, but
reach for it deliberately on grep/search/git/build output where filtering helps.

## Build & test

Tuist-generated project (`Project.swift` → `Larmindon.xcworkspace`). Schemes/targets:

- `LarmindonKit` — framework with all the real code (`Sources/Core`, `SpeechPipeline`,
  `AudioRouting`, `UI`, `Debug`). Both apps depend on it.
- `Larmindon` — iOS app (`Sources/App/**`). **This scheme has no macOS destination.**
- `Larmindon-macOS` — macOS app (same `Sources/App/**`).
- `CoreTests` — unit tests (`Tests/CoreTests/**`).

Compile-check (iOS sim):
```
xcodebuild -workspace Larmindon.xcworkspace -scheme Larmindon \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
```
For macOS use `-scheme Larmindon-macOS`. If `Project.swift` changes, regenerate with `tuist generate`.

## Testing constraints — IMPORTANT

- **SpeechAnalyzer does NOT work in the iOS Simulator.** It must run on a physical device.
  The iOS Simulator build only confirms the code *compiles*, not that transcription works.
- The user runs **on-device builds from Xcode** for live functional testing. Don't attempt to
  verify transcription/audio behavior yourself — leave that to the user and just report what
  compiles.

## Architecture notes

- **Settings** persist via SwiftUI `@AppStorage` (UserDefaults). Keys are duplicated as string
  literals across `PreferencesView` (the settings UI) and `LarmindonRootView` (reads them to
  start a session). Constants/enums live in `Sources/Core/UserPreferences.swift`.
- **Capture settings take effect at session start**, not live. `LarmindonRootView` reads the
  `@AppStorage` values and passes them into `CaptionSession.start(...)`, which stores them and
  forwards to `makeSource(...)` → `LiveSpeechAnalyzerTranscriptionSource`. Changing a capture
  setting mid-session requires Stop → Start to apply. Follow this pattern for new settings.
- `CaptionSession` (`@MainActor @Observable`) owns the active `TranscriptionSource`
  (`live` = `LiveSpeechAnalyzerTranscriptionSource`, `fake` = `FakeTranscriptionSource`),
  the `CaptionStore`, and the `AudioRouteManager`.

### macOS audio capture — don't undo these

Selecting an input **inside the app**, without touching macOS system audio settings, is a
core feature. These constraints were established by debugging real failures; each has a
diagnostic signature in `larmindon-diagnostics-*` bundles.

- **AVAudioEngine is only used for the system default input.** Every other device is read
  directly through a Core Audio IOProc (`MacOSDirectAudioDeviceCapture` /
  `SharedMacOSAudioDeviceCapture`), routed by `MacOSAudioCaptureStrategy.forDevice`.
  Setting `kAudioOutputUnitProperty_CurrentDevice` on the input node returns `noErr` but
  does **not** re-plumb the node — it keeps the previous device's format, so the tap
  installs at the wrong rate and `engine.start()` fails with
  `kAudioUnitErr_FormatNotSupported` (-10868).
- **Voice processing is never enabled on macOS.** It spans input and output as one duplex
  unit built across whatever the default input and default output are. Those are separate
  devices with independent sample rates, and a mismatch fails engine start with
  `kAudioUnitErr_FailedInitialization` (-10875). It also creates an aggregate device,
  which changes the Core Audio device list, which used to retrigger capture and loop. iOS
  applies the same processing through the audio session category/mode instead and is
  unaffected — keep the preference iOS-only.
- **Install taps with a `nil` format.** A format disagreeing with the bus makes
  `installTap` raise an Objective-C exception that Swift cannot catch, taking the app down.
  Buffer conversion downstream is format-agnostic and handles whatever arrives.
- **Don't restart capture on every device-list change.** `CaptionSession` tracks
  `activeInputDeviceID` and only restarts when the captured device actually changed
  identity, which is what happens on unplug/reconnect.

### Soniox shutdown

Ending a session cleanly means sending an empty WebSocket frame (`client.finish()`), then
waiting for the server to flush remaining tokens, send `finished: true`, and close. That
takes a couple of seconds. `SonioxTranscriptionSource.stop()` is re-entrancy-safe on
purpose: a second stop arriving mid-finish would fall through to `cancel()` and discard
those final tokens. `CaptionSession.stopActive` also clears user-visible state *before*
awaiting teardown, so Stop registers on the first press.

# Larmindon

Larmindon is a SwiftUI app for readable live captions on iPhone, iPad, and Mac,
using Apple's on-device speech recognition or Soniox server transcription.

Open it, choose a transcription mode, and start captions. The active audio input
stays visible while finalized text remains stable and in-progress captions update.

## Requirements

- The reproducible local checks use Xcode 27.0 (27A266a), including Swift 6.4.
- iOS 26 or macOS 26. Larmindon is built around Apple's SpeechAnalyzer APIs and does not support older operating systems.
- Tuist 4.200.1. Install that version explicitly using the official release or a tool manager such as `mise`.
- Python 3.9+ for the local check runner (standard library only).

```bash
mise install tuist@4.200.1
```

## Generate and Open

```bash
mise exec tuist@4.200.1 -- tuist generate
open Larmindon.xcworkspace
```

## Local Quality Checks

The entry point is `./scripts/check.sh`. This is a local development workflow;
it does not require CI, signing credentials, App Store setup, microphone access,
or speech-provider API keys. All tool pins live in
[`scripts/checks-toolchain.json`](scripts/checks-toolchain.json).

Before the first run, select the pinned Xcode using `DEVELOPER_DIR` if it is not
already active, finish Xcode's first-launch setup, and install its command-line
components. In Xcode, install the **iOS 26.5** simulator runtime and create an
**iPhone 17** simulator. The runner checks the Xcode version/build, Swift version,
Tuist version, and runtime; it never substitutes `OS=latest` or updates tools.
Tuist may be on `PATH` or installed under `mise` at the pinned version.

Install the development-only linter explicitly, then run the checks:

```bash
./scripts/check.sh setup
./scripts/check.sh
```

`setup` downloads SwiftLint **0.65.1** from its official GitHub release, verifies
the pinned SHA-256 checksum and version, and stores the binary and license under
ignored `.build/check-tools/`. It does not install Xcode, Tuist, or global tools.
Routine checks do not install anything. An absent tool or an incompatible
version fails with an actionable error. Pin upgrades should be separate changes,
with the full checks rerun before acceptance.

| Command | Checks |
| --- | --- |
| `./scripts/check.sh` | All checks below, plus regression tests for the check runner |
| `./scripts/check.sh lint` | Check-only formatting, SwiftLint gate, and unfiltered advisory metrics |
| `./scripts/check.sh format` | Check-only formatting; never rewrites files |
| `./scripts/check.sh test` | Tuist generation, macOS SwiftPM tests (Debug and Release), iOS `CoreTests` |
| `./scripts/check.sh build` | Tuist generation, macOS app and iOS app/widget builds |

The full command regenerates the ignored Xcode workspace from `Project.swift`
with Tuist's binary cache disabled. Builds use Debug configuration and
`CODE_SIGNING_ALLOWED=NO`. The macOS SwiftPM tests also run a second time as an
optimized release build (`-c release` with testability enabled), because optimized code
can fail where Debug passes: a miscompiled inlined initializer once crashed every Soniox
start in Release while all Debug checks were green. The iOS build includes the embedded widget. SwiftPM
tests alone do not cover the app entry point, widget, or iOS-only tests.

The iOS `CoreTests` suite runs inside a blank `LarmindonTestHost` app so its layout
tests have a real window scene. The host contains no capture or diagnostics
startup. macOS SwiftPM tests remain independent of an app host.

If multiple simulators share the expected name, choose one explicitly:

```bash
./scripts/check.sh test --simulator YOUR-SIMULATOR-UDID
```

The selected device must still be on the pinned iOS 26.5 runtime. Find its UDID
with `xcrun simctl list devices available`. The runner does not create or delete
devices or change your global Xcode selection.

Each run prints its report directory under `.build/checks/run-…/`. It contains
JSON lint/metrics reports, a readable metrics summary, a format log, the tool pins, build/test
logs, and (for iOS tests) an `.xcresult` bundle. Nonzero tool/build/test exits fail
the command. Missing source groups, a missing baseline, and invalid SwiftLint
rules also fail. Checks use no autofix or formatting writes; the runner hashes
Git-visible inputs before and after and fails if they changed, without reverting
anything. Avoid editing the checkout during a full run. Build caches and reports
are ignored and can be removed when no check is running.

### Formatting and Compiler Warnings

The `swift-format` bundled with the pinned Xcode uses the repository's
[`.swift-format`](.swift-format): four-space indentation, a 120-column target,
and no extra indentation inside conditional-compilation blocks. Layout and
trailing commas are standardized; broader style rewrites and string-literal
reflow are disabled. The initial formatting sweep is a separate Git checkpoint.

`all`, `lint`, and `format` run `swift-format lint --strict`. To apply formatting
deliberately, use the same configuration and toolchain (replace the paths with
individual files when making a small change):

```bash
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault xcrun swift-format format \
  --configuration .swift-format --in-place --recursive \
  Sources Tests Widgets Package.swift Project.swift
```

The local test/build commands treat **Swift compiler warnings as errors**:
SwiftPM receives `-Xswiftc -warnings-as-errors`; Xcode receives
`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`. Swift 6 language checking remains enabled.
Other build-tool warnings, such as App Intents metadata extraction notices,
remain visible in the logs. Keep toolchain upgrades separate from code changes
so new compiler diagnostics can be reviewed deliberately.

The runner's regression tests verify that formatting violations and malformed or
missing formatter configuration fail, that check-only formatting leaves files
unchanged, and that an actual Swift compiler warning is rejected.

### Lint Policy and Existing Debt

[`.swiftlint.yml`](.swiftlint.yml) explicitly enables force casts/tries, duplicate
conditions and dictionary keys, unused optional bindings, unhandled throwing
tasks, invalid or unnecessary suppression commands, and cyclomatic complexity.
It scans `Sources`, `Tests`, `Widgets`, `Package.swift`, and `Project.swift`.
SwiftLint runs with `--strict`: a new finding, including complexity **above 10**,
fails the gate. Complexity above 20 is an error and calls for decomposition.

The reviewed [baseline](.swiftlint-baseline.json) contains only these existing
complexity exceptions. No correctness-rule exceptions were needed:

| Existing function | Score | Planned work |
| --- | --- | --- |
| `AudioRouteManager.apply` | 11 | Separate configuration resolution from application |
| `CaptionSession.performStart` | 20 | Separate provider creation and lifecycle coordination |
| `LiveSpeechAnalyzerTranscriptionSource.startSpeechAnalyzerPipeline` | 15 | Extract capture ownership |

Phase 02 separated Soniox event consumption, audio sending, and pings into focused
methods, retiring its complexity exception. The remaining exceptions let tooling
land without rewriting the other startup paths. The
separate [metrics configuration](.swiftlint-metrics.yml) reports them without a
baseline, alongside file, type, function length, and nesting findings. Length
and nesting are advisory even when SwiftLint labels a finding an error. A native
baseline is suppression, not a guaranteed complexity ratchet; review the raw
score when changing an exempt function. Remove its entry when it is improved.

For a deliberate baseline review, write a **candidate**, never over the committed
file during a routine check:

```bash
.build/check-tools/0.65.1/swiftlint lint --config .swiftlint.yml --no-cache \
  --write-baseline .build/checks/proposed-baseline.json
```

Compare the candidate with the committed file. Remove resolved exceptions;
explain any newly approved exception and its follow-up in the change description.
Do not approve all findings simply to make checks pass. The gate's own tests use
disposable copies to verify that new violations fail and the baseline remains
portable across checkout paths.

See the [maintenance plan](maintenance-and-modularization-plan.html#phase-2) for
the remaining work. **01A–01C and 02A–02C** are implemented locally; CI and
release/distribution automation are deferred. Passing local tests/builds does not validate physical-device audio,
SpeechAnalyzer operation, live provider services, or speech quality in noise.

Phase 02 keeps all lifecycle tests offline. Capture acquisition, transport startup,
shutdown deadlines, and interruption backoff have narrow injectable dependencies;
production still uses the same capture strategies and monotonic delays. Terminal
recognition errors use `CaptionResult.failure`, including Apple runtime errors.
Soniox retains a 64-event result buffer: partial previews may be replaced, but
losing a finalized event terminates delivery with an explicit error. Diagnostic
SQLite reads throw on step errors, including failures after earlier successful rows.


## Build the iOS Simulator Target

After generation, build the `Larmindon` scheme for an iOS simulator:

```bash
xcodebuild -workspace Larmindon.xcworkspace -scheme Larmindon -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
```

To exercise the iPad build explicitly, select an installed iPad simulator:

```bash
xcodebuild -workspace Larmindon.xcworkspace -scheme Larmindon -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=26.5' build
```

Use simulator names that exist on your machine if either example device is not
installed.

## Redeploy to a Connected iPhone or iPad

With one iOS device connected and trusted, rebuild, install, and launch a
freshly signed development copy from the command line:

```bash
./scripts/redeploy-device.sh
```

If more than one physical iOS device is connected, pass its name or UDID:

```bash
./scripts/redeploy-device.sh "My iPad"
```

The script builds Debug by default. For an optimized Release build, including
when profiling CPU and power use with Instruments:

```bash
./scripts/redeploy-device.sh --release
./scripts/redeploy-device.sh --release "My iPhone"
```

`--release` can be combined with `--refresh-profile`. Both configurations use
development signing. Release products and their matching `.dSYM` files are in
`.build/DeviceDerivedData/Build/Products/Release-iphoneos/`; retain those symbols
for the build used in a recording so Instruments can resolve function names.

To force Xcode to issue a new development provisioning profile before the
redeploy, move the matching cached profile into a private local backup and
build with automatic provisioning:

```bash
./scripts/redeploy-device.sh --refresh-profile
```

Profile refresh requires an Apple account to be signed in under Xcode Settings
> Accounts so `xcodebuild` can request the replacement from Apple. If issuance
or the build fails, the script restores the previous cached profile.

Inspect the current cached profile and compare it with the profile embedded in
the most recent device build:

```bash
./scripts/show-ios-profile.sh
```

## Install a macOS Release Build

Build the macOS app in Release configuration and replace the copy installed at
`~/Larmindon_macOS.app`:

```bash
./scripts/deploy-macos-release.sh
```

Builds are signed with the personal-team Apple Development certificate (set in
`Project.swift`; the script also derives the team from the certificate). This matters
for more than tidiness: an ad-hoc signature's designated requirement is the build's
code hash, so macOS treats every rebuild as a new app and asks for microphone access
again. A certificate-backed signature keeps the grant across rebuilds.

## Transcription Modes

The main screen offers **On-device** and **Soniox**. On-device is the initial
default; the app remembers your selection. Press **Start Captions** to use the
selected mode and saved capture settings.

On-device uses Apple's `SpeechAnalyzer`, `SpeechTranscriber`, and `SpeechDetector`.
It requires compatible speech assets and a physical device for live validation;
the iOS Simulator cannot establish that SpeechAnalyzer transcription works.
Startup errors appear on the caption screen, with session details in **Microphone**.

Soniox captures audio locally and streams it to Soniox. Save your own API key in
**Settings → Server Transcription** before starting. The key is stored in Keychain;
it is validated when the first connection is made. Soniox is currently the only
implemented server provider.

## Fake Transcription Mode

Open **Microphone → Developer → Start fake transcription source** to exercise
captions without a microphone or provider connection. It streams scripted
in-progress and finalized events every 750 ms and works in Simulator.

## Settings

The settings surface includes:

- Caption font size, from 20 to 72 points.
- A fixed theme, or separately chosen light/dark themes that follow system
  appearance. Options include Light, Dark, Dark Blue, Dark Green, Rosé Pine,
  Rosé Pine Moon, Rosé Pine Dawn, Dracula Classic, and Alucard Classic.
- On-device VAD sensitivity and profanity filtering.
- Capture buffer size, from 160 to 2,048 frames (default 768).
- Apple voice processing on iOS/iPadOS, enabled by default and applied when
  capture next starts. Requested and active state are shown in **Microphone**.
  Voice processing remains disabled on macOS because of audio-device constraints.
- Server provider selection and Soniox credential storage/removal.

Capture and recognition setting changes take effect when the relevant session
next starts. Font size and theme choices update the presentation directly.

## Microphone and Diagnostics

The **Microphone** toolbar button opens a sheet on iOS/iPadOS and a separate
window on macOS. It replaces the old debug panel and shows input capabilities,
session/provider status, levels, requested and active voice processing, route
details, and the latest transcript state. Supported iOS inputs also expose
microphone-position, pickup-pattern, and stereo-orientation controls; applying
them during capture restarts captions.

The panel can prepare and share/save a diagnostic bundle. Transcript text is
excluded by default and can be included explicitly. Developer actions provide
the fake source and a route-information dump.

## Live Speech Paths

`LiveSpeechAnalyzerTranscriptionSource` owns the current on-device path, converting
captured buffers into `AnalyzerInput`, using `SpeechDetector` for VAD, and consuming
fast/volatile `SpeechTranscriber` results. Capture uses the configured buffer
request; the actual callback size is reported in **Microphone**.

Server mode uses `AudioCaptureSession` to supply captured frames to
`SonioxTranscriptionSource`. The [maintenance plan](maintenance-and-modularization-plan.html)
describes future consolidation of the capture paths and completion of the
provider boundary before adding Azure or custom audio processing.

## Audio Routing

On iOS/iPadOS, the app configures `AVAudioSession` for capture according to the
selected input and voice-processing preference, supports Bluetooth HFP, tracks
route inputs/outputs, and provides a system input picker with a fallback menu.
The main screen shows the current input; **Microphone** shows preferred and
active route details.

On macOS, the input menu tracks devices by stable Core Audio UID and restarts
capture when the selection changes. The system-default input uses `AVAudioEngine`;
every other selected input uses a direct Core Audio IOProc, including physical,
virtual, and aggregate devices. Selecting an input in Larmindon does not change
the system-default input.

## Physical-Device Validation

Local tests and unsigned builds cover policies, mocked providers, and simulator
layout. Changes affecting live operation need checks on the relevant hardware:

- Microphone permission flow.
- SpeechAnalyzer asset availability and live recognition.
- `AVInputPickerInteraction` behavior on iPhone and iPad.
- Bluetooth HFP route switching.
- Car audio route display.
- Voice-processing input behavior.
- Real-device validation of the `AVAudioEngine` to `SpeechAnalyzer` `AnalyzerInput` bridge.
- Soniox connection, live results, and stop/restart behavior with a configured key.

## Source Control

This repository uses Git. Check the diff, stage only the intended files, and
create a checkpoint after each change:

```bash
git status
git diff
git add path/to/changed-file
git commit -m "Describe the change"
```

Do not stage unrelated working-tree changes.

## Lock Screen caption launcher

The iOS app embeds a circular **Start Captions** widget using the Larmindon glyph.
After installing and opening the app once, customize the Lock Screen, choose
**Add Widgets → Larmindon → Start Captions**, and place the circular widget.
Tapping it opens the caption screen (unlocking the phone if required) and starts
live captions with the saved On-device or Soniox selection and capture settings.
An existing, starting, stopping, or interrupted session is left intact. Taps are
consumed once; they do not queue a restart after the session ends.

The widget opens `larmindon://captions/start`. The app accepts only that action,
waits until its scene is active, dismisses its settings/microphone sheets, and
uses the same guarded start operation as the Start Captions button. Credentials
stay in the app Keychain; no App Group or widget configuration is required.
Missing credentials and microphone/speech permission failures use the app's
normal error presentation. Set up Soniox in Settings before using that mode.

For simulator URL routing checks (with the app installed):

```sh
xcrun simctl openurl booted 'larmindon://captions/start'
```

Verify both a terminated-app launch and an already-open app, then repeat while
captions are starting/running. Automated tests cover URL validation, duplicate
starts, provider preservation, failed-start retries, local teardown, and iOS
interruption protection. Lock Screen appearance, authentication, and actual
microphone/transcription startup still require a physical iPhone check.

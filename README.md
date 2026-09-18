# Larmindon

Larmindon is a first-pass SwiftUI prototype for readable, on-device live captions on Apple platforms.

The app is intentionally plain: open it, start captions, keep the active audio input visible, and show stable finalized caption chunks plus one faded volatile tail.

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
| `./scripts/check.sh lint` | Fast SwiftLint gate plus unfiltered advisory metrics |
| `./scripts/check.sh test` | Tuist generation, macOS SwiftPM tests, iOS `CoreTests` |
| `./scripts/check.sh build` | Tuist generation, macOS app and iOS app/widget builds |

The full command regenerates the ignored Xcode workspace from `Project.swift`
with Tuist's binary cache disabled. Builds use Debug configuration and
`CODE_SIGNING_ALLOWED=NO`. The iOS build includes the embedded widget. SwiftPM
tests alone do not cover the app entry point, widget, or iOS-only tests.

If multiple simulators share the expected name, choose one explicitly:

```bash
./scripts/check.sh test --simulator YOUR-SIMULATOR-UDID
```

The selected device must still be on the pinned iOS 26.5 runtime. Find its UDID
with `xcrun simctl list devices available`. The runner does not create or delete
devices or change your global Xcode selection.

Each run prints its report directory under `.build/checks/run-…/`. It contains
JSON lint/metrics reports, a readable metrics summary, the tool pins, build/test
logs, and (for iOS tests) an `.xcresult` bundle. Nonzero tool/build/test exits fail
the command. Missing source groups, a missing baseline, and invalid SwiftLint
rules also fail. Checks use no autofix or formatting writes; the runner hashes
Git-visible inputs before and after and fails if they changed, without reverting
anything. Avoid editing the checkout during a full run. Build caches and reports
are ignored and can be removed when no check is running.

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
| `SonioxTranscriptionSource.start(audioFrames:)` | 16 | Separate event, send, and connection lifecycles |

These exceptions let tooling land without rewriting startup behavior. The
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

See the [maintenance plan](maintenance-and-modularization-plan.html#phase-1) for
the remaining work. Formatting configuration/sweep and Swift warnings-as-errors
are **01C**, not part of this gate yet. CI and release/distribution automation are
deferred. Passing local tests/builds does not validate physical-device audio,
SpeechAnalyzer operation, live provider services, or speech quality in noise.

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

## Live Transcription Mode

The default transcription source is `Live`. Press **Start Captions** in the app to capture microphone audio and feed it through Apple's on-device SpeechAnalyzer pipeline.

If the simulator or device does not have a compatible speech asset installed for the selected locale, the debug panel will show the Speech asset error. Real-device testing is still the most reliable path for the live source.

## Fake Transcription Mode

The `Fake` source streams scripted volatile and finalized caption events every 750 ms. This mode works in Simulator and does not require microphone hardware.

The settings surface includes:

- Caption font size.
- Light, dark, system, dark blue, or dark green appearance.
- Fake or live source selection.
- VAD sensitivity.
- Voice processing preference placeholder.
- Debug panel visibility.

## Live Speech Path

`LiveSpeechAnalyzerTranscriptionSource` is the native on-device path. It uses the modern Speech framework types (`SpeechAnalyzer`, `SpeechTranscriber`, and `SpeechDetector`) directly. Larmindon requires iOS 26/macOS 26 because SpeechAnalyzer is the reason this prototype exists.

The live source configures capture, runs an `AVAudioEngine` input tap with a 768-frame buffer, feeds `AnalyzerInput` into `SpeechAnalyzer`, uses `SpeechDetector` as the VAD module, and consumes `SpeechTranscriber` results with `.fastResults` and `.volatileResults` reporting.

## Audio Routing

On iOS/iPadOS, the app configures `AVAudioSession` for voice capture, allows Bluetooth HFP, tracks actual route inputs/outputs, and provides both a system input picker host and a fallback menu for available inputs. The main UI always displays the actual current route input, while preferred input details are shown in the debug panel.

On macOS, the input menu tracks devices by stable Core Audio UID and restarts live capture when the selection changes. Built-in and external hardware microphones use `AVAudioEngine`; virtual and aggregate devices use a direct Core Audio IOProc so Loopback-style and multi-stream devices are captured from the selected device instead of silently falling back through the engine input node.

## Real-Device Testing Still Needed

- Microphone permission flow.
- Speech recognition permission flow.
- `AVInputPickerInteraction` behavior on iPhone and iPad.
- Bluetooth HFP route switching.
- Car audio route display.
- Voice-processing input behavior.
- Real-device validation of the `AVAudioEngine` to `SpeechAnalyzer` `AnalyzerInput` bridge.

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

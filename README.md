# Larmindon

Larmindon is a first-pass SwiftUI prototype for readable, on-device live captions on Apple platforms.

The app is intentionally plain: open it, start captions, keep the active audio input visible, and show stable finalized caption chunks plus one faded volatile tail.

## Requirements

- Xcode 26.5 or newer from the local Apple SDK family used for this prototype.
- iOS 26 or macOS 26. Larmindon is built around Apple's SpeechAnalyzer APIs and does not support older operating systems.
- Tuist. If it is not already available, install it with the official installer or your preferred tool manager. In this checkout it may be available through `mise`.

```bash
mise exec -- tuist version
```

## Generate and Open

```bash
mise exec -- tuist generate
open Larmindon.xcworkspace
```

## Build the iOS Simulator Target

After generation, build the `Larmindon` scheme for an iOS simulator:

```bash
xcodebuild -workspace Larmindon.xcworkspace -scheme Larmindon -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build
```

To exercise the iPad build explicitly, select an installed iPad simulator:

```bash
xcodebuild -workspace Larmindon.xcworkspace -scheme Larmindon -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5),OS=latest' build
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

This repository is friendly to Jujutsu workflows. A typical local flow is:

```bash
jj status
jj diff
jj commit -m "Build SwiftUI Larmindon prototype"
```

Git-compatible hosting still works; use whichever commit workflow is appropriate for the checkout.

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
xcodebuild -workspace Larmindon.xcworkspace -scheme Larmindon -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Use a simulator name that exists on your machine if `iPhone 17` is not installed.

## Redeploy to a Connected iPhone

With one iPhone connected and trusted, rebuild, install, and launch a freshly
signed development copy from the command line:

```bash
./scripts/redeploy-device.sh
```

If more than one physical iOS device is connected, pass its name or UDID:

```bash
./scripts/redeploy-device.sh "My iPhone"
```

## Install a macOS Release Build

Build the macOS app in Release configuration and replace the copy installed at
`~/Larmindon_macOS.app`:

```bash
./scripts/deploy-macos-release.sh
```

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

On macOS, route information is a first-pass read-only placeholder so the shared UI and macOS target can build while platform-specific input selection is designed.

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

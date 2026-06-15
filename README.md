# Larmindon

Larmindon is a first-pass SwiftUI prototype for readable, on-device live captions on Apple platforms.

The app is intentionally plain: open it, start captions, keep the active audio input visible, and show stable finalized caption chunks plus one faded volatile tail.

## Requirements

- Xcode 26.5 or newer from the local Apple SDK family used for this prototype.
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

## Fake Transcription Mode

The default transcription source is `Fake`. Press **Start Captions** in the app to stream scripted volatile and finalized caption events every 750 ms. This mode works in Simulator and does not require microphone hardware.

The settings surface includes:

- Caption font size.
- Light, dark, or system appearance.
- Fake or live source selection.
- VAD sensitivity.
- Voice processing preference placeholder.
- Debug panel visibility.

## Live Speech Path

`LiveSpeechAnalyzerTranscriptionSource` is the intended native on-device path. It uses the modern Speech framework types (`SpeechAnalyzer`, `SpeechTranscriber`, and `SpeechDetector`) behind iOS 26/macOS 26 availability checks.

For this first pass, the live source configures capture and constructs the Speech modules, then returns a clear TODO error before feeding `AnalyzerInput`. The fake source, shared store, route manager, settings, and UI already use the same `TranscriptionSource` abstraction so the real microphone pipeline can be completed without reshaping the app.

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
- Completing the `AVAudioEngine` to `SpeechAnalyzer` `AnalyzerInput` bridge.

## Source Control

This repository is friendly to Jujutsu workflows. A typical local flow is:

```bash
jj status
jj diff
jj commit -m "Build SwiftUI Larmindon prototype"
```

Git-compatible hosting still works; use whichever commit workflow is appropriate for the checkout.

# Larmindon (Swift)

SwiftUI-native live captioning app for **macOS and iOS 26+ only** — never targets any
earlier OS version. Uses Apple's built-in **SpeechAnalyzer / SpeechTranscriber** APIs for
on-device transcription. (Native rewrite of an earlier captioning app.)

## Source control: jujutsu (`jj`)

This repo uses **jujutsu**, not plain git. **Checkpoint every turn** — after making changes,
run `jj commit -m "..."`. Don't wait to be asked. There's no staging step in jj; the working
copy is always a commit.

Use `jj commit`, **not** `jj describe`. `describe` only renames the working-copy commit, so
running it every turn overwrites the previous message and collapses all the work into a
single commit with no rollback granularity. `jj commit` describes the working copy *and*
starts a new one. Check `jj log` afterwards: the number of commits should be growing, not
one commit being renamed repeatedly.

Prefer many small checkpoints over one large one. Builds get tested on real hardware, so
being able to roll back one bad change without losing the good ones matters.

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

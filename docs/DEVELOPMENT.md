# Development

This document describes how to build, run, sign, and extend AnyListen.

## Required tooling

- **Xcode 15 or later** (Swift 5.9 / iOS 17 SDK).
- **XcodeGen** if you want to regenerate the project from `project.yml`:

  ```sh
  brew install xcodegen
  ```

- (Optional) a real iOS device for low-latency audio verification.
  The simulator runs the code, but `AVAudioSession.availableInputs` is
  stubbed and `AVRoutePickerView` shows no real routes.

## Project generation

`AnyListen.xcodeproj` is **generated** from `project.yml` and **not**
committed by hand. If you change `project.yml`, regenerate:

```sh
cd /path/to/AnyListen
xcodegen generate
```

`XcodeGen` will write:

- `AnyListen.xcodeproj/project.pbxproj`
- `AnyListen/Info.plist` (filled in from the `info.properties` block
  in `project.yml`)

It's safe to run `xcodegen generate` repeatedly — it overwrites cleanly.

### Adding files

When you add new Swift files:

1. Drop them in `AnyListen/`.
2. Re-run `xcodegen generate`.
3. Confirm the file is listed in `project.pbxproj` under the
   `AnyListen` target.
4. Re-open the project (`xcodegen` regenerates `pbxproj` cleanly, so
   no manual merging is needed).

Alternatively, you can right-click "Add Files…" inside Xcode, then add
the same files to `project.yml` so a regeneration doesn't drop them.

### Removing files

Delete the file from disk and remove its entry from `project.yml`,
then `xcodegen generate`. Or remove via Xcode and re-run
`xcodegen generate`.

## Build & run

```sh
xcodegen generate
open AnyListen.xcodeproj
# Build & Run on a connected device or the iOS Simulator
```

In Xcode:

1. Select the `AnyListen` scheme (only scheme in this repo).
2. Pick a destination (Simulator or a real device).
3. ⌘R.

Because microphone access is required, the first time the app
launches on a real device iOS will prompt. Use
`AVCaptureDevice.authorizationStatus(for: .audio)`-style flow inside
the app to verify behavior.

## Signing

`project.yml` carries a hard-coded `DEVELOPMENT_TEAM`:

```yaml
DEVELOPMENT_TEAM: 2UD3JL69WU
```

If you're going to commit a public fork:

- Replace with your own team ID, **or**
- Override per-developer in a `Config.xcconfig` and consume it in
  `project.yml` via `$(DEVELOPMENT_TEAM)`, **or**
- Remove the line entirely so contributors fill it in their Xcode
  account settings.

A real device build with an unsigned bundle will fail unless
signing identities are configured.

## Info.plist

Generated from `project.yml` (`info.properties`). iOS-bundled
properties currently set:

| Key | Value | Why |
|-----|-------|-----|
| `NSMicrophoneUsageDescription` | "AnyListen needs microphone access to route audio to your selected output." | Mandatory string for `AVAudioSession` record permission. |
| `UIBackgroundModes` | `[audio]` | Allows the audio session to stay live while the app is in the background or the screen is off. |
| `UILaunchScreen` | `{}` | Default empty launch screen spec — splash is whatever iOS draws. |
| `UISupportedInterfaceOrientations` | `[UIInterfaceOrientationPortrait]` | Portrait-only on iPhone. |

If you add a usage description later (e.g. for Bluetooth), add it to
`project.yml` and run `xcodegen generate` rather than editing
`Info.plist` directly — XcodeGen will regenerate.

## Bundle identifier

`com.anylisten.AnyListen`. Reserved suffixes:

- Cross-compile targets cannot share this id.
- Push notification / Background mode entitlements are *not*
  currently used; if you add them, they live in the developer
  portal, behind this id.

## Dependencies

Zero third-party dependencies. All frameworks used are first-party:

- `SwiftUI`
- `AVFoundation`
- `AVKit`
- `Foundation`
- `Combine`

There is no `Package.swift`, no `Cartfile`, no `podspec`.

## Suggested test target layout

There is currently **no test target**. To add one, add a target to
`project.yml`:

```yaml
targets:
  AnyListen:
    # … existing config
  AnyListenTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: AnyListenTests
    dependencies:
      - target: AnyListen
```

Recommended test categories:

1. **Pure logic tests** — `readableInputType`,
   `readableOutputName`, `sessionCategoryOptions` decision table.
2. **State-machine tests** — drive `AudioEngineManager` through
   `init → selectInput(A) → selectInput(B) → clearSelectedInput` and
   assert @Published values. AVAudioSession calls need to be either
   stubbed or run on a real device since the iOS simulator stubs are
   inconsistent.

## Build hygiene checklist

- ✅ `project.yml` is the source of truth.
- ✅ `Info.plist` is generated; don't hand-edit.
- ❌ No `.swiftlint.yml` (see [`REVIEW.md`](REVIEW.md) L4).
- ❌ No `.swiftformat` (see [`REVIEW.md`](REVIEW.md) L4).
- ❌ No `Config.xcconfig` for per-developer overrides.
- ❌ No CI (`/.github` etc.).

When adding CI, the minimum useful pipeline is:

1. `xcodegen generate`.
2. `xcodebuild -scheme AnyListen -destination 'platform=iOS Simulator,name=iPhone 15' build`.
3. (Once a test target exists) `xcodebuild test …`.

## Permissions privacy

This app:

- Requests `NSMicrophoneUsageDescription` lazily, only when the
  user taps LISTEN.
- Never persists microphone audio.
- Never opens a network socket.
- Does not include any analytics frameworks.

If you ever change any of these, update the privacy section in this
document and re-review the app review questionnaire accordingly.

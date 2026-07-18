# Code Review

A focused review of the codebase, organized by severity and topic. Items
were chosen because each is either a real correctness/robustness risk
or a concrete user-experience gap that a future iteration would want to
address.

Suggested severity legend:

- 🔴 **High** — corrects a real bug or risk; ship-blocker.
- 🟠 **Medium** — sharp edge that will bite in production.
- 🟡 **Low** — polish / hardening.

---

## 🔴 High

### H1. Pass-through gain is fixed at 1.0 with no UI control

The mixed signal is `mainMixerNode` at the default volume of `1.0`.
This is fine for monitoring, but if the user pairs — say — a high-gain
USB preamp and a Bluetooth speaker, the result can be uncomfortably
loud or clipping. On AirPods/BT speakers without hardware volume
limits, sudden peaks can hurt ears.

**Suggested fix:** expose `mainMixerNode.outputVolume` as
`@Published var passThroughGain: Float`, default `1.0`, persistent via
`UserDefaults`, with a `Slider` in the settings card. Clamp `0.0...1.0`.

### H2. App icon is missing

`project.yml` references no asset catalog, and `AnyListen/` has no
`Assets.xcassets`. The Xcode build will produce an empty/default app
icon, which looks broken on the home screen and fails App Store
review.

**Suggested fix:** add `Assets.xcassets` with at minimum
`AppIcon.appiconset` containing the required 1024×1024 master plus the
device-scoped 60×60 / 120×120 / 180×180 entries. Add to
`project.yml` as an explicit source.

### H3. iPad is excluded without a reason

`TARGETED_DEVICE_FAMILY: 1` and `UISupportedInterfaceOrientations:
[UIInterfaceOrientationPortrait]` deliberately exclude iPad. The
generated app will refuse to install on iPad. Even if iPhone is the
intended target, supporting the iPhone-on-iPad compat mode avoids
"iPhone" cramping on a big screen and broadens reach.

**Suggested fix:** consider `TARGETED_DEVICE_FAMILY: "1,2"` (or
`TARGETED_DEVICE_FAMILY = 1` with the iPad compat flag). If there's a
firm product reason to stay iPhone-only, note that decision in this
document (or in a top-level ADR-style markdown file alongside it).

---

## 🟠 Medium

### M1. Engine is fully torn down / reattached on every stop → start

Every `stop()` calls `teardownAudioEngine()`, and every `start()`
constructs a fresh `AVAudioEngine`. For repeated short toggles this
adds 50–150 ms of latency and produces a soft audio glitch. Keep the
engine alive, just `pause`/`resume` the player and the input tap.

**Suggested fix:** keep `audioEngine` and `playerNode` alive across
stops; only `playerNode.stop()` and `inputNode.removeTap` for shutdown;
on re-start, re-install tap and `playerNode.play()`. Be careful with
the "format on input changed" case — re-install the tap if the input
format changed while stopped.

### M2. `start()` re-activates the session twice

```swift
try configureAudioSessionForCurrentSelection()          // session setActive(true)
…
try applyPreferredInputIfNeeded(forceActive: true)      // session setActive(true) again
```

The second `setActive(true)` is wasted in the common case and can
emit a redundant route-change notification that the debounce happens
to suppress. Consider drop the second activation when
`forceActive == false` callers can satisfy without it, or move the
forced activation into a separate path that's only used when the
preferred input mismatches after the first activation.

### M3. The 2-second `ignoreRouteChangesUntil` window is a magic number

`start()` does `ignoreRouteChangesUntil = Date().addingTimeInterval(2.0)`.
2 s is empirically enough — but on slower devices or during heavy
system contention (incoming call), a route change may arrive after
the window expires and the manager will mis-fire. Make it
configurable, or lengthen to 3 s when `selectedInputIsMissing`.

### M4. `engine.inputNode.inputFormat(forBus: 0)` may have 0 channels

The code does `guard inputFormat.channelCount > 0, …` which is good,
but on some devices the very first input format read is stale
(channel count == 0). Triggering a `format-change` notification and
restarting the engine would be more robust than failing on `start()`.

### M5. Tap-buffer capture is fire-and-forget on disconnect

On hot-unplug of a USB input, the tap may not be torn down for a few
hundred ms and `scheduleBuffer` calls piled up against a player node
whose format is still correct. These either error silently or
delay the engine's stop. Add an explicit drop counter to logs (and
consider cancelling laggard buffers on stop).

### M6. No volume / output lock detection

If you mute output (`AVAudioSession.outputVolume` == 0), the user
hears nothing but the UI says "Listening is ON". Consider a soft
warning when stderr-system volume is 0 on engine start.

### M7. The route picker button is the only piece of Apple audio
chrome inside the app's own UI

There's no AirPlay/Audio-Recording-Indicator hint, no system
"Recording" indicator beyond the iOS status-bar red dot. This is a
UX detail — VoiceOver users in particular don't get a clear
"recording in progress" cue. Consider a visible mic-active state on
the listen button (red glow when running) which already exists via
color but no animation.

---

## 🟡 Low

### L1. No localization

All visible strings are hard-coded English. There is no
`Localizable.strings`. English-only is fine for a v1, but flag this
before any App Store submission outside English locales.

### L2. Accessibility labels

- Big "Listen" button has no `.accessibilityLabel`.
- Input/output rows are unlabeled `HStack`s.
- Alert "Speaker feedback warning" is English-only and not
  type-set for VoiceOver dynamic type sizing.

### L3. No tests

There is no test target. The audio-engine logic is ripe for unit
tests:

- `sessionCategoryOptions` decisions (table-driven by `portType`).
- `readableInputType` / `readableOutputName` mappings.
- State transitions in `selectInput`, `clearSelectedInput`,
  `start`, `stop`.

UIViewRepresentable wrapper for `AudioRoutePicker` is awkward to unit
test directly; consider extracting a `View` model that takes a
`currentOutputName` and exposes an action callback, which would be
unit-testable without a real AVRoutePickerView.

### L4. SwiftLint / SwiftFormat absent

There is no `.swiftlint.yml` or `.swiftformat`. Reasonable picks:

- `*.swift`: 120 column soft, 200 hard.
- SwiftUI views split per file when > 300 lines.
- Force unwrap of implicitly unwrapped optionals discouraged —
  the code is clean here, but enforce as matter of style.

### L5. Magic numbers / constants

- `0.005` (buffer duration) — give it a named constant
  `kPreferredIOBufferDurationSeconds`.
- `1024` (tap buffer size) — `kTapBufferSize`.
- `2.0` (route-change debounce) — `kRouteChangeIgnoreWindowSeconds`.

### L6. Long methods

`AudioEngineManager.start()` and `selectInput()` are both ~30 lines.
Refactor each into named helpers
(`resetAudioSession(preferredInput:)`, `rebuildEngineIfRunning()`) so
the entry points become table-of-contents and logged individually.

### L7. Logging

There are no `os_log` calls. Adding structured logging (with a
subsystem like `com.anylisten.audiomanager` and categories like
`sess`, `engine`, `route`) would dramatically help diagnosing
field reports.

### L8. No asset catalog beyond AppIcon (forward-looking)

When you do add `Assets.xcassets`, prefer a `Brand` color set and an
`AccentColor` so dark mode can flip cleanly. Right now the dark
navy gradient is hard-coded into `ContentView`.

### L9. Error surfaces are coarse

`errorMessage` is one string. Consider an enum of typed error cases
backed by a localized description. This unlocks proper
recovery suggestions in the UI and structured telemetry.

### L10. Background mode is declared but not exercised

`UIBackgroundModes: [audio]` is set. iOS will only keep the app
alive during real audio session activation. Verify this works when
the lock screen engages — and add `applicationWillResignActive`
handling that *doesn't* tear down audio (Apple says audio sessions
should keep running through the lock screen).

### L11. `selectedInputName` stored **and** derived

Both `selectedInputName` and the live `availableInputs[i].name` are
held. They can diverge temporarily
(set-after-pick, before `updateAudioRoutes` runs). Consider always
deriving display names from live inputs and using stored name only
for "missing"-state messaging.

---

## Things that **are** good — don't "fix"

- Memory safety in the tap closure (`[weak player]`, guard on both
  nil and `isPlaying`).
- Permission UX (lazy + completion-based).
- Resilience to media-services reset (`handleMediaServicesReset`).
- Honest `errorMessage` resets at every entry point that could
  resolve one.
- The Bluetooth category trick (`sessionCategoryOptions`) is
  genuinely thoughtful — keep it.

---

## Suggested change order (in priority order)

1. H1 — gain control (user safety).
2. H2 — AppIcon (App Store gate).
3. H3 — decide iPhone-only vs iPad-compat.
4. M1 — keep engine alive across toggles (UX polish).
5. M3 — make debounce configurable.
6. L1 — localization (if shipping wider than en).
7. L3 + L7 — minimal test suite + logging hooks.
8. The rest as polish.

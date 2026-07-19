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

**Status:** ✅ Resolved — `monitorVolume` slider in the Settings sheet,
persisted, clamped to attenuation-only (ROADMAP P4).

### H2. App icon is missing

`project.yml` references no asset catalog, and `AnyListen/` has no
`Assets.xcassets`. The Xcode build will produce an empty/default app
icon, which looks broken on the home screen and fails App Store
review.

**Suggested fix:** add `Assets.xcassets` with at minimum
`AppIcon.appiconset` containing the required 1024×1024 master plus the
device-scoped 60×60 / 120×120 / 180×180 entries. Add to
`project.yml` as an explicit source.

**Status:** ✅ Resolved — `Assets.xcassets/AppIcon.appiconset` with the
single 1024×1024 universal slot (supported since Xcode 14) is in the target
and `ASSETCATALOG_COMPILER_APPICON_NAME` is set in the generated project.

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

**Status:** ✅ Resolved (round 2) — `TARGETED_DEVICE_FAMILY` is now `"1,2"`
(iPad supported via iPhone-on-iPad compat). Portrait-only orientation remains.

---

## 🟠 Medium

### M1. Engine is fully torn down / reattached on every stop → start

Every `stop()` calls `teardownAudioEngine()`, and every `start()`
constructs a fresh `AVAudioEngine`. For repeated short toggles this
adds 50–150 ms of latency and produces a soft audio glitch. Keep the
engine alive, just `pause`/`resume` the player and the input tap.

**Suggested fix:** keep `audioEngine` alive across stops; use
`engine.pause()` to stop and `engine.start()` to resume, rebuilding the
engine only when the input format actually changed (e.g. after an input
switch while stopped). There is no `playerNode` or tap to manage in the
current direct-connection design.

**Status:** Still open. Latency-neutral if done right — `pause`/`start`
preserves the graph and buffer sizes, so the ~5 ms I/O floor is
unchanged. Worth doing alongside auto-listen (see [`ROADMAP.md`](ROADMAP.md), P5).

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

**Status:** ✅ Resolved — `start()` now calls `ensureSessionConfigured()`
once (which activates only if `!sessionIsActive`) then `rebuildEngineOnly()`.
The `forceActive` parameter and the double activation no longer exist.

### M3. The 2-second `ignoreRouteChangesUntil` window is a magic number

`start()` does `ignoreRouteChangesUntil = Date().addingTimeInterval(2.0)`.
2 s is empirically enough — but on slower devices or during heavy
system contention (incoming call), a route change may arrive after
the window expires and the manager will mis-fire. Make it
configurable, or lengthen to 3 s when `selectedInputIsMissing`.

**Status:** ✅ Resolved — it is now the named constant
`routeChangeSilenceWindowSeconds = 2.5`, applied via
`silenceRouteChangesTemporarily()`.

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

**Status:** ✅ N/A (round 3) — the tap and `AVAudioPlayerNode` were removed;
the loopback is now a direct `inputNode → mainMixerNode` connection. There
is no tap buffer to leak and no `scheduleBuffer` calls in flight.

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

**Status:** ✅ Resolved (infrastructure) — every user-facing string is now
extracted into `AnyListen/Localizable.xcstrings` (and
`NSMicrophoneUsageDescription` into `InfoPlist.xcstrings`);
`SWIFT_EMIT_LOC_STRINGS = YES` is set. Content remains English-only for v1
by decision (see APP_STORE.md), but shipping a translation is now a
data-only change.

### L2. Accessibility labels

- Big "Listen" button has no `.accessibilityLabel`.
- Input/output rows are unlabeled `HStack`s.
- Alert "Speaker feedback warning" is English-only and not
  type-set for VoiceOver dynamic type sizing.

**Status:** ✅ Mostly resolved — the Listen button now has label/hint/value,
start/stop is announced to VoiceOver, gear and route picker are labelled,
and the feedback alert no longer exists. Remaining: combine each route row
into a single accessible element.

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

**Status:** ✅ Mostly resolved — `0.005` and the debounce window are now
named constants (`preferredIOBufferDurationSeconds`,
`routeChangeSilenceWindowSeconds = 2.5`); the `1024` tap buffer no longer
exists (tap removed in round 3).

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

- The **direct `inputNode → mainMixerNode` connection** — no tap, no
  player node, no real-time callback — is what delivers Live-Listen-parity
  latency (~5 ms app-added) while removing a whole class of
  tap/`removeTap`-while-running freezes.
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

---

## Bug fixes (round 2 — revised after on-device testing)

> NOTE: an earlier version of this section claimed category priming
> alone fixes USB enumeration and that an auto-"reapply" of the engine
> on route changes was the right policy. On-device testing proved both
> wrong. The corrected behavior is documented here and implemented in
> `AudioEngineManager.swift`.

### Bug A — USB mic missing from `availableInputs` on first launch

**Symptom:** Cold-launch with a USB mic plugged in. Picker shows only
"iPhone Microphone". Selecting "Automatic" makes the USB mic appear
(but Automatic initially resolves to the iPhone mic).

**Cause (corrected):** `availableInputs` does NOT fully enumerate USB
audio devices until the session is **activated** (`setActive(true)`) —
setting the category alone is insufficient. Activation requires mic
permission to be already granted.

**Fix:** At launch, if permission is `.authorized`, we run the full
session configuration **including activation** (`ensureSessionConfigured`).
If permission is undetermined we only prime the category (no launch-time
prompt) and activation happens inside the LISTEN → permission-grant flow.
Additionally: (a) Automatic mode ranks inputs external-first (USB/headset/
line-in > built-in > Bluetooth) and actively pins the best one via
`setPreferredInput`; (b) a one-shot "post-start settle" re-check 0.8 s
after starting upgrades the input if USB enumeration landed late.

### Bug B — AirPods HFP "fake" input in Automatic mode

**Symptom:** "Automatic" mode lists AirPods as an available input
option and even shows them as selected, but the actual audio is
captured from the iPhone built-in mic. Picking the AirPods HFP item
appears to select it but the route stays on iPhone mic.

**Cause:** When `selectedInputID == nil`, the old code set category
options to `[.allowBluetooth, .allowBluetoothA2DP]`. With HFP allowed,
iOS will quietly promote a paired AirPods-in-call-mode or hearing
aid for input — but our `currentInputName` reads from
`currentRoute.inputs.first`, which often reports "iPhone Microphone"
even though the picker shows AirPods.

**Fix:** Default category options are now `[.allowBluetoothA2DP]`
**only**. HFP (`.allowBluetooth`) is opt-in: it's added only when the
user explicitly selects a Bluetooth port as their input. Effect:
AirPods/HA start as **output-only** in our app's session. iOS won't
ever auto-promote them to input, so the menu no longer misadvertises
them as an input.

### Bug C — Output routing: speaker unreachable, picker lies, stale button

**Symptoms (multiple, related):**
1. The native route picker sometimes shows "iPhone Speaker" selected,
   but audio NEVER comes out of the speaker — only the earpiece or
   AirPods produce sound. App text correctly shows "iPhone Earpiece".
2. Switching output mid-listen left the big button stuck on
   "STOP LISTENING" while audio was actually dead.
3. Selecting "iPhone Earpiece" snapped back to "iPhone Speaker".

**Causes (corrected):**
- `.playAndRecord` without `.defaultToSpeaker` defaults built-in
  output to the RECEIVER (earpiece). The old
  `overrideOutputAudioPort(.speaker)` was compensating for this.
- Session deactivation WIPES output overrides. The round-1 "reapply
  engine on every route change" policy did a full deactivate →
  reconfigure → reactivate on each route-change notification, which
  destroyed the user's route-picker choice every time they made one —
  that's why Speaker could never stick.
- `handleRouteChange()` only reacted to `.oldDeviceUnavailable`, so
  output changes left a dead engine with `isRunning == true`.

**Fixes:**
- `.defaultToSpeaker` is now a permanent category option: built-in
  output defaults to the loud speaker, and the native picker's
  Speaker/Earpiece toggle works via the system override.
- The session is NEVER deactivated while the app is alive (except as
  a fallback when a category change refuses to apply while active).
  Route-picker output choices therefore persist across stop/start.
- The round-1 auto-"reapply" policy is REPLACED with a stop-policy
  per user decision: any real route change while running stops
  listening with a short message ("Audio route changed. Tap LISTEN to
  resume."). "Real" is detected via a route signature
  (`inputUID|outputUIDs`) comparison, not reason codes, which are too
  noisy to trust.
- New interruption handling: phone calls / Siri / other audio apps
  interrupting us now stop listening cleanly instead of leaving a
  stuck ON button. We never auto-resume after an interruption.
- Engine config-change notifications (format shifts) rebuild ONLY the
  engine — never the session — so output overrides survive.

### Other improvements shipped alongside

- Magic numbers are named constants: `routeChangeSilenceWindowSeconds`,
  `postStartSettleDelaySeconds`, `preferredIOBufferDurationSeconds`,
  `tapBufferSize`.
- `selectedInputName` storage no longer drives display when the
  selected port is reachable — the live name from `availableInputs`
  wins. The stored name is only used for the "…missing" suffix.
- `UIApplication.didBecomeActiveNotification` re-checks permission
  (covers Settings changes) and re-activates the session if an
  interruption tore it down.
- `project.yml` flipped `TARGETED_DEVICE_FAMILY: 1` → `"1,2"` (iPad).

### Known trade-off to verify

The session now activates AT LAUNCH when mic permission is already
granted (needed for USB enumeration). This means launching the app
takes audio focus (other apps' audio pauses), and the session stays
active while the app is alive. The mic-recording privacy indicator
should only appear while the engine is actually capturing (i.e.
while listening), but this should be verified on-device.

---

## Bug fixes (round 3 — latency, freeze, async enumeration)

### Latency vs Live Listen (~25% extra) — FIXED

**Symptom:** finger-snap test: sound → ~100 ms (AirPods BT floor) →
Live Listen; our app added ~25 ms on top.

**Cause:** the tap-based loopback paid a 1024-frame capture buffer
(21.3 ms @ 48 kHz) before any audio moved, plus AVAudioPlayerNode
scheduling jitter.

**Fix:** the tap and player node are deleted. The input node is
connected directly to `mainMixerNode`
(`engine.connect(inputNode, to: mainMixerNode, format:)`). App-added
latency is now essentially the ~5 ms I/O buffer hint. Side benefit:
no `removeTap`-while-running and no real-time-thread callback at all.

### Freeze when switching input while listening — FIXED

**Symptom:** changing input (iPhone mic → USB mic) mid-listen wedged
the app; force-quit required.

**Cause:** teardown → session reconfigure → engine rebuild ran
synchronously on the main thread while a USB route switch was in
flight — a mediaserverd deadlock class.

**Fix:** in-app input changes now STOP first (per the user's own
policy request — input and output changes behave identically), and
the session is only reconfigured while no engine is alive.

### USB still "— missing" at cold launch — FIXED

**Symptom:** even with launch-time activation, a persisted USB mic
showed "— missing"; selecting "Automatic" (seconds later) found it.

**Cause (now confirmed on-device):** USB enumeration after activation
is asynchronous **by seconds** and fires no route-change notification
when it completes.

**Fix:** 0.5 s × 12-tick polling after activation/start/foregrounding
(`startEnumerationPolling`). Each tick re-queries inputs, refreshes
the UI, and re-pins the preferred input — late USB devices self-heal.

### Earpiece no longer in the picker — ACCEPTED TRADE-OFF

`.defaultToSpeaker` hides the receiver from the native route picker.
Speaker / AirPods / hearing aids remain. Revisit only if a user
explicitly needs earpiece output.

---

## Bug fixes (round 4 — cold-launch USB still missing)

**Symptom:** even with polling, a persisted USB mic showed "— missing"
after cold launch and never self-healed. Curious workaround: merely
opening and CLOSING the output route picker (no change) made the USB
mic appear and become the current input.

**Root cause — ordering bug in `ensureSessionConfigured`:** the old
sequence was `setCategory → applyPreferredInputIfNeeded → setActive`.
With a persisted USB selection, `applyPreferredInputIfNeeded` THREW
(device not yet enumerated) BEFORE `setActive` ran — so the session
was never activated at launch, and USB enumeration (which requires an
active session) never started. The polling timer only called
`applyPreferredInputIfNeeded`, never retried activation. Presenting
AVRoutePickerView makes the *system* activate the session — hence the
"magic fix" on picker dismissal, followed by our route-change handler
pinning the newly-enumerated device.

**Fix:** activate BEFORE applying the preferred input in
`ensureSessionConfigured`; polling ticks also retry activation if it
hasn't stuck; polling extended to 10 s and also runs on every
foregrounding.

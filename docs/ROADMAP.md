# Roadmap — Next-Iteration Review & Plan

This document captures a forward-looking review of AnyListen after the
round-3/4 audio work (direct-connection loopback, cold-launch USB fix,
input-switch freeze fix) landed. The core audio path is considered done and
is governed by a single hard constraint that shapes everything below.

## The hard constraint: latency parity with Live Listen

> **AnyListen must not add perceptible latency beyond the
> Bluetooth-to-hearing-aid floor.** The primary user is someone wearing
> hearing-aid/headset output who is *within microphone range of the same
> hearing aids* (e.g. a passenger in a car). Any app-added delay produces a
> distinct second "echo" alongside the direct acoustic path. Latency has
> been validated on-device by running AnyListen and Live Listen
> **simultaneously** and confirming no audible echo/double — i.e. the two
> paths have matched latency.

The current implementation achieves this with a single graph edge:

```
inputNode ──► mainMixerNode ──► <output route>
```

App-added latency is essentially one I/O buffer (~5 ms, the
`setPreferredIOBufferDuration(0.005)` hint) and nothing else. **Any change
that inserts processing between `inputNode` and `mainMixerNode` is out of
scope.** The following "nice to have" ideas are **rejected** because each
adds latency:

- ❌ **Peak / brick-wall limiter (`AVAudioUnitEffect`,
  `kAudioUnitSubType_PeakLimiter`).** A true peak limiter is *look-ahead* by
  construction — it requires a delay buffer (a few ms) to catch transients
  without distortion — and any AU effect node in the graph adds its own
  render buffering on top of the ~5 ms I/O buffer. Both costs are real and
  unavoidable. **This is the most-requested safety feature and it is
  explicitly rejected on latency grounds.**
- ❌ **Tap-based safety clip / level metering.** Re-introduces the
  1024-frame capture buffer (~21 ms @ 48 kHz) that was removed in round 3
  specifically for latency. Rejected.
- ❌ **Any `AVAudioUnitEffect` in the chain** (EQ, compressor, noise gate, …).
  Each adds render buffering. Rejected unless a future,
  latency-budget-verified exception is made and re-validated against Live
  Listen.

The **only** loudness/safety lever that costs zero added latency is
`mainMixerNode.outputVolume`, because the mixer already exists in the graph
regardless of its gain setting. The volume slider in P4 uses exactly that.
Hearing-protection against sudden transients, beyond a conservative gain
setting, is left to the hearing aids' own DSP and iOS output protection —
not app-inserted DSP. **After any change that touches the audio path, re-run
the side-by-side Live Listen latency check.**

## Prioritized plan

> **Status (July 2026):** P1, P3, and P4 have **shipped** (P1 without the
> "allow same-device loopback" override — the guard is always on; P4's
> slider lives in the Settings sheet). Auto-resume after calls also shipped
> (default **on**, not the "stay stopped" default proposed below). P2 and
> P5 remain open.

### P1 — Same-device loopback guard + first-run guidance
*(cheap, high impact, no latency impact)*

**Status: ✅ Shipped** — and broadened: ANY built-in-speaker route is
blocked (`outputIsBlocked`), not just the iPhone-mic→speaker loopback. The
speaker card shows "Connect headphones", the button reads "Headphones
required". The override toggle was not added. An observed headphone
disconnect shows "X — missing" instead.

**Problem.** iPhone-mic → iPhone-speaker is virtually always unwanted,
causes feedback, and is *the default state when the app opens with no
accessories plugged in* — the worst possible first impression. Today the
Listen button is enabled in this state and merely shows a scary confirm
alert.

**Plan.**
- Add a computed `isDangerousLoopback` on the manager: input portType ==
  `.builtInMic` **and** output portType == `.builtInSpeaker`.
- Disable the Listen button when `isDangerousLoopback &&
  !allowSameDeviceLoopback`.
- Show **constructive** guidance in the listening card instead of the scary
  alert: "Connect headphones or a Bluetooth hearing aid to begin." This
  turns the worst first-run into onboarding.
- Bury "Allow same-device loopback (warning: feedback)" in Settings, default
  off, made deliberately hard to enable (e.g. a typed confirm or double-tap).
- Keep the native input `Menu` and `AVRoutePickerView` untouched — no picker
  rewrite, no loss of native iOS chrome. The guard lives on the action
  button only.

**Latency impact:** none. **Files:** `AudioEngineManager.swift`,
`ContentView.swift`, new `SettingsView.swift`.

### P2 — Mix with other audio (`.mixWithOthers`)
*(the "do notifications/music stop the loopback?" question; no latency impact expected)*

**Problem.** Today the session is `.playAndRecord` with **no
`.mixWithOthers`**, and it is active for the app's entire lifetime
(activated at launch when permission is granted; `stop()` never
deactivates). Net effect: from the moment AnyListen is opened with mic
permission granted until it is killed, **every other audio source on the
phone is paused** — music, podcasts, YouTube, navigation prompts — even
when not listening. For a "set and forget" hearing-aid app this is the
opposite of the desired behavior, and it is the root of the
"do notifications/music stop the loopback?" question.

**Plan.**
- Make `.mixWithOthers` the default in `sessionCategoryOptions`.
- Expose a setting **"Pause other audio while listening (exclusive mode)"**,
  default **off**. When off, other audio keeps playing alongside the
  loopback (notification sounds briefly duck, never interrupt; calls still
  interrupt via `AVAudioSessionInterruption`).
- With mix on, the "should music/YouTube stop the loopback?" decision becomes
  moot — they don't, by default, which matches the stated preference.

**Latency impact:** none expected — our render path is unchanged. **Must be
re-verified on-device against Live Listen** (mix + playAndRecord is
well-supported, but confirm USB enumeration and the route-picker output
choice still behave and that latency parity holds). **Files:**
`AudioEngineManager.swift`, `SettingsView.swift`.

### P3 — Auto-listen ("lock on")
*(the best "set and forget" win; no latency impact)*

**Status: ✅ Shipped** — "Start listening automatically" in Settings,
persisted, evaluated on route changes / foregrounding / enumeration ticks.
The cold-background caveat below still applies.

**Problem.** Users who want the mic on whenever their gear is connected must
tap LISTEN every time. Unplugging the USB mic should mute; plugging it back
in should resume.

**Plan.**
- New persisted `@AppStorage("autoListenEnabled") var autoListenEnabled`.
- An `evaluateAutoListen()` that starts listening when (preferred or
  Automatic input is available) **and** (current output is non-built-in)
  **and** `!isRunning`; stops when either goes missing.
- Call it from `handleRouteChange`, `handleDidBecomeActive`, and each
  enumeration-poll tick (so a late-enumerating USB mic self-starts).
- Reuses existing state: `selectedInputID` / Automatic ranking for the mic,
  `lastExternalOutputID` for the hearing aids. A single toggle — no separate
  "designate preferred devices" UI needed.

**Honest limitation — cold background auto-start is not reliable on iOS.**
When the engine is not producing audio, iOS suspends a backgrounded
`audio`-mode app, so a route-change notification from re-plugging the USB
mic may not be delivered until the app is next foregrounded. Therefore:
- Foreground auto-start on plug-in → works. ✅
- Already-listening → unplug stops, replug resumes (the app stayed awake
  because it was producing audio). ✅
- App suspended in background for a while → replug → *probably will not
  wake it*. ⚠️

This still matches the "unplug the USB receiver to mute, keep/open the app
to unmute" workflow. Do **not** promise cold-background resurrection in
copy. (The only reliable lever for true cold-background auto-start is
keeping a silent engine running — a battery cost best avoided for v1.)

**Latency impact:** none. **Files:** `AudioEngineManager.swift`,
`SettingsView.swift`.

### P4 — Monitor volume slider (`mainMixerNode.outputVolume`)
*(the zero-latency loudness + hearing-protection lever)*

**Status: ✅ Shipped** — slider in the Settings sheet, persisted, clamped
to 0.0–1.0 (attenuation only, no boost).

**Problem.** Pass-through gain is fixed at 1.0 (REVIEW H1). For high-gain
USB preamps into BT hearing aids this can be uncomfortably loud; the user
has no way to set loopback level relative to other audio.

**Plan.**
- Expose `mainMixerNode.outputVolume` as `@Published var monitorVolume:
  Float`, default **1.0**, persisted. Clamp `0.0...1.0` (**no boost** —
  boost risks clipping and, for hearing-aid users, sudden-loud transients).
- Slim slider in the listening card (visible while listening) or in
  Settings.
- Frame it honestly: it is a *gain on top of system volume* — the hardware
  buttons still control the hearing aids' absolute level. So it is really
  "loopback loudness relative to other audio," which becomes most useful
  once mix mode (P2) lets music play alongside.

**Latency impact:** **zero** — the mixer is already in the graph;
`outputVolume` is a scalar gain applied in the mixer's render, costing no
extra buffer. This is the *only* hearing-protection lever that preserves
Live Listen parity. **Files:** `AudioEngineManager.swift`,
`ContentView.swift` / `SettingsView.swift`.

### P5 — Keep the engine alive across toggles
*(latency-neutral UX polish; unblocks comfortable auto-listen)*

**Problem.** Every `stop()` tears down `AVAudioEngine` and every `start()`
rebuilds it (REVIEW M1, still true). With auto-listen (P3), unplug/replug
toggles get frequent, and the 50–150 ms glitch per toggle is noticeable.

**Plan.**
- Keep `audioEngine` alive across stops; `engine.pause()` to stop,
  `engine.start()` to resume.
- Rebuild **only** when the input format actually changed (e.g. after an
  input switch while stopped) — same rebuild path as today, so no regression.

**Latency impact:** **neutral** — `pause`/`start` preserves the graph and
buffer sizes; the ~5 ms I/O floor is unchanged. **Files:**
`AudioEngineManager.swift`.

## Settings surface

A gear icon in the header opening a `.sheet` with a `Form`. Proposed
contents (defaults chosen for the hearing-aid daily-driver):

| Setting | Default | Why |
|---------|---------|-----|
| Auto-start when my mic and headphones are connected | off | P3 — "lock on" |
| Other audio while listening: Mix / Exclusive | Mix | P2 — don't trample music/videos |
| After a phone call ends: Stay stopped / Resume | Stay stopped | today's behavior, made explicit |
| Monitor volume | 1.0 (max) | P4 — zero-latency gain |
| Allow same-device loopback (warning: feedback) | off, hard to enable | P1 |

Notifications need no setting: with mix mode on (default), notification
sounds duck briefly and never stop the loopback — matching the stated
preference. Calls always interrupt via the system interruption API; the
"after a call" setting above covers recovery.

"Excluded outputs" (a manual never-route-here list) is **deferred** — the
same-device guard (P1) plus mix mode (P2) cover the realistic dangers, and a
manual exclude list adds UI weight for little gain.

## Polish (no latency impact)

- **Accessibility — important for this audience.** The big Listen button has
  no `accessibilityLabel` (REVIEW L2); VoiceOver says only "Button." Add
  `.accessibilityLabel(isRunning ? "Stop listening" : "Start listening")`,
  `.accessibilityHint`, `.accessibilityValue(isRunning ? "on" : "off")`, and
  post `UIAccessibility.post(.announcement, …)` on state changes. Label the
  mic/speaker rows as combined elements. Hearing-aid users have non-trivial
  VoiceOver use.
- **Subtle "alive" pulse.** A gentle ~1.2 s opacity pulse on the green circle
  while running (respect `accessibilityReduceMotion`) — the REVIEW M7 "no
  animation when running" gap. Keep it subtle.
- **First-run / empty state.** Tied to P1: when nothing external is
  connected, the screen should read as "plug in your mic and headphones,"
  not as a ready-to-feedback Listen button.

## Deferred: iPad landscape / multitasking

The app is portrait-only on all devices, so `UIRequiresFullScreen = true`
is set (App Store upload validation rejects iPad apps that restrict
orientations without opting out of multitasking). **This is a stopgap.**
The layout is a simple scrolling stack of cards — there is no fundamental
reason it can't support landscape on iPad (side-by-side cards or a
max-width column would both work), and multitasking (Split View) suits the
"appliance" use case. When that lands: remove `UIRequiresFullScreen` from
`project.yml` **and** `AnyListen/Info.plist`, add the landscape
orientations, and re-capture the 13″ iPad screenshots in the supported
orientations.

## Doc / hygiene follow-ups

- `docs/ARCHITECTURE.md` and `docs/AUDIO_PIPELINE.md` previously described
  the **tap + `AVAudioPlayerNode`** pipeline; both are corrected to the
  direct-connection design in this round.
- `docs/UI.md` previously referenced a monolithic `settingsCard` /
  `statusArea`; corrected to the three-card layout in this round.
- `docs/REVIEW.md` H3 / M2 / M3 / L5 are now marked resolved, M5 marked N/A
  (this round). Since then, H1 (→ P4), H2 (AppIcon), and L1 (string
  catalogs) have also been resolved. Still-open items worth picking up:
  M1 (→ P5), M4, M6, M7, L2 (partial), L3, L4, L6–L11.

## Suggested implementation order

1. **P1** — same-device loopback guard + first-run guidance + Settings shell
   (cheapest high-impact pair).
2. **P2** — mix mode (re-verify latency on device).
3. **P3** — auto-listen.
4. **P4** — monitor volume slider.
5. **P5** — keep engine alive across toggles (do alongside/after P3).
6. Polish: accessibility labels, alive pulse, empty state.

Each step is contained to `AudioEngineManager.swift` / `ContentView.swift`
plus the new `SettingsView.swift` and a few `@AppStorage` keys. **Re-run the
Live Listen side-by-side latency check after every step that touches the
audio path** (P2, P4, P5; P1 and P3 are logic-only and cannot affect
latency).

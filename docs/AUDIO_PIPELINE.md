# Audio Pipeline

All audio work lives in `AudioEngineManager.swift`. This document pulls the
moving parts into one place and explains the *why* behind the trickiest
choices, because Core Audio is full of landmines and the comments in code
can only say so much.

## Audio session lifecycle

Session work is centralized in `ensureSessionConfigured()`, which is
deliberately *lazy* — each step runs only when needed:

```swift
if category-or-options changed (or never configured) {
    try session.setCategory(.playAndRecord, mode: .default,
                            options: sessionCategoryOptions)   // (fallback: deactivate → set)
    try session.setPreferredIOBufferDuration(0.005)
}
try applyPreferredInputIfNeeded()          // pin selected / automatic-best input
if !sessionIsActive {
    try session.setActive(true)            // activation = what enumerates USB devices
}
```

Key properties:

1. **No routine deactivation.** Deactivating the session wipes output
   overrides (the user's route-picker choices) and de-enumerates USB.
   The session is configured once and kept active for the app's
   lifetime; only a *category options* change (Bluetooth-ness of the
   selected input flipping) can trigger a re-set, with a
   deactivate → set → reactivate fallback if iOS refuses the
   while-active transition.
2. **5 ms target I/O buffer** for low-latency monitoring.
3. **Preferred input is pinned explicitly** — in Automatic mode, the
   best-ranked available input (external mics beat built-in), not
   `nil`-and-pray.
4. **Activation is what makes USB devices enumerate** into
   `availableInputs` (and it needs mic permission). Hence: activate at
   launch if permission is already granted.

The function is wrapped in `isApplyingAudioSessionChange = true … defer {
… = false }` plus a 2.5 s silence window, which `handleRouteChange`
checks to avoid reacting to self-induced notifications.

## Bluetooth: the clever bit

When iOS HFP/HSP Bluetooth headsets (typical AirPods in call mode, or any
"phone" profile BT headset) connect, they aggressively request ownership
of **both** the input *and* the output. If your user wants to feed audio
from a USB interface into a Bluetooth speaker, iOS will, by default, hand
the input to the BT device too — which means you lose USB.

The app sidesteps this by making `.allowBluetooth` (HFP) **opt-in
only** — it is included solely when the user has explicitly selected a
Bluetooth port as their input. In every other case (including
Automatic), the options are `[.allowBluetoothA2DP, .defaultToSpeaker]`:
A2DP keeps AirPods / hearing aids available as **output**, HFP keeps
its hands off the **input**:

```swift
private var sessionCategoryOptions: AVAudioSession.CategoryOptions {
    if let sid = selectedInputID,
       let port = AVAudioSession.sharedInstance().availableInputs?.first(where: { $0.uid == sid }),
       Self.isBluetoothPort(port.portType) {
        return [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
    }
    return [.allowBluetoothA2DP, .defaultToSpeaker]
}
```

(The original implementation returned `[.allowBluetooth,
.allowBluetoothA2DP]` for Automatic mode, which is what let iOS
silently promote an AirPods HFP mic over USB while the UI reported the
built-in mic — the "fake AirPods input" bug.)

Trade-offs:

- **AirPods in normal "music" mode (`A2DP`)** are unaffected: they remain
  available as output.
- **AirPods / BT headsets in call mode (`HFP`)** are no longer allowed to
  bid for the input.
- **A user who *does* want their BT headset microphone** should select
  the BT input explicitly — the manager keeps `.allowBluetooth` in that
  case.

This is the keystone of the app's "feel like routing an input to an
output" experience. If you ever refactor this, do it conservatively.

## Engine wiring (direct connection, low latency)

```swift
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let format = inputNode.inputFormat(forBus: 0)
engine.connect(inputNode, to: engine.mainMixerNode, format: format)
```

That is the entire audio path. The input node is connected **directly**
to the main mixer; the mixer handles any sample-rate conversion to the
output route (e.g. USB mic 48 kHz → AirPods A2DP).

### Why not tap + player? Latency.

The original loopback used `installTap(bufferSize: 1024)` +
`AVAudioPlayerNode.scheduleBuffer`. On-device measurement showed it
audibly slower than Live Listen (~25% extra latency on a finger-snap):

- A 1024-frame tap buffer at 48 kHz is **21.3 ms** of capture-side
  buffering before any audio moves at all.
- The player node adds scheduling jitter on top (buffers queue between
  the tap's delivery cadence and the player's render cadence).

The direct connection costs roughly **one I/O buffer (~5 ms)** — the
session's `setPreferredIOBufferDuration(0.005)` hint is essentially the
whole app-added latency now. Bonus removals: no `removeTap`-while-
running (a freeze candidate) and no real-time-thread callback at all.

Trade-off: we lose per-buffer access (no level metering / processing
without re-adding a tap). A future gain control can still use
`mainMixerNode.outputVolume` — free, per-sample, zero added latency.

- **Format comes from `inputNode.inputFormat(forBus: 0)`**, never
  hard-coded — keeps every device iOS exposes compatible.
- The engine is rebuilt (never the session) when the input format may
  have changed — see route-change handling below.

## Built-in output: `.defaultToSpeaker`, never an override

`.playAndRecord` **without** `.defaultToSpeaker` routes built-in output
to the *receiver* (the quiet top earpiece) by default. The first
iteration of this app compensated with
`overrideOutputAudioPort(.speaker)`, which caused two real bugs:

1. It snapped deliberate earpiece selections back to the speaker.
2. Session deactivation **wipes output overrides** — and the engine
   was being rebuilt (with a full deactivate → reactivate cycle) on
   route changes, so every output choice the user made in the native
   route picker was silently destroyed.

Current approach:

- `.defaultToSpeaker` is a permanent category option, so built-in
  output defaults to the loud speaker — the sane default for routing
  an external mic.
- `overrideOutputAudioPort` is **never called**. The native
  `AVRoutePickerView` owns output selection, including the
  Speaker ↔ Earpiece toggle, and its choices persist because
- the session is **never deactivated while the app is alive** (only as
  a fallback when a category change refuses to apply while active).

## Session activation & USB enumeration

USB audio devices do **not** appear in `availableInputs` until the
session is **activated** (`setActive(true)`) — setting the category
alone is not enough, and activation requires mic permission to be
already granted. Consequences:

- At launch, if permission is `.authorized`, the app activates the
  session immediately (`ensureSessionConfigured`). This takes audio
  focus (other apps pause) — acceptable for a mic router.
- If permission is undetermined, only the category is primed (no
  launch-time prompt); activation happens inside the LISTEN →
  permission-grant flow.
- Once activated, the session stays active for the app's lifetime so
  USB stays enumerated and route-picker output choices persist.
- A `UIApplication.didBecomeActiveNotification` handler re-activates
  if an interruption (phone call, Siri) tore the session down.

### Enumeration is asynchronous — poll

Activation *starts* USB enumeration; it does not finish it. On tested
hardware (RØDE Wireless ME RX) the device appeared in `availableInputs`
**seconds** after activation, and its arrival fired **no** route-change
notification. Without compensation, a persisted USB selection shows
"— missing" at launch until the user pokes the menu.

`startEnumerationPolling()` runs a 0.5 s × 12-tick (6 s) timer after
launch-activation, after every start, and after re-activation on
foregrounding. Each tick re-queries `availableInputs`, refreshes the
UI, and re-pins the preferred input if a better one appeared — so a
late-enumerating USB mic self-heals automatically.

## Permission flow

```swift
microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
…
AVAudioSession.sharedInstance().requestRecordPermission { … }
```

`beginListening()` short-circuits to the permission flow if status is
anything other than `.authorized`. After grant, it falls through to
`start()`. After a refusal, it sets `errorMessage`.

The choice of `AVCaptureDevice.authorizationStatus(for: .audio)` over
`AVAudioSession.sharedInstance().recordPermission` is purely stylistic —
they're coordinated by AVFoundation so it doesn't matter functionally.

## Notification handling

Five publishers, all `.receive(on: .main)`:

| Notification | Handler | Effect |
|--------------|---------|--------|
| `AVAudioSession.routeChangeNotification` | `handleRouteChange` | Refresh UI; re-pick automatic input; **stop listening** if the route signature actually changed while running, or if the selected input vanished. |
| `AVAudioSession.mediaServicesWereResetNotification` | `handleMediaServicesReset` | Tear down, clear session flags, set "system reset" message. |
| `AVAudioEngineConfigurationChange` | `handleEngineConfigurationChange` | While running (and not silenced): rebuild the **engine only** — never the session — so format shifts don't destroy output overrides. |
| `AVAudioSession.interruptionNotification` | `handleInterruption` | `.began` → stop listening cleanly (phone call, Siri). `.ended` → mark session inactive; never auto-resume. |
| `UIApplication.didBecomeActiveNotification` | `handleDidBecomeActive` | Re-check permission (Settings changes), re-activate if needed, refresh routes. |

### Route changes: stop-policy via route signature

Reason codes (`oldDeviceUnavailable`, `.override`, …) are too noisy to
trust — iOS fires them for self-induced changes, logical-vs-physical
port flips, and category chatter. Instead, the handler compares a
**route signature** (`currentInputUID | outputUIDs`) from before and
after the notification:

- **Selected input vanished** (while running) → stop with "Selected
  input was disconnected." This check runs *even inside the silence
  window* — a yanked USB mic is never ignored.
- **Signature changed** (while running) → stop with "Audio route
  changed. Tap LISTEN to resume." User-initiated output swaps,
  AirPods connecting, headphone plug/unplug all land here. Per
  product decision we stop rather than auto-rebuild; the user taps
  LISTEN to resume on the new route, and the new route's output
  choice survives because the session was never deactivated.
- **Signature unchanged** → nothing material happened; just refresh
  UI. This absorbs `.categoryChange` noise for free.

### The silence window

`ensureSessionConfigured()` and self-induced input re-pins set
`silenceRouteChangesUntil = now + 2.5 s`. Within the window the handler
still refreshes UI state and absorbs the new route signature (so the
baseline is never stale), but does not stop listening — that would
kill every start, since our own configuration fires a burst of
notifications.

### In-app input changes also stop (and why)

Selecting an input from the in-app menu while running stops listening
("Input changed. Tap LISTEN to resume."), matching the output-change
policy. Beyond UX consistency, this eliminated a real freeze: the old
"teardown engine → reconfigure session → rebuild engine" sequence ran
synchronously on the main thread while a USB route switch was in
flight, which could deadlock the audio server and wedge the app.
Stopping first means the session is only ever reconfigured while no
engine is alive.

## State → UI projection

`updateAudioRoutes()` is the single place that maps AVAudioSession
state to display strings:

- Resolves `selectedInputID` against the live `availableInputs` to
  decide between "connected", "missing", or "fall back to first
  current route input".
- Maps port types to human categories ("Built-in", "USB", "Bluetooth",
  "Headset", "Line In") via `readableInputType`.
- Maps output ports to friendly strings like "iPhone Speaker",
  "<name> (Bluetooth)", via `readableOutputName`.
- Sets `outputMayCauseFeedback = (firstOutput.portType == .builtInSpeaker)`.

UI runs `updateAudioRoutes()` from `onAppear` and from the manager's
own init.

## Threading model summary

- **Main thread**: AVAudioSession calls, `@Published` writes, `UserDefaults`.
- **Real-time audio thread (`AVAudioEngine.inputNode` tap)**: reads
  captured buffers and calls `AVAudioPlayerNode.scheduleBuffer`. No
  state writes, no allocations beyond the `AVAudioPCMBuffer` itself
  (which is supplied by the engine).
- **Cross-thread contract**: never hold a strong reference to the
  `playerNode` outside the engine. `teardownEngine` is the only
  place that breaks the contract, and it does so behind
  `removeTap → engine.stop`, so the audio thread either runs the guard
  and returns or the buffer is dropped silently.

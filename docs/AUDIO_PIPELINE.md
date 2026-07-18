# Audio Pipeline

All audio work lives in `AudioEngineManager.swift`. This document pulls the
moving parts into one place and explains the *why* behind the trickiest
choices, because Core Audio is full of landmines and the comments in code
can only say so much.

## Audio session lifecycle

A single helper, `configureAudioSessionForCurrentSelection()`, centralizes
session work:

```swift
try? session.setActive(false, options: .notifyOthersOnDeactivation)   // 1
try session.setCategory(.playAndRecord, mode: .default,                 // 2
                        options: sessionCategoryOptions)
try session.setPreferredIOBufferDuration(0.005)                        // 3
try applyPreferredInputIfNeeded(forceActive: false)                    // 4
try session.setActive(true, options: .notifyOthersOnDeactivation)      // 5
```

Steps 1–5 in plain English:

1. **Deactivate first.** Some category/preferred-input changes are ignored
   while the session is active on older iOS versions.
2. **Set the category** *before* activation. `sessionCategoryOptions` is
   derived from the selection — see *Bluetooth handling* below.
3. **5 ms target buffer** for low-latency monitoring.
4. **Set the preferred input** before activation. iOS is more likely to
   honor `setPreferredInput` if it's done before the session goes active.
5. **Activate.**

The function is wrapped in `isApplyingAudioSessionChange = true … defer {
… = false }`, which `handleRouteChange` checks to ignore self-induced
notifications.

## Bluetooth: the clever bit

When iOS HFP/HSP Bluetooth headsets (typical AirPods in call mode, or any
"phone" profile BT headset) connect, they aggressively request ownership
of **both** the input *and* the output. If your user wants to feed audio
from a USB interface into a Bluetooth speaker, iOS will, by default, hand
the input to the BT device too — which means you lose USB.

The app sidesteps this by stripping `.allowBluetooth` from the
session-category options whenever the user picks a **non-Bluetooth**
input:

```swift
private var sessionCategoryOptions: AVAudioSession.CategoryOptions {
    guard let sid = selectedInputID else {
        return [.allowBluetooth, .allowBluetoothA2DP]
    }
    let session = AVAudioSession.sharedInstance()
    if let port = (session.availableInputs ?? []).first(where: { $0.uid == sid }) {
        let isBluetooth: Bool = {
            switch port.portType {
            case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return true
            default: return false
            }
        }()
        if !isBluetooth {
            // USB / built-in / headset / line-in: keep A2DP for output,
            // drop HFP so AirPods stay output-only.
            return [.allowBluetoothA2DP]
        }
    }
    return [.allowBluetooth, .allowBluetoothA2DP]
}
```

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

## Engine wiring

```swift
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let inputFormat = inputNode.inputFormat(forBus: 0)

let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: inputFormat)

inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak player] buffer, _ in
    guard let player = player, player.isPlaying else { return }
    player.scheduleBuffer(buffer)
}
```

Notes:

- **Tap on the engine's `inputNode`** rather than wiring via `connect`.
  `connect` would make the engine assume output-side routing; a tap gives
  full control over what gets buffered and when.
- **Format comes from `inputNode.inputFormat(forBus: 0)`**, not from a
  hard-coded sample rate. This keeps us compatible with every device that
  iOS exposes.
- **Buffer size 1024 at the engine level**, separate from the session's
  5 ms I/O hint. These are tied: a 5 ms @ 48 kHz is ~240 frames; the tap
  sees multiples of that.
- **Player is re-attached on every restart.** We could keep the engine
  alive across start/stop cycles to make toggling snappier. See
  [`REVIEW.md`](REVIEW.md) for that note.

## Output override

`applyOutputOverrideIfNeeded()` runs after the engine starts:

```swift
let outputs = session.currentRoute.outputs
let shouldOverride = outputs.contains { output in
    output.portType == .builtInSpeaker || output.portType == .builtInReceiver
}
if shouldOverride {
    try session.overrideOutputAudioPort(.speaker)
}
```

Without this, when the only output is the receiver (top earpiece), iOS
silently routes output there and the user hears nothing useful.
`overrideOutputAudioPort(.speaker)` forces the bottom loudspeaker.

This is harmless for headphones/Bluetooth/USB — the override only fires
when the only output *is* the built-in one.

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

Three publishers, all `.receive(on: .main)`:

| Notification | Handler | Effect |
|--------------|---------|--------|
| `AVAudioSession.routeChangeNotification` | `handleRouteChange` | Refreshes inputs; auto-stops if the selected input disappears. Suppressed for 2 s after `start()` to avoid reacting to its own session reconfiguration. |
| `AVAudioSession.mediaServicesWereResetNotification` | `handleMediaServicesReset` | Tear everything down, set a "system reset" error. |
| `AVAudioEngineConfigurationChange` | `handleEngineConfigurationChange` | Refresh inputs only. *Does not* stop the engine — the comment in code spells out why: "Engine configuration notifications can be emitted during normal startup." |

### The 2-second debounce

`start()` sets `ignoreRouteChangesUntil = Date().addingTimeInterval(2.0)`.
The basic idea: re-activating the session can emit
`categoryChange`/`overrideChange` route-change notifications, and iOS
sometimes emits `oldDeviceUnavailable` when the input / output flips
between logical and physical ports even though nothing actually
disconnected. Without the debounce, those would race against our
deliberate state.

Two seconds is empirically enough on tested devices but is a magic
number. If you ever see flapping behavior (listen toggles off
immediately after starting), increase it.

### `oldDeviceUnavailable`

This is the legitimate "unplugged" signal, so it's *not* debounced:

```swift
case .oldDeviceUnavailable:
    if selectedInputIsMissing {
        if isRunning {
            stopForSettingsChange()
            errorMessage = "Selected input was disconnected."
        }
    }
```

`selectedInputIsMissing` is set in `applyPreferredInputIfNeeded` when
the previously persisted `uid` is no longer in `availableInputs`.
Because we *also* update routes on every notification, the UI shows
"<name> — missing" in red before the auto-stop fires.

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
  `playerNode` outside the engine. `teardownAudioEngine` is the only
  place that breaks the contract, and it does so behind
  `removeTap → engine.stop`, so the audio thread either runs the guard
  and returns or the buffer is dropped silently.

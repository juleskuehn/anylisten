# Architecture

AnyListen is small enough that "architecture" mostly means understanding the
three Swift files and how state flows between them. This document covers both
the static structure and the runtime data flow.

## Module layout

```
┌─────────────────────────────────────────────────────────────────┐
│ SwiftUI App                                                      │
│                                                                  │
│  AnyListenApp ─────► ContentView ─────► AudioEngineManager       │
│                                          │                       │
│                                          ▼                       │
│                                    AVAudioEngine                 │
│                                    inputNode ──► mainMixerNode   │
│                                          │                       │
│                                          ▼                       │
│                                    AVAudioSession                │
│                                    • category / options          │
│                                    • preferred input             │
│                                    • route changes               │
│                                                                  │
│  ContentView ─────► AudioRoutePicker ───► AVRoutePickerView      │
└─────────────────────────────────────────────────────────────────┘
```

Three Swift files, three responsibilities:

| File | Responsibility |
|------|----------------|
| `AnyListenApp.swift` | Entry point. Creates a single `WindowGroup` whose root is `ContentView`. Nothing else. |
| `ContentView.swift` | All user-facing UI. Owns the single `AudioEngineManager` via `@StateObject` and reads its `@Published` state to render. Owns one piece of *view-local* state — the speaker-feedback alert. |
| `AudioEngineManager.swift` | All audio logic. The `AVAudioEngine`, the `AVAudioSession` config, route-change listening, permission, persistence. Publishes state for the view layer. |
| `AudioRoutePicker.swift` | Thin SwiftUI bridge around `AVRoutePickerView`. Stretches Apple's internal button to fill its parent frame so it sits cleanly inside our rounded "Speaker or Headphones" tile. |

There is no separate `ViewModel` layer — `AudioEngineManager` plays that
role. This is a deliberate, idiomatic-SwiftUI trade-off for a single-screen
app.

## State model

### Persistent state (`UserDefaults`)

| Key | Type | Meaning |
|-----|------|---------|
| `AnyListen.selectedInputID` | `String?` | The `uid` of the AVAudioSession port the user picked as input. |
| `AnyListen.selectedInputName` | `String?` | Display name; used in error messages if the input later disconnects. |
| `AnyListen.lastExternalInputID` | `String?` | `uid` of the most recent non-built-in input (chosen or auto-upgraded). |
| `AnyListen.lastExternalInputName` | `String?` | Its display name; used for the "— missing" suffix on disconnect. |
| `AnyListen.lastExternalOutputID` | `String?` | `uid` of the most recent non-built-in output. |
| `AnyListen.lastExternalOutputName` | `String?` | Its display name; used for the "— missing" suffix on disconnect. |

The selected **output** is *not* persisted by the app — iOS owns the audio
routing graph and remembers AirPods/Bluetooth pairings itself. The
`lastExternal*` keys are not a user "selection"; they are a memory of what
iOS last routed to, used only to flag a missing device instead of silently
accepting a fallback to built-in hardware.

### Published state (`AudioEngineManager`)

| Property | Type | Purpose |
|----------|------|---------|
| `isRunning` | `Bool` | Whether the engine is started (audio is flowing). |
| `availableInputs` | `[AudioInputDevice]` | Inputs iOS exposes via `availableInputs`. |
| `currentInputName` | `String` | Pretty name for display, including "— missing" suffix. |
| `currentOutputName` | `String` | Pretty name for display (e.g. "AirPods Pro (Bluetooth)"). |
| `selectedInputID` / `selectedInputName` | `String?` | Mirror of `UserDefaults`. |
| `selectedInputIsMissing` | `Bool` | `true` when the previously selected input is no longer in `availableInputs`. |
| `outputIsMissing` | `Bool` | `true` when the previously routed external output was OBSERVED going away (`.oldDeviceUnavailable` while routed to it) and iOS fell back to the speaker. Shown as "X — missing". |
| `outputIsBlocked` | `Bool` | `true` when the current route output is the built-in speaker (and not in the missing state). Listening is blocked; the view shows "Connect headphones" and disables Listen. |
| `lastExternalInputID` / `lastExternalInputName` | `String?` | Most recent non-built-in input (chosen or auto-upgraded); persisted so a disconnect shows "missing" instead of a silent fallback. |
| `lastExternalOutputID` / `lastExternalOutputName` | `String?` | Most recent non-built-in output; the name feeds the "— missing" text when an observed loss occurs. |
| `errorMessage` | `String?` | Internal stop/failure reason (route changed, disconnected, engine failure). Currently **not rendered** in the UI — state is communicated via the orange row text and the disabled-button label. |
| `microphonePermissionStatus` | `AVAuthorizationStatus` | Drives permission UX. |

### View-local state

`ContentView` holds exactly one piece of state outside the manager:
`@State private var showSettings`, which presents the Settings sheet.

## Lifecycle

1. **`AnyListenApp.init`** — runs once, builds the `Scene`.
2. **`ContentView.onAppear`** — triggers
   `audioManager.updateAudioRoutes()` to populate the input list before first
   render paint. (The manager's own `init` also calls it.)
3. **`AudioEngineManager.init`** — loads persisted selection, checks mic
   permission, subscribes to five `NotificationCenter` publishers (route
   change, media services reset, engine configuration change, audio session
   interruption, app did-become-active) on the main queue, and — if mic
   permission is already granted — activates the session immediately so USB
   inputs begin enumerating (then polls, because USB enumeration is
   asynchronous and fires no usable notification).
4. **User taps LISTEN** → enabled only when the route is listenable: no
   missing input, no missing output, and the output is not the built-in
   speaker (`outputIsBlocked`). Otherwise the button is disabled and its
   label says what's needed ("Headphones required" / "Microphone
   required"). A tap calls `audioManager.beginListening()`.
5. **`beginListening`** — short-circuits to the permission flow if needed; on
   grant, calls `start()`.
6. **`start`** — ensures the session is configured (category + preferred
   input + activate, each only if stale) → rebuilds the engine → connects
   `inputNode` directly to `mainMixerNode` → starts the engine. No tap, no
   player node, no output override.
7. Audio runs. Route-change notifications passively update the displayed
   input/output lists and may auto-stop if the selected input disappears or
   the route signature changes.
8. **User taps STOP** → `stop()` → `teardownEngine()` → re-route queries.
   The session is intentionally left active (keeps USB enumerated and
   preserves the route-picker output choice).
9. **Input change mid-run** (`selectInput`, `clearSelectedInput`) → tear
   down the engine → reconfigure the session → **stop with a "Tap LISTEN to
   resume" message** (no auto-restart; matching the output-change policy and
   avoiding a reconfigure-while-running deadlock).

## Threading

- All **`@Published` mutations and `UserDefaults` access** happen on the main
  queue. The `NotificationCenter` publishers `.receive(on: DispatchQueue.main)`
  before `.sink`, so handler entry is on main.
- Permission completion handlers
  (`AVAudioApplication.requestRecordPermission`) are dispatched to `.main`
  before mutating state.

Because the loopback is a **direct `inputNode → mainMixerNode` connection**
with no tap and no player node, the app has **no real-time audio thread of
its own** — all rendering happens inside `AVAudioEngine`'s graph. There is
no `scheduleBuffer` callback, no `removeTap`, and no cross-thread reference
to manage. `teardownEngine()` is simply `audioEngine?.stop()` then
`audioEngine = nil`. This is a deliberate latency and correctness win over
the earlier tap + `AVAudioPlayerNode` design (see
[`AUDIO_PIPELINE.md`](AUDIO_PIPELINE.md)).

## Audio routing flow (logical view)

```
            ┌──────────────────────────────────────┐
User mic ──►│  AVAudioEngine.inputNode             │
            │      format = inputNode format       │
            │      (no tap, no capture buffer)     │
            └────────────────┬─────────────────────┘
                             │  direct graph connection
                             │  (no app real-time thread)
                             ▼
            ┌──────────────────────────────────────┐
            │  mainMixerNode                       │
            │  (outputVolume = 1.0 — not exposed)  │
            │  (sample-rate conversion to output)  │
            └────────────────┬─────────────────────┘
                             │
                             ▼
                AVAudioSession.currentRoute.outputs
                (speaker / headphones / BT A2DP / USB / …)
```

The five-millisecond `setPreferredIOBufferDuration(0.005)` is what makes the
loopback feel like monitoring. Lower values trade off reliability for
latency; 5 ms is the sweet spot on most iPhones. Because nothing is inserted
between the input node and the mixer, this ~5 ms I/O buffer is essentially
the *entire* app-added latency — which is how the app matches Live Listen.
This is a hard constraint that governs future changes: anything that would
insert processing between `inputNode` and `mainMixerNode` is out of scope
(see [`ROADMAP.md`](ROADMAP.md)).

For the rationale behind category options, output routing, route-change
debouncing, and Bluetooth handling, see
[`AUDIO_PIPELINE.md`](AUDIO_PIPELINE.md).

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
│                                          │           │           │
│                                          │           ▼           │
│                                          │    AVAudioEngine tap   │
│                                          │    → AVAudioPlayerNode │
│                                          │    → mainMixerNode     │
│                                          ▼           │           │
│                                    AVAudioSession   │           │
│                                    • category       │           │
│                                    • preferred I/O  │           │
│                                    • route changes  │           │
│                                                                  │
│  ContentView ─────► AudioRoutePicker ───► AVRoutePickerView      │
└─────────────────────────────────────────────────────────────────┘
```

Three Swift files, three responsibilities:

| File | Responsibility |
|------|----------------|
| `AnyListenApp.swift` | Entry point. Creates a single `WindowGroup` whose root is `ContentView`. Nothing else. |
| `ContentView.swift` | All user-facing UI. Owns the single `AudioEngineManager` via `@StateObject` and reads its `@Published` state to render. Owns one piece of *view-local* state — the speaker-feedback alert. |
| `AudioEngineManager.swift` | All audio logic. The `AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioSession` config, route-change listening, permission, persistence. Publishes state for the view layer. |
| `AudioRoutePicker.swift` | Thin SwiftUI bridge around `AVRoutePickerView`. Stretches Apple's internal button to fill its parent frame so it sits cleanly inside our rounded "Output" tile. |

There is no separate `ViewModel` layer — `AudioEngineManager` plays that
role. This is a deliberate, idiomatic-SwiftUI trade-off for a single-screen
app.

## State model

### Persistent state (`UserDefaults`)

| Key | Type | Meaning |
|-----|------|---------|
| `AnyListen.selectedInputID` | `String?` | The `uid` of the AVAudioSession port the user picked as input. |
| `AnyListen.selectedInputName` | `String?` | Display name; used in error messages if the input later disconnects. |

The selected **output** is *not* persisted. iOS owns the audio routing graph
and remembers AirPods/Bluetooth pairings itself.

### Published state (`AudioEngineManager`)

| Property | Type | Purpose |
|----------|------|---------|
| `isRunning` | `Bool` | Whether the engine is started and the tap is active. |
| `availableInputs` | `[AudioInputDevice]` | Inputs iOS exposes via `availableInputs`. |
| `currentInputName` | `String` | Pretty name for display, including "— missing" suffix. |
| `currentOutputName` | `String` | Pretty name for display (e.g. "AirPods Pro (Bluetooth)"). |
| `selectedInputID` / `selectedInputName` | `String?` | Mirror of `UserDefaults`. |
| `selectedInputIsMissing` | `Bool` | `true` when the previously selected input is no longer in `availableInputs`. |
| `outputMayCauseFeedback` | `Bool` | `true` when the active output is `builtInSpeaker`. |
| `errorMessage` | `String?` | User-visible error string for the status area. |
| `microphonePermissionStatus` | `AVAuthorizationStatus` | Drives permission UX. |

### View-local state

`ContentView` holds exactly one piece of state outside the manager:
`@State private var showSpeakerWarning`. That alert is intentionally a UI
concern and never needs to outlive the screen.

## Lifecycle

1. **`AnyListenApp.init`** — runs once, builds the `Scene`.
2. **`ContentView.onAppear`** — triggers
   `audioManager.updateAudioRoutes()` to populate the input list before first
   render paint. (The manager's own `init` also calls it.)
3. **`AudioEngineManager.init`** — loads persisted selection, checks mic
   permission, subscribes to three `NotificationCenter` publishers (route
   change, media services reset, engine configuration change) on the main
   queue.
4. **User taps LISTEN** → `ContentView` consults
   `outputMayCauseFeedback`:
   - If feedback risk → show the warning alert.
   - Else → `audioManager.beginListening()`.
5. **`beginListening`** — short-circuits to permission flow if needed; on
   grant, calls `start()`.
6. **`start`** — deactivates → reconfigures session (category + preferred
   input + activate) → instantiates the engine → installs tap → starts the
   engine → calls `applyOutputOverrideIfNeeded()`.
7. Audio runs. Route-change notifications passively update the displayed
   input/output lists and may auto-stop if the selected input disappears.
8. **User taps STOP** → `stop()` → `teardownEngine()` → re-route
   queries.
9. **Settings change mid-run** (`selectInput`, `clearSelectedInput`) →
   teardown → reconfigure → auto-restart if previously running.

## Threading

- All **`@Published` mutations and `UserDefaults` access** happen on the main
  queue. The `NotificationCenter` publishers `.receive(on: DispatchQueue.main)`
  before `.sink`, so handler entry is on main.
- The **tap callback** runs on a Core Audio render thread (or a dedicated
  audio queue, depending on the hardware). It captures `[weak player]` and
  reads `player.isPlaying` — both safe and non-retaining.
- Permission completion handlers (`AVAudioSession.requestRecordPermission`)
  are dispatched to `.main` before mutating state.

The shared contract between audio thread and main thread is:
the manager never lets the `player` strong-reference escape; `teardownEngine`
does `engine.inputNode.removeTap(onBus: 0)` then `engine.stop()` while
nil-ling `playerNode`. The audio-thread guard `guard let player = player,
player.isPlaying else { return }` makes any residual fire safe.

## Audio routing flow (logical view)

```
            ┌──────────────────────────────────────┐
User mic ──►│  AVAudioEngine.inputNode (tap)       │
            │      bufferSize = 1024              │
            │      format    = inputNode format   │
            └────────────────┬─────────────────────┘
                             │   scheduleBuffer (Core Audio thread)
                             ▼
            ┌──────────────────────────────────────┐
            │  AVAudioPlayerNode                   │
            └────────────────┬─────────────────────┘
                             │
                             ▼
            ┌──────────────────────────────────────┐
            │  mainMixerNode                       │
            │  (outputVolume = 1.0 — not exposed)  │
            └────────────────┬─────────────────────┘
                             │
                             ▼
                AVAudioSession.currentRoute.outputs
                (speaker / headphones / BT A2DP / USB / …)
```

The five-millisecond `setPreferredIOBufferDuration(0.005)` is what makes
the loopback feel like monitoring. Lower values trade-off reliability for
latency; 5 ms is the sweet spot on most iPhones.

For the rationale behind category options, output override, route-change
debouncing, and Bluetooth handling, see
[`AUDIO_PIPELINE.md`](AUDIO_PIPELINE.md).

# UI

AnyListen ships a single screen built in SwiftUI, plus a Settings sheet
opened from the gear icon in the header. There are deliberately no tabs or
navigation stacks — the app's job fits in one view.

## Layout

```
┌──────────────────────────────────┐
│  AnyListen                ⚙︎     │   ← Title (20 pt rounded bold) + gear
├──────────────────────────────────┤
│ ┌──────────────────────────────┐ │
│ │ 🎤  MICROPHONE               │ │   ← mic icon + "Change ▾" Menu
│ │     <current input name>     │ │   ← orange "X — missing" when the
│ │                  [ Change ▾ ]│ │     selected mic is gone
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ 🔊  SPEAKER OR HEADPHONES    │ │   ← AVRoutePickerView (AirPlay)
│ │     <current output name>    │ │   ← orange "X — missing" or
│ │                [ 🎚 AirPlay ]│ │     "Connect headphones" when blocked
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ ◗  LISTENING CONTROL         │ │
│ │     Listening is on / off    │ │
│ │     ╭──────────╮             │ │
│ │     │  ◗ ear   │             │ │   ← Listen / Stop (132 × 132)
│ │     ╰──────────╯             │ │
│ │     Start / Stop Listening   │ │   ← or the reason it's disabled
│ └──────────────────────────────┘ │
└──────────────────────────────────┘
```

Warning states are shown *in place*: the row's value text turns orange
("Wireless ME RX — missing", "Connect headphones") and the Listen button is
disabled with the reason as its label ("Headphones required", "Microphone
required"). There are no separate warning banners, and `errorMessage` from
the manager is deliberately **not rendered** — stop causes are communicated
via the orange state text and the disabled button label.

The whole thing sits on a top-leading → bottom-trailing linear gradient
between two dark navy stops, inside a `ScrollView` so larger Dynamic Type
sizes (senior-friendly) don't push the listen button off-screen.

## Component breakdown (`ContentView.swift`)

| Subview | Role |
|---------|------|
| `microphoneCard` | The MICROPHONE panel. Hosts the input menu; value text goes orange with a "— missing" suffix when the selected mic is gone. |
| `speakerCard` | The SPEAKER OR HEADPHONES panel. Hosts `AudioRoutePicker`; shows "Connect headphones" in orange whenever the speaker is routed (blocked), or "X — missing" when the external output was observed going away. |
| `listeningCard` | The LISTENING CONTROL panel. Hosts the listen button and state label; border turns green while running. |
| `routeRow(...)` | Helper builder. Renders a leading icon, two-line title/value, and a trailing control (any `View`). Marks warning state with orange. |
| `inputMenu` | SwiftUI `Menu` containing "Automatic" + every device in `availableInputs`, marked with a check when current. |
| `listenButton` | The big circular 132 × 132 button. If running → `stop()`; else `beginListening()`. Disabled (`isButtonDisabled`) when the selected input is missing, the output is missing, or the route is the same-device loopback — with the reason shown as the label. |
| `SettingsView` | The gear-icon sheet: monitor-volume slider, "Start listening automatically", and "Resume after phone calls". |

Each card is wrapped in the `cardStyle(borderColor:)` helper: a translucent
fill, a 1pt border (orange when warning, otherwise subtle white), and a 20pt
corner radius. The listening card's border turns green while running.

## State binding

The root view creates the manager with `@StateObject` so its lifetime tracks
the screen, and never recreates it:

```swift
@StateObject private var audioManager = AudioEngineManager()
```

All state that drives the UI lives on `audioManager`; the only view-local
state is `@State private var showSettings` for the Settings sheet.

Reactions:

- `onAppear` triggers `audioManager.updateAudioRoutes()` to make sure the
  list of available inputs is fresh on first paint.
- `onChange(of: audioManager.isRunning)` posts a VoiceOver announcement
  ("Listening started" / "Listening stopped").
- The listen button consults `isRunning` (drives label, fill, and whether a
  tap stops or starts) and is disabled via `isButtonDisabled`, which is true
  when `selectedInputIsMissing`, `outputIsMissing`, or `outputIsBlocked`
  (speaker routed) holds while not running.
- The microphone card renders its value in orange when
  `selectedInputIsMissing` is true.
- The speaker card renders its value in orange when `outputIsMissing` (the
  previously routed external output was observed going away) or
  `outputIsBlocked` (speaker routed) — the latter replacing the value text
  with "Connect headphones". Missing takes precedence in the text.

Cross-flow that *could* feel surprising:

- When the user changes the input while running, the manager tears the
  engine down, reconfigures the session, and **stops with a "Tap LISTEN to
  resume" message** — it does not auto-restart. (Auto-restart was removed
  both for UX consistency with output changes and because reconfiguring the
  session while a USB route switch is in flight could deadlock the audio
  server. See [`REVIEW.md`](REVIEW.md), round 3.)

## `AudioRoutePicker` and `AVRoutePickerView`

The native `AVRoutePickerView` is a UIKit button. SwiftUI wraps it like
this:

```swift
struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> FullFrameAudioRoutePickerView { … }
    func updateUIView(_ uiView: FullFrameAudioRoutePickerView, context: Context) {}
}
```

`FullFrameAudioRoutePickerView.layoutSubviews()` stretches every internal
subview to its own bounds. Without that, the AirPlay glyph sits in a
corner of the SwiftUI frame and the hit area is too small. The
workaround is described in the comment on `layoutSubviews`. There is no
`UIView` resizing override because the inner structure of
`AVRoutePickerView` is private; brute-force mass-resize is the
documented workaround used elsewhere too.

## Blocked-output UX (speaker route)

Listening requires an external output, so **any** built-in-speaker route is
blocked, not warned about: `outputIsBlocked` disables the Listen button,
the speaker card shows "Connect headphones" in orange, and the button label
reads "Headphones required". This covers every way of landing on the
speaker — first launch with nothing connected (the old "dangerous
loopback" case), or deliberately picking "iPhone Speaker" in the route
picker. Picking the speaker is a real, visible action (listening stops and
the UI turns orange), but the app never claims the headphones are
"missing" — they may well still be connected, just not selected.

The "X — missing" output state is reserved for an *observed* device loss:
a route change with reason `.oldDeviceUnavailable` while actually routed
to that device (tracked via `externalOutputObservedLost`; see
`AudioEngineManager.updateExternalOutputLossState`). There is no
`availableOutputs` API, so the route alone can't distinguish the two cases
— the route-change reason can.

This replaced an earlier design that showed a scary confirm alert with a
"Listen Anyway" escape hatch, and a later heuristic that misreported a
user-selected speaker as "X — missing".

## Accessibility

- The Listen button carries `.accessibilityLabel` (Start/Stop listening),
  `.accessibilityHint`, and `.accessibilityValue` (on/off), and start/stop
  is announced via `UIAccessibility.post(.announcement, …)`.
- The gear button ("Settings") and the route picker ("Select output") are
  labelled; the route picker's decorative state icon is hidden from
  VoiceOver.
- The layout lives in a `ScrollView` so larger Dynamic Type sizes don't
  push the Listen button off-screen; the gear and Change controls keep
  44×44 hit targets.
- Remaining backlog: the mic/speaker rows are still separate elements
  rather than one combined accessible element per row. See
  [`REVIEW.md`](REVIEW.md) L2.

## Localization

All user-facing strings are extractable and live in two string catalogs:

- `AnyListen/Localizable.xcstrings` — every UI string (SwiftUI `Text`
  literals are auto-extracted; dynamic strings go through
  `String(localized:)`; `SWIFT_EMIT_LOC_STRINGS = YES` is set in
  `project.yml`).
- `AnyListen/InfoPlist.xcstrings` — `NSMicrophoneUsageDescription`.

English is the source and only language for v1 (the store listing is
English-only too — see [`APP_STORE.md`](APP_STORE.md)). Shipping a new
language is now a data-only change: add it to the catalogs in Xcode.

One deliberate localization choice: device names from `AVAudioSession`
(e.g. "Jules's AirPods") are passed through verbatim, and composite
sentences ("Selected input was disconnected.") are whole-sentence keys
rather than interpolated fragments.

## Why no SwiftUI-only audio devices API?

`AVRoutePickerView` is the only first-party UI for output selection on
iOS in an app that doesn't own CarPlay/AirPlay entitlements.
Alternatives like a custom `AVAudioSession.availableInputs`-driven
output picker can't actually *change* the output — iOS owns that
graph. So `AudioRoutePicker` is correct here, despite the SwiftUI
bridge it forces.

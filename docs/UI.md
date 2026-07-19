# UI

AnyListen ships a single screen built in SwiftUI. There are deliberately no
tabs, navigation stacks, or settings pages today — the app's job fits in one
view. (A Settings sheet is planned; see
[`ROADMAP.md`](ROADMAP.md).)

## Layout

```
┌──────────────────────────────────┐
│  AnyListen                       │   ← Title (18 pt rounded bold)
├──────────────────────────────────┤
│ ┌──────────────────────────────┐ │
│ │ 🎤  MICROPHONE               │ │   ← mic icon + "Change ▾" Menu
│ │     <current input name>     │ │   ← (Automatic + each input)
│ │                  [ Change ▾ ]│ │
│ │ <missing-mic warning>        │ │   ← orange, only when missing
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ 🔊  SPEAKER OR HEADPHONES    │ │   ← AVRoutePickerView (AirPlay)
│ │     <current output name>    │ │
│ │                [ 🎚 AirPlay ]│ │
│ │ <missing / feedback warning> │ │   ← orange, when applicable
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ ◗  LISTENING CONTROL         │ │
│ │     Listening is on / off    │ │
│ │     ╭──────────╮             │ │
│ │     │  ◗ ear   │             │ │   ← Listen / Stop (132 × 132)
│ │     ╰──────────╯             │ │
│ │     LISTEN  (or STOP…)       │ │
│ │ <error message in orange>    │ │
│ └──────────────────────────────┘ │
└──────────────────────────────────┘
```

The whole thing sits on a top-leading → bottom-trailing linear gradient
between two dark navy stops, inside a `ScrollView` so larger Dynamic Type
sizes (senior-friendly) don't push the listen button off-screen.

## Component breakdown (`ContentView.swift`)

| Subview | Role |
|---------|------|
| `microphoneCard` | The MICROPHONE panel. Hosts the input menu and the missing-mic warning. |
| `speakerCard` | The SPEAKER OR HEADPHONES panel. Hosts `AudioRoutePicker` and the missing-output / feedback warnings. |
| `listeningCard` | The LISTENING CONTROL panel. Hosts the listen button, state label, and operational error message. |
| `routeRow(...)` | Helper builder. Renders a leading icon, two-line title/value, and a trailing control (any `View`). Marks warning state with orange. |
| `inputMenu` | SwiftUI `Menu` containing "Automatic" + every device in `availableInputs`, marked with a check when current. |
| `listenButton` | The big circular 132 × 132 button. Inline logic: if running → `stop()`; else if `outputMayCauseFeedback` → show the warning alert; else `beginListening()`. Disabled and dimmed when the selected input is missing. |
| `warningText(_:)` | Small helper for the orange feedback / missing-device warnings inside each card. |

Each card is wrapped in the `cardStyle(borderColor:)` helper: a translucent
fill, a 1pt border (orange when warning, otherwise subtle white), and a 20pt
corner radius. The listening card's border turns green while running.

## State binding

The root view creates the manager with `@StateObject` so its lifetime tracks
the screen, and never recreates it:

```swift
@StateObject private var audioManager = AudioEngineManager()
```

All state that needs to drive UI lives on `audioManager`, with one
exception: `@State private var showSpeakerWarning` belongs to the view
because the warning is a transient modal UX concern, not a domain
property of the audio model.

Reactions:

- `onAppear` triggers `audioManager.updateAudioRoutes()` to make sure the
  list of available inputs is fresh on first paint.
- The listen button consults three manager properties: `isRunning`
  (drives label color and fill), `outputMayCauseFeedback` (gates the
  feedback warning alert), and `selectedInputIsMissing` (drives the
  disabled / "Microphone required" state).
- The microphone card renders an orange warning when
  `selectedInputIsMissing` is true.
- The speaker card renders an orange warning when `outputIsMissing` (a
  remembered external output has vanished and iOS fell back to the
  speaker) OR `outputMayCauseFeedback` (the speaker is genuinely the
  chosen output). Missing takes precedence over feedback in the text.
- The listening card reads `isRunning` and `errorMessage`.

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

## Feedback warning UX

```swift
.alert("Speaker feedback warning", isPresented: $showSpeakerWarning) {
    Button("Cancel", role: .cancel) { }
    Button("Listen Anyway", role: .destructive) {
        audioManager.beginListening()
    }
} message { … }
```

Triggers when `audioManager.outputMayCauseFeedback == true` — i.e., the
active output is `builtInSpeaker` (and not merely the fallback for a
missing external). The user can still proceed; the warning is
informational, not blocking.

> **Planned change:** the same-device loopback case (iPhone mic → iPhone
> speaker) is the worst possible first-run experience. The plan is to
> disable the Listen button for that case by default (with constructive
> "connect headphones" guidance instead of a scary confirm) and hide an
> "allow same-device loopback" toggle in Settings. See
> [`ROADMAP.md`](ROADMAP.md), P1.

## Accessibility

Today, the only labelled control is the route picker:

```swift
.accessibilityLabel("Select output")
```

Everything else relies on standard SwiftUI / system-derived labels:

- Big button is unlabeled — VoiceOver says "Button" only. Recommend
  adding `.accessibilityLabel(audioManager.isRunning ? "Stop listening"
  : "Listen")` and `.accessibilityHint(...)`.
- The MICROPHONE / SPEAKER rows are unlabeled `HStack`s. Recommend labelling
  them as one combined element per row, or adding explicit labels to
  the leading `Image` (`accessibilityHidden(true)` and shifting the
  description onto the value text).
- The listening card's state line is dynamic — fine — but the alert
  message "Speaker feedback warning" is hard-coded English.

See [`REVIEW.md`](REVIEW.md) for the full accessibility backlog, and
[`ROADMAP.md`](ROADMAP.md) for accessibility work planned for this
audience (hearing-aid users have non-trivial VoiceOver use).

## Localization

There is no `Localizable.strings`. Every visible string is a string
literal in Swift or a SwiftUI default. If you ship this app outside
English-speaking locales, you'll need to:

1. Add `Localizable.strings` (or use the built-in `String(localized:)` /
   `LocalizedStringKey`).
2. Wrap every user-facing literal.
3. Localize the `NSMicrophoneUsageDescription` in `Info.plist` (add a
   `InfoPlist.strings`).

## Why no SwiftUI-only audio devices API?

`AVRoutePickerView` is the only first-party UI for output selection on
iOS in an app that doesn't own CarPlay/AirPlay entitlements.
Alternatives like a custom `AVAudioSession.availableInputs`-driven
output picker can't actually *change* the output — iOS owns that
graph. So `AudioRoutePicker` is correct here, despite the SwiftUI
bridge it forces.

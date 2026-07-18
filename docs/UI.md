# UI

AnyListen ships a single screen built in SwiftUI. There are deliberately no
tabs, navigation stacks, or settings pages — the app's job fits in one
view.

## Layout

```
┌──────────────────────────────────┐
│  AnyListen                       │   ← Title (18 pt rounded bold)
├──────────────────────────────────┤
│ ┌──────────────────────────────┐ │
│ │ 🎤  INPUT                    │ │   ← Input row (mic icon)
│ │     <current input name>     │ │   ← tap "Select" to swap
│ │                  [ Select ▾ ]│ │
│ ├──────────────────────────────┤ │
│ │ 🔊  OUTPUT                   │ │   ← Output row (speaker icon)
│ │     <current output name>    │ │
│ │                [ 🎚 AirPlay ]│ │   ← AVRoutePickerView
│ └──────────────────────────────┘ │
│                                  │
│           ╭──────────╮           │
│           │  ◗ ear   │           │   ← Listen / Stop (132 × 132)
│           ╰──────────╯           │
│          LISTEN  (or STOP…)      │
│                                  │
│      Listening is ON / OFF       │
│      <error message in orange>   │
└──────────────────────────────────┘
```

The whole thing sits on a top-leading → bottom-trailing linear gradient
between two dark navy stops.

## Component breakdown (`ContentView.swift`)

| Subview | Role |
|---------|------|
| `settingsCard` | The white-on-glass INPUT / OUTPUT panel. Hosts the input menu, `AudioRoutePicker`, conditional warning text. |
| `routeRow(...)` | Helper builder. Renders a leading icon, two-line title/value, and a trailing control (any `View`). Marks warning state with orange. |
| `inputMenu` | SwiftUI `Menu` containing "Automatic" + every device in `availableInputs`, marked with a check when current. |
| `listenButton` | The big circular 132 × 132 button. Drives `audioManager.toggleListening()` — except when output is the built-in speaker, in which case it shows the warning alert first. Disabled and dimmed when `selectedInputIsMissing` is true. |
| `statusArea` | Status line + optional `errorMessage`. |
| `warningText(_:)` | Small helper for feedback / missing-input warnings inside the settings card. |

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
- The listen button consults three properties: `isRunning`
  (drives label color), `outputMayCauseFeedback` (drives warning), and
  `selectedInputIsMissing` (drives disabled state).
- The settings card consults `selectedInputIsMissing` and
  `outputMayCauseFeedback` to render orange-on-white warning text.
- The status area reads `isRunning` and `errorMessage`.

Cross-flow that *could* feel surprising:

- When the user changes the input while running, the manager stops,
  reconfigures, and restarts. The button label doesn't flicker because
  both the stop and the start are sequenced inside one `selectInput`
  call — UI only sees the steady state after `start()` resolves.

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
} message: { … }
```

Triggers when `audioManager.outputMayCauseFeedback == true` — i.e., the
active output is `builtInSpeaker`. The user can still proceed; the
warning is informational, not blocking.

## Accessibility

Today, the only labelled control is the route picker:

```swift
.accessibilityLabel("Select output")
```

Everything else relies on standard SwiftUI / system-derived labels:

- Big button is unlabeled — VoiceOver says "Button" only. Recommend
  adding `.accessibilityLabel(audioManager.isRunning ? "Stop listening"
  : "Listen")` and `.accessibilityHint(...)`.
- The INPUT/OUTPUT rows are unlabeled `HStack`s. Recommend labelling
  them as one combined element per row, or adding explicit labels to
  the leading `Image` (`accessibilityHidden(true)` and shifting the
  description onto the value text).
- The status area is dynamic — fine — but the alert message "Speaker
  feedback warning" is hard-coded English.

See [`REVIEW.md`](REVIEW.md) for the full accessibility backlog.

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

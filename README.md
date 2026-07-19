# AnyListen

AnyListen is a tiny iPhone-only iOS app that routes the device's microphone (or any
other selected audio input) to a user-chosen audio output — Bluetooth speaker,
USB DAC, AirPlay, headphones, etc. — with low latency, no recording, and no
network.

The app is intentionally minimal: a single screen with an input picker, an
output picker, and a big "Listen" button.

> All audio stays on-device. The app neither records to disk nor transmits
> anything off the device.

## Features

- Pick from any audio input iOS exposes (built-in mic, USB, BT HFP, headset, …)
- Pick from any audio output via the system `AVRoutePickerView`
- Low-latency pass-through (~5 ms I/O buffer)
- Persistent input selection across launches
- Smart handling of Bluetooth / AirPods so they don't hijack USB input
- Soft warnings for missing input or speaker feedback risk

## High-level architecture

SwiftUI views drive a single `ObservableObject` — `AudioEngineManager` — which
in turn manages an `AVAudioEngine` and an `AVAudioSession`. The engine's input
node is connected *directly* to its main mixer node, producing a real-time
loopback to the user's chosen output at roughly one I/O buffer (~5 ms) of
app-added latency — no tap, no player node, no scheduling jitter. This matches
Live Listen's latency, which is a core requirement (see
[`docs/ROADMAP.md`](docs/ROADMAP.md)).

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full picture, or
the [`docs/README.md`](docs/README.md) table of contents.

## Project layout

```
AnyListen/
├── AnyListenApp.swift          # @main entry point
├── AudioEngineManager.swift    # Core audio / AVAudioSession logic
├── AudioRoutePicker.swift      # SwiftUI wrapper around AVRoutePickerView
├── ContentView.swift           # The single screen
└── Info.plist                  # Bundle metadata, mic permission, audio BG mode
```

## Building

The project is generated from [`project.yml`](project.yml) via
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open AnyListen.xcodeproj
```

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for more, including
deployment-target notes, signing, and the dependency footprint.

## Code review

A focused review — covering correctness, robustness, UX gaps, accessibility,
localization, and build hygiene — is in
[`docs/REVIEW.md`](docs/REVIEW.md).

## Status

This is a working prototype. It is not App Store hardened: there is no
localization, no tests, no telemetry hooks. See REVIEW.md for the gaps.

The App Store listing (store name, subtitle, search keywords, category) is
decided and recorded in [`docs/APP_STORE.md`](docs/APP_STORE.md). Those
fields live in App Store Connect, not in this repo — the on-device name
stays "AnyListen".

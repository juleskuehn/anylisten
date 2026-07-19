# AnyListen — Documentation Index

This directory holds the long-form documentation for AnyListen.

| File | What's inside |
|------|---------------|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | High-level module layout, data flow, lifecycle, threading. |
| [`AUDIO_PIPELINE.md`](AUDIO_PIPELINE.md) | Deep dive into the `AVAudioEngine` + `AVAudioSession` setup and the Bluetooth/HFP reasoning. |
| [`UI.md`](UI.md) | The single-screen UI: layout, state binding, warnings, accessibility notes. |
| [`REVIEW.md`](REVIEW.md) | Issues, sharp edges, and suggested improvements. |
| [`ROADMAP.md`](ROADMAP.md) | Next-iteration review & plan; the Live Listen latency constraint and what it rules out. |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | Build configuration, signing, deployment target, XcodeGen workflow. |
| [`APP_STORE.md`](APP_STORE.md) | App Store Connect listing: store name, subtitle, keywords, category, and the rationale behind them. |
| [`SCREENSHOT_TESTING.md`](SCREENSHOT_TESTING.md) | CLI simulator screenshot workflow for UI iteration — capture recipes, device states, Dynamic Type zoom via CLI. |

## At a glance

- **Platform**: iOS (iPhone & iPad), portrait.
- **Bundle ID**: `com.anylisten.AnyListen`
- **Language**: Swift
- **UI**: SwiftUI
- **Audio**: AVFoundation (`AVAudioEngine`, `AVAudioSession`), AVKit (`AVRoutePickerView`)
- **Build tool**: XcodeGen (`project.yml` → `AnyListen.xcodeproj`)
- **State**: a single `@StateObject` `AudioEngineManager` exposing
  `@Published` properties.

## Source file map

```
AnyListen/
├── AnyListenApp.swift         # @main; WindowGroup > ContentView
├── AudioEngineManager.swift   # All audio state + routing logic
├── AudioRoutePicker.swift     # UIViewRepresentable wrapping AVRoutePickerView
├── ContentView.swift          # The single screen + Settings sheet
├── Localizable.xcstrings      # String catalog (source: English)
├── InfoPlist.xcstrings        # Localizable Info.plist strings
├── PrivacyInfo.xcprivacy      # Privacy manifest
├── Assets.xcassets/           # App icon
└── Info.plist                 # Mic permission string + audio background mode
```

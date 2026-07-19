# Simulator Screenshot Testing

Field notes from driving UI tweaks via CLI screenshots (Xcode 26, iOS 26
simulators). The goal: make a UI change, then *see* it — at multiple text
sizes and device sizes — without touching Xcode's GUI.

## The basic capture loop

```sh
# 1. Build for simulator (no signing needed)
xcodebuild -project AnyListen.xcodeproj -scheme AnyListen \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO

# 2. Install + launch + capture (use UDIDs, not "booted")
APP=~/Library/Developer/Xcode/DerivedData/<hash>/Build/Products/Debug-iphonesimulator/AnyListen.app
SIM=B172CF39-7195-416A-8DE2-80D7539174F1
xcrun simctl install $SIM "$APP"
xcrun simctl launch $SIM com.anylisten.AnyListen
xcrun simctl io $SIM screenshot shot.png
```

Gotchas:

- **Always address devices by UDID.** Once more than one simulator is
  booted, `booted` commands fail or hit the wrong device.
  `xcrun simctl list devices` (optionally `| grep Booted`) gives UDIDs.
- **Sims shut down between sessions.** `SimError 405 "Unable to lookup in
  current state: Shutdown"` → `xcrun simctl boot <udid>`, wait ~10 s.
- **Screenshot size = native device pixels.** iPhone 17 Pro Max →
  1320×2868 (the App Store 6.9″ slot), iPad Pro 13″ → 2064×2752 (the 13″
  slot), iPhone 16e → 1170×2532. Capture on the device class that matches
  the slot you need; no resizing afterwards.
- **Installing over an existing app keeps its container** — permission
  states and UserDefaults survive reinstalls. Terminate + relaunch to
  re-run launch-argument paths.

## Presentation polish

```sh
# Clean status bar (Apple marketing style); persists per device until cleared
xcrun simctl status_bar $SIM override --time 9:41 \
  --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
xcrun simctl status_bar $SIM clear        # when done

# Dark / light appearance (affects system chrome + adaptive UI)
xcrun simctl ui $SIM appearance dark
```

Note: iPad's status bar always shows the date as well as the time; the
override only controls the time part.

## There is no tap API — reaching non-default states

`simctl` cannot inject touches. AppleScript GUI scripting / `cliclick`
require the terminal to have Accessibility ("assistive access")
permission — without it you get `osascript is not allowed assistive
access (-1719)`. Two workarounds that need no permissions:

**1. Temporary DEBUG launch-argument hooks.** Add state-forcing code
behind `#if DEBUG`, pass the flag at launch, remove the hook when done:

```swift
// ContentView.body .onAppear — TEMP, for screenshot capture only
#if DEBUG
if ProcessInfo.processInfo.arguments.contains("-AnyListenOpenSettings") {
    showSettings = true
}
#endif
```

```sh
xcrun simctl launch $SIM com.anylisten.AnyListen -AnyListenOpenSettings
```

Used for: opening the Settings sheet (a SwiftUI `Menu` like the input
picker **cannot** be force-opened this way — menus have no presentation
binding, so menu-open shots still need a manual capture).

**2. System permission states via `simctl privacy`.**

```sh
xcrun simctl privacy $SIM revoke microphone com.anylisten.AnyListen  # denied
xcrun simctl privacy $SIM grant  microphone com.anylisten.AnyListen  # granted
xcrun simctl privacy $SIM reset  microphone com.anylisten.AnyListen  # notDetermined
```

`revoke` on a fresh install yields `.denied` without any prompt — exactly
what's needed to capture a permission-denied screen.

## Dynamic Type / large text

Driving text size from the CLI took some digging. The working recipe
(confirmed on the iOS 26 simulator):

```sh
# 1. Write the CORRECT key: UIPreferredContentSizeCategoryName
xcrun simctl spawn $SIM defaults write com.apple.UIKit \
  UIPreferredContentSizeCategoryName -string UICTContentSizeCategoryAccessibilityXL

# 2. A FULL reboot is required — terminating + relaunching the app is
#    NOT enough; the trait never reaches the running system otherwise.
xcrun simctl shutdown $SIM
xcrun simctl boot $SIM

# 3. Install / launch / screenshot as usual.
```

Reset afterwards with `-string UICTContentSizeCategoryL` (the default)
plus another reboot.

Category names: `UICTContentSizeCategory{XS,S,M,L,XL,XXL,XXXL}` and the
accessibility tiers `UICTContentSizeCategoryAccessibility{M,L,XL,XXL,XXXL}`.

The key was found by inspecting what the system itself persists after a
manual Settings change:

```sh
grep -rl ContentSizeCategory \
  ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/Preferences/
# → com.apple.UIKit.plist → UIPreferredContentSizeCategoryName
```

Dead ends (don't bother):

| Approach | Result |
|---|---|
| `defaults write com.apple.UIKit UIContentSizeCategory …` | Wrong key — writes fine, never honored. |
| Launch arg `-UIContentSizeCategory …` | Not honored (iOS 26 sim, SwiftUI). |
| Writing the right key without rebooting | Not honored — full shutdown + boot required. |
| Simulator menu *Features → Increase Text Size* (⌘+) | Works, but needs GUI / assistive access. |

Also learned: **don't rely on a sim "still being zoomed"** — sims shut
down between sessions and a manually set text size may be gone by the
time you come back; set it explicitly (and reboot) for every capture
session.

## Verifying results

- **Read the screenshot back** — never assume a change rendered. (Hard
  lesson: an `.xcstrings` rename fixed the keys but left stale English
  *values*; the code looked right, the pixels told the truth.)
- **Bit-identical PNGs are a feature.** `simctl` captures are
  deterministic for unchanged screens — if git shows no binary change
  after a recapture, the screen provably didn't change. Useful both for
  confirming "default appearance unchanged" and for spotting unintended
  diffs.

## Handy device IDs on this machine

| Device | UDID | Slot |
|---|---|---|
| iPhone 17 Pro Max | `B172CF39-7195-416A-8DE2-80D7539174F1` | 6.9″ required |
| iPad Pro 13″ (M5) | `164E9A9E-C724-4B78-B871-317191303C68` | 13″ required |
| iPhone 16e | `9FB2F4AA-B70B-4254-90BB-5C5BFD8613A2` | small-screen testing |

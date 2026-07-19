# App Store Metadata

Canonical record of the AnyListen App Store Connect listing decisions
(2026-07-19). **None of these fields live in this repo** — the store name,
subtitle, keywords, and category are entered in App Store Connect at
submission time. The on-device name stays `AnyListen` via `PRODUCT_NAME`
in `project.yml` and must not be renamed to match the store listing.

## The listing

| Field | Value | Chars | Limit |
|-------|-------|------:|------:|
| App name | `AnyListen: Sound Amplifier` | 26 | 30 |
| Subtitle | `Live listen with external mic` | 29 | 30 |
| Keywords | `microphone,hearing,aid,airpods,bluetooth,headphones,booster,usb,volume,ear,audio` | 80 | 100 |
| Primary category | Utilities | — | — |

## Rationale

### Search indexing drove everything

The App Store search algorithm indexes **only** the app name, subtitle,
and keyword field (plus developer name). The long description is **not**
indexed on iOS — that is a Google Play behavior. The description still
matters for conversion and for Google indexing of the App Store web
page, but every search term we care about must fit in the three indexed
fields above.

- **"Sound amplifier"** in the name is the high-volume category phrase
  that established hearing-assistance apps (Petralex et al.) rank for.
- **"Live listen with external mic"** in the subtitle captures the
  long-tail feature searches from users who know Apple's Live Listen and
  want to use a non-iPhone microphone with it.
- **"loopback" was deliberately rejected**: it is pro-audio jargon the
  target audience never types, and it collides with Rogue Amoeba's Mac
  product of the same name.
- The keyword field picks up everything that didn't fit:
  `microphone` (full word), `hearing`, `aid`, `airpods`, `bluetooth`,
  `headphones`, `booster`, `usb`, `volume`, `ear`, `audio`.

Keyword field rules applied: no spaces after commas (spaces count
against the 100), singular forms only, no words already present in the
name or subtitle (duplicates waste characters), no "app", no category
names, no competitor trademarks.

### Medical positioning

Utilities category plus "amplifier"/"hearing support" language is the
established PSAP (personal sound amplification product) framing and
avoids the scrutiny that comes with medical claims.

- ✅ Fine: `hearing`, `aid` in the **hidden** keyword field (standard
  practice among competitors).
- ❌ Never in visible metadata, screenshots, or description: "treats
  hearing loss", "medical device", "FDA", "replaces a hearing aid".

The App Store **description** (not indexed; safe for plain language)
ends with this exact disclaimer line as cheap insurance against
Guideline 1.4.1 scrutiny:

> AnyListen is not a medical device and is not intended to diagnose,
> treat, cure, or prevent any disease or hearing condition.

### "Live Listen" trademark risk

"Live Listen" is an Apple feature name. Using it in the **subtitle**,
trailing our own brand, is descriptive and low-risk; many third-party
apps do the same. Never make it the leading words of the app name, and
never style the branding to imply the app *is* Apple's feature. Worst
case is an Apple request to adjust metadata at the next version
submission.

### Name uniqueness

The exact name "AnyListen" is taken by an unrelated audiobook player
(Books category). App Store Connect only enforces exact-name uniqueness,
so the `: Sound Amplifier` suffix satisfies it. Dispute risk from that
app is low: different category, descriptive suffix, no indication of a
registered trademark.

## Editing constraints (App Store Connect)

- Name, subtitle, keywords, and description can **only** be changed when
  submitting a **new app version** — get them right before each release.
- Promotional text (170 chars), What's New, and URLs are editable
  anytime.

## Pre-submission checklist

- [ ] Create the app record in App Store Connect with bundle ID
      `com.anylisten.AnyListen`.
- [ ] Enter name / subtitle / keywords exactly as in the table above.
- [ ] Primary category: **Utilities**. Do **not** choose Medical.
- [ ] App privacy questionnaire: microphone is used for real-time
      pass-through only; no data is collected, stored, or transmitted
      (matches the privacy section in [`DEVELOPMENT.md`](DEVELOPMENT.md)).
- [x] App icon: `AppIcon-1024.png` in `Assets.xcassets`, confirmed wired
      into the generated project (`ASSETCATALOG_COMPILER_APPICON_NAME =
      AppIcon`).
- [x] Privacy manifest: `PrivacyInfo.xcprivacy` declares no collected
      data, no tracking, and the UserDefaults required-reason API
      (CA92.1). Keep it in sync with the app privacy questionnaire.
- [ ] Review notes for Apple: describe the app as an audio
      routing/amplification utility, explicitly not a medical device and
      making no medical claims. Also explain how to test: no login is
      needed; connect any headphones (wired or Bluetooth), then tap
      Start Listening; the speaker route is *intentionally* blocked to
      prevent feedback; background audio is the intended use.
- [ ] **Demo video** (required for hardware-dependent features — a
      reviewer on a stock device sees a disabled Listen button without
      headphones): record ~30 s of AirPods connecting → Start Listening
      → live pass-through, and link it in the review notes.
- [ ] Privacy policy URL: `docs/privacy.html` in this repo, served via
      GitHub Pages at `https://juleskuehn.github.io/anylisten/privacy.html`
      (enable: repo Settings → Pages → deploy from branch → main → /docs).
      The same URL is linked in-app from the Settings sheet.
- [ ] Support URL: `docs/support.html` →
      `https://juleskuehn.github.io/anylisten/support.html` (Guideline 1.5:
      must offer a way to contact the developer).
- [x] Screenshots: captured at the **required** slot sizes via simulator
      — 6.9″ iPhone (1320×2868) and 13″ iPad (2064×2752) — in
      [`../screenshots/appstore/`](../screenshots/appstore/) (three states
      per device: main, mic-permission card, Settings). Upload those per
      slot; replace with on-device captures later if desired.
- [ ] Screenshots and description: no medical claims (see list above).
- [x] Localization readiness: all app strings live in
      `Localizable.xcstrings` / `InfoPlist.xcstrings` (REVIEW L1
      resolved). Listing content is English-only for v1; add languages
      via the catalogs when that changes.

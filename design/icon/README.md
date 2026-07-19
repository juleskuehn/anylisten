# Icon source layers

`AppIcon-1024.png` (in `AnyListen/Assets.xcassets/AppIcon.appiconset/`) is
composed from these two layers:

| Layer | File | Notes |
|-------|------|-------|
| Background | `background.png` | Solid `#38CD6C` green, full-bleed square (the system applies the rounded-corner mask — never bake it in). |
| Foreground | `foreground-ear.png` | White ear glyph with a proper alpha channel, cleanly un-blended from the background. |

Rules baked into the shipped PNG: **1024×1024, RGB, no alpha channel, no
transparency** — App Store Connect rejects icons that have either
(ITMS-90717).

## Liquid Glass / Icon Composer (optional upgrade)

Per the HIG, layered icons get the best system treatment (specular
highlights, dark/clear/tinted variants) on iOS 26+. To adopt it: open
**Icon Composer** (included with Xcode 26), import `background.png` as the
background layer and `foreground-ear.png` as a single foreground layer,
annotate the dark/mono variants, export the `.icon` file, add it to the
target, and point `ASSETCATALOG_COMPILER_APPICON_NAME` at it (replacing the
flattened PNG in the asset catalog). The flattened PNG remains a valid
fallback until then.

# App Icon — Design Spec

**Date:** 2026-04-23
**Status:** Approved, ready for implementation plan.

## Goal

Give SpeakClean a proper macOS app icon — the artwork shown in the Dock, Launchpad, Finder "Get Info", the Applications folder, and the Finder window title bar. Derived from the menu-bar glyph (I-beam text cursor + 4-bar waveform) so recognition transfers between the menu-bar button and the Dock icon.

## Non-goals

- **No change to the menu-bar icon.** It stays template-rendered and programmatically drawn in `MenuBarIcon.swift`. Menu-bar and Dock icons serve different roles (monochrome tint-following vs. full-fidelity artwork) and are intentionally different artifacts.
- **No dark-mode icon variant.** macOS does not theme app icons by system appearance; one artwork serves both modes.
- **No animated / state-dependent app icon.** (The menu bar already surfaces recording / processing state.)
- **No window / document / file-type icons.** SpeakClean has no windows of its own aside from Settings and no document types.

## Visual design

Monochrome: a light squircle with a dark glyph, plus a gentle top-to-bottom background gradient — selected via the visual companion. Concretely:

- **Canvas:** 1024 × 1024 px, PNG with alpha. The macOS icon grid calls for a ~100 px transparent bleed around the visible artwork; the squircle itself is 824 × 824 centered in the canvas.
- **Shape:** macOS Big Sur+ squircle (superellipse), 824 × 824, centered at (512, 512). Use the standard macOS app-icon mask path — corner shape is part of the authored artwork, not applied by `iconutil`. Do not substitute a rounded-rect approximation.
- **Background fill:** vertical linear gradient clipped to the squircle, `#ffffff` at the top of the squircle → `#c9ccd2` at the bottom. No border, no inner shadow.
- **Glyph:** the menu-bar icon composition, recomposed at app-icon scale.
  - I-beam text cursor on the left: one vertical stroke with two short horizontal serifs top and bottom (same 3-line construction as `MenuBarIcon.idle`).
  - 4-bar waveform on the right, four vertical bars with proportional heights matching `MenuBarIcon.idle` (the bar endpoints at the 36-unit menu-bar canvas are `(14,22)`, `(8,28)`, `(11,25)`, `(14,22)`).
  - Stroke color: near-black (`#111`), fully opaque.
  - Round line caps (`.round`), matching the menu-bar icon.
- **Glyph proportions:** the full 36 × 36 menu-bar coordinate system maps linearly to a 560 × 560 inner region of the squircle (centered at (512, 512)). That leaves ~130 px of padding between the glyph and the squircle edge on all sides, which is the typical breathing room for "content inside a macOS app icon". The resulting stroke width is `2.5 × (560 / 36) ≈ 39 px` at 1024 canvas — subject to a final visual tune (see Open questions).
- **Drop shadow / depth:** none in the artwork itself. macOS renders a subtle ambient shadow around Dock icons automatically.

Monochrome was chosen deliberately over a color squircle: the app is a small utility, the menu-bar identity is already grayscale, and a colorless icon reads as "system-utility" rather than "app with a brand". The gradient gives the icon enough volume to not feel flat next to other Dock apps.

## Source of truth and generation

The icon is produced from a single authored source, rasterized into Apple's standard iconset, and packaged into a `.icns`.

### Source file

`scripts/render-icon.swift` — single-file Swift script that composes a 1024 × 1024 `IconView` in SwiftUI (`RoundedRectangle(cornerRadius: 185, style: .continuous)` for the squircle, `LinearGradient` for the fill, a `Path` for the glyph) and snapshots it with `ImageRenderer` into a PNG. Checked into git as the canonical source.

Rationale for a SwiftUI renderer over an authored SVG: Apple's exact macOS Big Sur+ squircle path is hard to encode faithfully in SVG without the official Sketch/Figma template, but SwiftUI's `.continuous` corner style *is* that curve. Going through Swift avoids the SVG-rasterization step entirely and lets the squircle be Apple's own math rather than an approximation.

### Rasterization

`scripts/build-icon.sh` — shell script that:

1. Runs `swift scripts/render-icon.swift Resources/AppIcon/icon-1024.png` to produce the 1024 × 1024 source PNG.
2. Uses `sips` (built into macOS) to downscale the 1024 PNG to the other iconset sizes: 16, 32, 64, 128, 256, 512, and their `@2x` variants (10 files total — see `man iconutil`).
3. Packages the `.iconset` directory into `Resources/AppIcon/AppIcon.icns` via `iconutil -c icns`. The intermediate `.iconset` is deleted after packaging.

Both `icon-1024.png` **and** the generated `AppIcon.icns` are checked in. The script is idempotent but the build pipeline does not invoke it — regenerating the icon is a developer action, not a build-time step, so normal `swift build` and `scripts/build-app.sh` runs remain offline and dependency-free.

### App bundle integration

`scripts/build-app.sh` gains two changes:

1. After assembling the bundle, copy `Resources/AppIcon/AppIcon.icns` into `build/SpeakClean.app/Contents/Resources/AppIcon.icns`.
2. The generated `Info.plist` gains a `CFBundleIconFile` entry with value `AppIcon` (no `.icns` extension — Apple convention).

No code changes in the Swift targets. The app is `LSUIElement = true` (no Dock icon during use), but the bundle icon still shows in Finder, Launchpad, and when the Settings window is frontmost.

## Files touched

- **New:** `scripts/render-icon.swift`
- **New:** `scripts/build-icon.sh`
- **New:** `Resources/AppIcon/icon-1024.png` (generated, committed)
- **New:** `Resources/AppIcon/AppIcon.icns` (generated, committed)
- **Modified:** `scripts/build-app.sh` (copy icon, add `CFBundleIconFile`)
- **Modified:** `CLAUDE.md` — short note that the icon is authored in `scripts/render-icon.swift` and regenerated via `scripts/build-icon.sh`

## Testing

Primarily a visual check — unit tests are not meaningful for an icon artifact. The implementation plan should include:

1. Run `scripts/build-icon.sh` and inspect the 10 PNGs in the generated `.iconset` at 100% zoom to confirm the glyph is crisp (no sub-pixel blur) at 16, 32, and 64 px.
2. Run `scripts/build-app.sh`, then `open build/SpeakClean.app` — confirm the icon renders in the Finder window's title bar, in `⌘I` Get Info, and in Launchpad (`open /Applications/SpeakClean.app` if installed there).
3. Run `iconutil -c iconset build/SpeakClean.app/Contents/Resources/AppIcon.icns -o /tmp/verify.iconset` to unpack the built `.icns`, then inspect that all 10 expected PNG files are present at the correct dimensions.

No automated tests.

## Open questions

None — resolved during implementation:

- **Rasterization path:** replaced the planned SVG source + external rasterizer with a SwiftUI `ImageRenderer` script. Apple's squircle curve comes "for free" from `RoundedRectangle(style: .continuous)`.
- **Glyph stroke width:** left at the starting ~39 px. Reads clearly at ≥32 px; slightly muddy at 16 px but that's expected for Finder sidebar size — a tweak can come later if needed.

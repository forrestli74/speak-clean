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

`Resources/AppIcon/icon.svg` — hand-authored 1024 × 1024 SVG. Contains the squircle mask, the gradient, and the glyph. Checked into git as the canonical source.

Rationale for SVG (vs. a Swift renderer that reuses `NSBezierPath` like the menu bar): the squircle superellipse is the complicated part, and encoding it once as an SVG path is simpler than translating it to Core Graphics. The glyph itself is trivial in either format. Keeping the source human-readable makes it easy to tweak colors or proportions later without needing to run a Swift tool.

### Rasterization

`scripts/build-icon.sh` — shell script that:

1. Renders `Resources/AppIcon/icon.svg` to a 1024 × 1024 PNG using the system's `qlmanage` or, if unreliable, a zero-dep Swift one-liner that loads the SVG via `WebKit.WKWebView` and snapshots it. The implementation plan will pick the most reliable path available on macOS 26 without Homebrew dependencies.
2. Uses `sips` (built into macOS) to downscale the 1024 PNG to the other iconset sizes: 16, 32, 64, 128, 256, 512, and their `@2x` variants (see `man iconutil` for the exact 10-file naming convention).
3. Packages the `.iconset` directory into `Resources/AppIcon/AppIcon.icns` via `iconutil -c icns`.

Both the source SVG **and** the generated `AppIcon.icns` are checked in. The script is idempotent and documented, but the build pipeline does not invoke it — regenerating the icon is a developer action, not a build-time step, so normal `swift build` and `scripts/build-app.sh` runs remain offline and dependency-free.

### App bundle integration

`scripts/build-app.sh` gains two changes:

1. After assembling the bundle, copy `Resources/AppIcon/AppIcon.icns` into `build/SpeakClean.app/Contents/Resources/AppIcon.icns`.
2. The generated `Info.plist` gains a `CFBundleIconFile` entry with value `AppIcon` (no `.icns` extension — Apple convention).

No code changes in the Swift targets. The app is `LSUIElement = true` (no Dock icon during use), but the bundle icon still shows in Finder, Launchpad, and when the Settings window is frontmost.

## Files touched

- **New:** `Resources/AppIcon/icon.svg`
- **New:** `Resources/AppIcon/AppIcon.icns` (generated, committed)
- **New:** `scripts/build-icon.sh`
- **Modified:** `scripts/build-app.sh` (copy icon, add `CFBundleIconFile`)
- **Modified:** `.gitignore` if needed (keep the intermediate `.iconset` directory out of git)
- **Modified:** `CLAUDE.md` — short note that the icon is authored in `Resources/AppIcon/icon.svg` and regenerated via `scripts/build-icon.sh`

## Testing

Primarily a visual check — unit tests are not meaningful for an icon artifact. The implementation plan should include:

1. Run `scripts/build-icon.sh` and inspect the 10 PNGs in the generated `.iconset` at 100% zoom to confirm the glyph is crisp (no sub-pixel blur) at 16, 32, and 64 px.
2. Run `scripts/build-app.sh`, then `open build/SpeakClean.app` — confirm the icon renders in the Finder window's title bar, in `⌘I` Get Info, and in Launchpad (`open /Applications/SpeakClean.app` if installed there).
3. Run `iconutil -c iconset build/SpeakClean.app/Contents/Resources/AppIcon.icns -o /tmp/verify.iconset` to unpack the built `.icns`, then inspect that all 10 expected PNG files are present at the correct dimensions.

No automated tests.

## Open questions

None at spec time. The implementation plan resolves:

- Exact SVG → PNG rasterization path (whether `qlmanage` is reliable on macOS 26, or if a small inline Swift helper is cleaner).
- Final glyph stroke width at 1024 px (tuned so that the 16 px rasterization still reads — starting point ~39 px, likely to be bumped to ~44–50 px after a visual check at small sizes).

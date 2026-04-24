# Release Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship signed DMG builds of SpeakClean from GitHub Actions using the existing self-signed "SpeakClean Dev" certificate so that end users install once, grant TCC permissions once, and future updates preserve those grants automatically.

**Architecture:** A single workflow file fires on `v*` tag push (or manual `workflow_dispatch`). It imports the cert from a `.p12` base64-encoded GitHub secret into a temporary keychain, runs the existing `scripts/build-app.sh` with `SIGN_ID="SpeakClean Dev"`, wraps the signed `.app` in a flat DMG via `hdiutil` named `SpeakClean.dmg` (no version in filename — so GitHub's `/releases/latest/download/SpeakClean.dmg` redirect stays stable), verifies the new bundle's designated requirement matches the previous release's (guarding against accidental cert rotation that would break TCC), and attaches the DMG to a GitHub Release. One-time setup: export the existing local cert as `.p12`, base64-encode it, and paste into two GitHub secrets.

**Tech Stack:** GitHub Actions (macos-15 runner), `security` / `codesign` / `hdiutil` (system tools, no Homebrew deps), `gh` CLI (preinstalled on runners), bash.

**Distribution endpoint:** `https://github.com/forrestli74/speak-clean/releases/latest/download/SpeakClean.dmg`

**Out of scope for this plan:** Sparkle auto-updates, notarization, Homebrew tap.

**Icon:** already committed. `scripts/build-app.sh` copies `Resources/AppIcon/AppIcon.icns` into `build/SpeakClean.app/Contents/Resources/AppIcon.icns` and writes `CFBundleIconFile = AppIcon`. The workflow reuses the existing script, so the icon flows into every release DMG automatically. A verification step (Task 6) confirms the icon is present in the downloaded DMG.

---

## File Structure

- Create: `.github/workflows/release.yml` — the release workflow
- Create: `scripts/make-dmg.sh` — wraps a signed `.app` in `SpeakClean.dmg`
- Create: `scripts/export-signing-cert.sh` — maintainer one-time helper to export the existing keychain cert as base64 `.p12`
- Modify: `scripts/build-app.sh` — minor: ensure the Info.plist version is sourced from the env `VERSION` var (already true) and that an unset `SIGN_ID` in CI is an error rather than falling back to ad-hoc
- Modify: `README.md` — add "Download" section with the stable URL and install instructions (right-click → Open, drag to Applications)

---

## Task 1: Add `scripts/export-signing-cert.sh` maintainer helper

**Files:**
- Create: `scripts/export-signing-cert.sh`

**Why first:** GitHub Actions can't sign without the cert. The maintainer must export the existing `SpeakClean Dev` identity from their login keychain as a `.p12`, base64-encode it, and paste that into two GitHub Actions secrets (`SIGNING_CERT_P12` and `SIGNING_CERT_PASSWORD`). This script automates the export side.

- [ ] **Step 1: Create the script**

Write `scripts/export-signing-cert.sh`:

```bash
#!/usr/bin/env bash
#
# Export the "SpeakClean Dev" code-signing identity from the login
# keychain as a password-protected .p12, base64-encode it, and print
# the two values to paste into GitHub Actions secrets:
#
#   SIGNING_CERT_P12       (the base64 string)
#   SIGNING_CERT_PASSWORD  (the password below)
#
# Run once when setting up CI, or again when rotating the cert
# (see docs/superpowers/plans/2026-04-23-release-workflow.md).
#
set -e

IDENTITY_NAME="${IDENTITY_NAME:-SpeakClean Dev}"
OUT_P12="${OUT_P12:-/tmp/speakclean-signing.p12}"
P12_PASSWORD="${P12_PASSWORD:-}"

if [[ -z "$P12_PASSWORD" ]]; then
    P12_PASSWORD="$(uuidgen)"
fi

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY_NAME"; then
    echo "error: no code-signing identity named '$IDENTITY_NAME' in keychain" >&2
    echo "hint: generate one with openssl + keychain import, or set IDENTITY_NAME=..." >&2
    exit 1
fi

rm -f "$OUT_P12"

security export \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -t identities \
    -f pkcs12 \
    -P "$P12_PASSWORD" \
    -o "$OUT_P12"

if [[ ! -s "$OUT_P12" ]]; then
    echo "error: export produced empty file $OUT_P12" >&2
    exit 1
fi

echo ""
echo "==> .p12 written to $OUT_P12"
echo ""
echo "Paste these two values into GitHub Actions secrets"
echo "(Repo → Settings → Secrets and variables → Actions → New repository secret):"
echo ""
echo "  Name:  SIGNING_CERT_P12"
echo "  Value: (the base64 string below, one line, no leading/trailing newline)"
echo ""
base64 -i "$OUT_P12"
echo ""
echo "  Name:  SIGNING_CERT_PASSWORD"
echo "  Value: $P12_PASSWORD"
echo ""
echo "After pasting, delete the local file: rm $OUT_P12"
```

- [ ] **Step 2: Make it executable and smoke test**

Run:
```bash
chmod +x scripts/export-signing-cert.sh
scripts/export-signing-cert.sh
```

Expected: a base64 blob is printed, followed by a UUID password. The `SpeakClean Dev` identity must already be in the login keychain for this to succeed (it already is on this developer's machine from earlier ad-hoc testing). If the script is ever run on a fresh machine without the cert, it exits with a clear error.

**Note to the maintainer running this:** this script exports a secret key. Do not commit the output. Delete `/tmp/speakclean-signing.p12` when done.

- [ ] **Step 3: Commit**

```bash
git add scripts/export-signing-cert.sh
git commit -m "build: add helper to export signing cert as .p12 for CI"
```

---

## Task 2: Add `scripts/make-dmg.sh` DMG packaging helper

**Files:**
- Create: `scripts/make-dmg.sh`

**Why:** Both local builds and CI need to produce a DMG with a stable name `SpeakClean.dmg`. Using `hdiutil` avoids a Homebrew dependency on `create-dmg`. The DMG is flat (no custom background, no icon positioning) — we can upgrade later if we want branding.

- [ ] **Step 1: Create the script**

Write `scripts/make-dmg.sh`:

```bash
#!/usr/bin/env bash
#
# Wrap a signed SpeakClean.app in a compressed DMG.
#
# Usage:
#   scripts/make-dmg.sh [path/to/SpeakClean.app]
#
# Default app path: build/SpeakClean.app
# Output: build/SpeakClean.dmg
#
# The output filename is intentionally version-free so that
# https://github.com/<user>/<repo>/releases/latest/download/SpeakClean.dmg
# always resolves to the newest release's asset.
#
set -e

APP_PATH="${1:-build/SpeakClean.app}"
OUT_DMG="build/SpeakClean.dmg"
VOL_NAME="SpeakClean"
STAGING_DIR="build/dmg-staging"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

rm -rf "$STAGING_DIR" "$OUT_DMG"
mkdir -p "$STAGING_DIR"

# Copy the .app with `ditto` so symlinks, extended attributes, and the
# code signature survive intact. Also drop a symlink to /Applications
# so the mounted volume offers drag-to-install.
ditto "$APP_PATH" "$STAGING_DIR/SpeakClean.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUT_DMG"

rm -rf "$STAGING_DIR"

echo ""
echo "built $OUT_DMG"
```

- [ ] **Step 2: Make it executable and smoke test locally**

Run:
```bash
chmod +x scripts/make-dmg.sh
scripts/build-app.sh
scripts/make-dmg.sh
ls -lh build/SpeakClean.dmg
```

Expected: `build/SpeakClean.dmg` is produced, a few MB. Mount with `open build/SpeakClean.dmg` → a Finder window shows `SpeakClean.app` next to an `Applications` shortcut. Eject when done.

Verify the signature survived packaging:
```bash
hdiutil attach build/SpeakClean.dmg -mountpoint /tmp/sc-mnt -nobrowse -quiet
codesign --verify --deep --strict --verbose=4 /tmp/sc-mnt/SpeakClean.app
hdiutil detach /tmp/sc-mnt -quiet
```

Expected: `/tmp/sc-mnt/SpeakClean.app: valid on disk` and `satisfies its Designated Requirement`.

- [ ] **Step 3: Commit**

```bash
git add scripts/make-dmg.sh
git commit -m "build: add hdiutil-based DMG packaging script"
```

---

## Task 3: Tighten `scripts/build-app.sh` for CI use

**Files:**
- Modify: `scripts/build-app.sh`

**Why:** The current script falls back to ad-hoc signing when `SIGN_ID` is unset. In CI we want that to be a fatal error so a misconfigured workflow doesn't silently ship a non-TCC-persistent build. We add a `REQUIRE_SIGN_ID=1` opt-in that CI sets; the local flow stays unchanged.

- [ ] **Step 1: Replace the signing block**

In `scripts/build-app.sh`, locate the block starting at the line `SIGN_ID="${SIGN_ID:-}"` (around line 83) and replace it with:

```bash
SIGN_ID="${SIGN_ID:-}"
REQUIRE_SIGN_ID="${REQUIRE_SIGN_ID:-0}"
if [[ -n "$SIGN_ID" ]]; then
    echo "==> codesign with '$SIGN_ID'"
    codesign --force --deep --sign "$SIGN_ID" "$APP_DIR"
elif [[ "$REQUIRE_SIGN_ID" == "1" ]]; then
    echo "error: REQUIRE_SIGN_ID=1 but SIGN_ID is empty — refusing to ad-hoc sign" >&2
    exit 1
else
    echo "==> ad-hoc codesign (set SIGN_ID='Apple Development: ...' for a stable identity)"
    codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --verbose=2 "$APP_DIR"
```

- [ ] **Step 2: Verify local build still works**

Run:
```bash
scripts/build-app.sh
```

Expected: ad-hoc signing path, exit 0. (No `SIGN_ID`, no `REQUIRE_SIGN_ID`, so fallback applies.)

Run:
```bash
REQUIRE_SIGN_ID=1 scripts/build-app.sh
```

Expected: exits with `error: REQUIRE_SIGN_ID=1 but SIGN_ID is empty`.

Run:
```bash
SIGN_ID="SpeakClean Dev" scripts/build-app.sh
```

Expected: signed with "SpeakClean Dev", exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/build-app.sh
git commit -m "build: add REQUIRE_SIGN_ID guard for CI"
```

---

## Task 4: Write the release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Why:** The workflow is the operational core — it fires on tag push (or manual dispatch), imports the cert, builds and signs the app, verifies the designated requirement matches the last release (so an accidental cert change fails fast instead of invalidating every user's TCC grants), packages into `SpeakClean.dmg`, and attaches it to a GitHub Release.

- [ ] **Step 1: Ensure the `.github/workflows` directory exists**

Run:
```bash
mkdir -p .github/workflows
```

- [ ] **Step 2: Write the workflow file**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to build (e.g., 0.2.0). Only used when dispatching manually.'
        required: true

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  build:
    runs-on: macos-15
    timeout-minutes: 20
    permissions:
      contents: write
    env:
      ALLOW_SIGNING_IDENTITY_CHANGE: ${{ vars.ALLOW_SIGNING_IDENTITY_CHANGE == 'true' && 'true' || 'false' }}

    steps:
      - name: Resolve version
        id: version
        run: |
          set -euo pipefail
          if [[ "${{ github.event_name }}" == "push" ]]; then
            TAG="${GITHUB_REF#refs/tags/}"
            VERSION="${TAG#v}"
          else
            VERSION="${{ github.event.inputs.version }}"
          fi
          if [[ -z "$VERSION" ]]; then
            echo "::error::Could not determine version"
            exit 1
          fi
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "tag=v$VERSION" >> "$GITHUB_OUTPUT"
          echo "Building v$VERSION"

      - name: Checkout
        uses: actions/checkout@v4

      - name: Select Xcode (matches local toolchain)
        run: sudo xcode-select -s /Applications/Xcode_26.app/Contents/Developer

      - name: Import signing certificate into temp keychain
        env:
          SIGNING_CERT_P12: ${{ secrets.SIGNING_CERT_P12 }}
          SIGNING_CERT_PASSWORD: ${{ secrets.SIGNING_CERT_PASSWORD }}
        run: |
          set -euo pipefail
          if [[ -z "$SIGNING_CERT_P12" ]] || [[ -z "$SIGNING_CERT_PASSWORD" ]]; then
            echo "::error::SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD secrets are required"
            exit 1
          fi

          KEYCHAIN_PATH="$RUNNER_TEMP/speakclean-signing.keychain-db"
          KEYCHAIN_PASSWORD="$(uuidgen)"
          echo "$SIGNING_CERT_P12" | base64 --decode > "$RUNNER_TEMP/signing.p12"

          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          security import "$RUNNER_TEMP/signing.p12" \
            -P "$SIGNING_CERT_PASSWORD" \
            -A -t cert -f pkcs12 \
            -k "$KEYCHAIN_PATH" \
            -T /usr/bin/codesign

          # Put the temp keychain in the user search list so codesign finds it.
          # (On the CI runner, we don't need the login keychain — the only
          # identity we want is the one we just imported.)
          security list-keychain -d user -s "$KEYCHAIN_PATH"

          security set-key-partition-list \
            -S apple-tool:,apple: \
            -s -k "$KEYCHAIN_PASSWORD" \
            "$KEYCHAIN_PATH"

          rm -f "$RUNNER_TEMP/signing.p12"

          echo "Signing identities in temp keychain:"
          security find-identity -v -p codesigning "$KEYCHAIN_PATH"

      - name: Build signed .app
        env:
          VERSION: ${{ steps.version.outputs.version }}
          SIGN_ID: SpeakClean Dev
          REQUIRE_SIGN_ID: '1'
        run: |
          set -euo pipefail
          scripts/build-app.sh

      - name: Verify signature
        run: |
          set -euo pipefail
          codesign --verify --deep --strict --verbose=4 build/SpeakClean.app
          codesign -dv --verbose=4 build/SpeakClean.app

      - name: Capture candidate designated requirement
        run: |
          set -euo pipefail
          mkdir -p build
          codesign -dr - build/SpeakClean.app 2>&1 \
            | sed -n 's/^designated => //p' \
            > build/candidate-dr.txt
          if [[ ! -s build/candidate-dr.txt ]]; then
            echo "::error::Failed to extract candidate designated requirement"
            exit 1
          fi
          echo "Candidate DR:"
          cat build/candidate-dr.txt

      - name: Compare DR against previous release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          PREV_TAG="$(gh release list --limit 1 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
          if [[ -z "$PREV_TAG" ]] || [[ "$PREV_TAG" == "null" ]]; then
            echo "No previous release found — skipping DR comparison."
            exit 0
          fi

          echo "Comparing against $PREV_TAG"
          mkdir -p build/previous
          if ! gh release download "$PREV_TAG" -p 'SpeakClean.dmg' -D build/previous; then
            echo "::warning::Previous release has no SpeakClean.dmg asset — skipping DR comparison."
            exit 0
          fi

          MOUNT="$(mktemp -d /tmp/sc-prev.XXXXXX)"
          trap 'hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rm -rf "$MOUNT"' EXIT
          hdiutil attach build/previous/SpeakClean.dmg -mountpoint "$MOUNT" -nobrowse -quiet

          if [[ ! -d "$MOUNT/SpeakClean.app" ]]; then
            echo "::warning::Previous DMG has no SpeakClean.app at root — skipping DR comparison."
            exit 0
          fi

          codesign -dr - "$MOUNT/SpeakClean.app" 2>&1 \
            | sed -n 's/^designated => //p' \
            > build/previous-dr.txt

          if [[ ! -s build/previous-dr.txt ]]; then
            echo "::warning::Failed to extract previous DR — skipping comparison."
            exit 0
          fi

          echo "Previous DR:"
          cat build/previous-dr.txt

          if diff -u build/previous-dr.txt build/candidate-dr.txt; then
            echo "Designated requirement matches previous release."
            exit 0
          fi

          if [[ "$ALLOW_SIGNING_IDENTITY_CHANGE" == "true" ]]; then
            echo "::warning::ALLOW_SIGNING_IDENTITY_CHANGE=true — proceeding despite DR drift"
            exit 0
          fi

          echo "::error::Candidate DR differs from previous release. Existing users would lose TCC grants. Set repo variable ALLOW_SIGNING_IDENTITY_CHANGE=true only for intentional cert rotations."
          exit 1

      - name: Package DMG
        run: scripts/make-dmg.sh build/SpeakClean.app

      - name: Compute SHA256
        id: sha
        run: |
          set -euo pipefail
          SHA="$(shasum -a 256 build/SpeakClean.dmg | awk '{print $1}')"
          echo "sha256=$SHA" >> "$GITHUB_OUTPUT"
          echo "SHA-256: $SHA"

      - name: Create or update GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.version.outputs.tag }}
          name: ${{ steps.version.outputs.tag }}
          draft: false
          prerelease: false
          generate_release_notes: true
          files: build/SpeakClean.dmg
          body: |
            **Download:** https://github.com/${{ github.repository }}/releases/latest/download/SpeakClean.dmg

            **SHA-256:** `${{ steps.sha.outputs.sha256 }}`

            **First install:** open the DMG, drag `SpeakClean.app` to `Applications`, then right-click the app in `/Applications` and choose **Open** to bypass the Gatekeeper warning (one-time, per install).

            **Updates:** download and replace. macOS Accessibility and Microphone permissions carry over automatically because the app is signed with a stable self-signed certificate.
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow with DR drift guard"
```

---

## Task 5: One-time CI setup (manual steps, performed by the maintainer)

**Files:** none (these are manual GitHub UI / local shell actions)

**Why:** The workflow needs three repo-level settings before it can successfully run: two secrets for the signing cert, and (optionally) a repo variable gate for cert rotation.

- [ ] **Step 1: Export the cert**

Run locally:
```bash
scripts/export-signing-cert.sh
```

Copy the base64 blob and the password it prints.

- [ ] **Step 2: Create GitHub secrets**

In the GitHub repo: **Settings → Secrets and variables → Actions → New repository secret**

Create two secrets:
- `SIGNING_CERT_P12` = (the base64 blob from Step 1)
- `SIGNING_CERT_PASSWORD` = (the password from Step 1)

- [ ] **Step 3: Delete the local `.p12`**

```bash
rm -f /tmp/speakclean-signing.p12
```

- [ ] **Step 4: (Optional) Repo variable for future cert rotation**

Don't set this now. When you *do* need to rotate the cert (e.g., CN changes, key leaked), go to **Settings → Secrets and variables → Actions → Variables tab** and set `ALLOW_SIGNING_IDENTITY_CHANGE=true` for one release. Remove immediately after.

---

## Task 6: End-to-end dry run via `workflow_dispatch`

**Files:** none (GitHub UI + local verification)

**Why:** Before tagging the first real release, fire the workflow manually to confirm cert import, build, and DMG upload all work. Using dispatch avoids creating a real tag if something goes wrong.

- [ ] **Step 1: Push the branch**

```bash
git push origin main
```

- [ ] **Step 2: Trigger a dispatch run**

Go to **GitHub → Actions → Release → Run workflow**. Enter version `0.1.0-dryrun` (or similar). Click Run.

- [ ] **Step 3: Watch the logs**

Expected observations:
- "Signing identities in temp keychain" lists `"SpeakClean Dev"` with exactly `1 valid identities found`.
- `codesign --verify` passes with `valid on disk` and `satisfies its Designated Requirement`.
- "Compare DR against previous release" logs `No previous release found — skipping DR comparison.` (because this is the first run).
- A GitHub Release `v0.1.0-dryrun` is created with `SpeakClean.dmg` attached.

- [ ] **Step 4: Verify the download**

On your local machine:
```bash
curl -sL -o /tmp/sc-dryrun.dmg \
  "https://github.com/forrestli74/speak-clean/releases/latest/download/SpeakClean.dmg"
hdiutil attach /tmp/sc-dryrun.dmg -mountpoint /tmp/sc-dr -nobrowse -quiet
codesign -dvv /tmp/sc-dr/SpeakClean.app 2>&1 | grep -E 'Authority|Identifier|TeamIdentifier'
codesign -dr - /tmp/sc-dr/SpeakClean.app
ls /tmp/sc-dr/SpeakClean.app/Contents/Resources/AppIcon.icns
/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" /tmp/sc-dr/SpeakClean.app/Contents/Info.plist
hdiutil detach /tmp/sc-dr -quiet
rm /tmp/sc-dryrun.dmg
```

Expected:
- `Authority=SpeakClean Dev` (self-signed root)
- `Identifier=io.github.forrestli74.speak-clean`
- `designated => identifier "io.github.forrestli74.speak-clean" and certificate leaf = H"94dfd7e2d6c96d9126c46652102e89e40e2e72d8"` (or whatever cert hash the local machine's `SpeakClean Dev` has)
- `AppIcon.icns` exists in the bundle's `Contents/Resources`
- `CFBundleIconFile` plist key prints `AppIcon`

- [ ] **Step 5: Delete the dry-run release**

On GitHub: go to the Releases page, click the `v0.1.0-dryrun` release, click **Delete release**. Then delete the orphaned tag:
```bash
git push origin --delete v0.1.0-dryrun
```

---

## Task 7: Update README with download instructions

**Files:**
- Modify: `README.md`

**Why:** Users reading the repo need the stable download URL, the one-time Gatekeeper workaround, and a plain statement about what TCC permissions to expect.

- [ ] **Step 1: Add a "Download" section near the top of README.md**

Insert (or replace an existing Install section with) the following, placed just after the project summary / header:

```markdown
## Download

[**Download SpeakClean.dmg** (latest)](https://github.com/forrestli74/speak-clean/releases/latest/download/SpeakClean.dmg)

### First-time install

1. Open the DMG and drag `SpeakClean.app` to `Applications`.
2. In `/Applications`, **right-click** `SpeakClean.app` → **Open**. Click **Open** in the "Apple cannot verify..." dialog. (One-time per install — standard macOS flow for apps not on the App Store.)
3. On first launch, grant:
    - **Microphone** permission (prompted automatically)
    - **Accessibility** permission (required for the global hotkey and paste — add SpeakClean in System Settings → Privacy & Security → Accessibility)

### Updates

Download the new DMG from the same URL and drag the new `.app` into `/Applications`, replacing the old one. Your permission grants carry over automatically — no re-granting needed.

### Requirements

macOS 26+, Apple Silicon. Ollama (`brew install ollama`) + `ollama pull gemma4:e2b` provides the local cleanup model.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add download and install instructions with stable URL"
```

---

## Task 8: Cut the first real release

**Files:** none (tag + push)

**Why:** Once dry-run passes and the README is committed, tagging `v0.1.0` (or whatever starting version you pick) triggers the first real release end-to-end. This also seeds the DR-drift comparison baseline for every future release.

- [ ] **Step 1: Pick a starting version**

`0.1.0` (matches the default in `scripts/build-app.sh`) is a reasonable start. Adjust to `0.2.0` if you want to mark the Settings UI milestone distinctly.

- [ ] **Step 2: Tag and push**

```bash
git tag v0.1.0
git push origin v0.1.0
```

- [ ] **Step 3: Watch the release**

Go to **Actions → Release** and confirm the run completes green. Expected runtime: ~6–10 minutes (Swift build dominates).

- [ ] **Step 4: Verify from a fresh directory**

```bash
cd /tmp
curl -sL -o SpeakClean.dmg \
  "https://github.com/forrestli74/speak-clean/releases/latest/download/SpeakClean.dmg"
open SpeakClean.dmg
```

Drag the app to `/Applications`, right-click → Open, confirm the app launches and the menu bar icon appears. Permissions grants should NOT appear if this machine already trusts `SpeakClean Dev`; on a clean machine they'll appear once and then persist across future updates (that's the whole point).

---

## Risks and mitigations

- **Cert rotation invalidates all users' TCC grants.** Mitigation: DR drift guard in the workflow (Task 4). Any DR change fails the release unless `ALLOW_SIGNING_IDENTITY_CHANGE=true` is explicitly set. Rotation should be extremely rare.
- **`.p12` password or cert leaks.** Mitigation: secrets are never printed in logs (no `set -x` around the import); the decoded `.p12` is deleted immediately after `security import`. If a leak does occur, revoke locally, re-run `export-signing-cert.sh` with a fresh password, update secrets, and tag the next release with `ALLOW_SIGNING_IDENTITY_CHANGE=true`.
- **Gatekeeper UX on first install.** Mitigation: README tells users to right-click → Open. This is a one-time per-install action, not per-update. Alternative long-term fix: pay the $99/yr Apple Developer ID fee + notarize; the workflow already leaves room to add notarization steps later.
- **Homebrew Cask deprecation of unsigned/self-signed casks (Sep 2026).** Not addressed in this plan. If distribution via Homebrew is needed, revisit before the deadline — likely requires paying the $99/yr fee or coordinating with Cask maintainers.
- **GitHub-hosted macOS runner changes (Xcode version updates).** The `Select Xcode` step pins to `Xcode_26.app`. If the runner image changes what's preinstalled, that step will fail loudly rather than silently building with the wrong toolchain.

---

## Follow-ups (out of scope for this plan)

- Sparkle in-app auto-updates. Users currently self-update by re-downloading. Sparkle is the idiomatic macOS solution but adds signing complexity (EdDSA appcast signature on top of codesign).
- Notarization. If you later pay for an Apple Developer ID, add `xcrun notarytool submit --wait` after the DMG step and `xcrun stapler staple` to embed the notarization ticket. Gatekeeper will then launch the app without the right-click-Open dance.
- DMG branding (custom background image, icon positioning via `create-dmg`). The current plain `hdiutil` DMG is functional but unbranded.

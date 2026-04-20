# Settings UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native macOS Settings window for changing the global recording shortcut and the Ollama cleanup model, replacing the `defaults write` CLI path.

**Architecture:** A new SwiftUI `Settings` scene alongside the existing `MenuBarExtra`, opened from a new "Settings…" menu item. Two `TextField`s apply on commit; a "Reset to Defaults" button restores and applies the registered defaults. Shortcut text is validated against the existing `parsedShortcut` parser (extracted and generalized). Model text triggers `AppController.reset()` so availability re-checks flow through the existing error-surfacing path.

**Tech Stack:** SwiftUI (`Settings`, `MenuBarExtra`, `Form`, `TextField`), AppKit (`NSEvent` global/local monitors, preserved from current code), Swift Testing (`import Testing`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-04-20-settings-ui-design.md`

---

## Task 1: Extract `AppConfig.parse(_:)` and add default constants

**Files:**
- Modify: `Sources/speak-clean/PersonalLibrary.swift`
- Create: `Tests/SpeakCleanTests/AppConfigParseTests.swift`

**Why first:** The Settings view needs to validate arbitrary strings without writing to `AppConfig.shortcut`. The existing `parsedShortcut` only parses the stored value. Extracting `parse(_:)` as a static function also gives us a direct unit-test surface. Adding named default constants lets the "Reset to Defaults" button reference them from one source of truth.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SpeakCleanTests/AppConfigParseTests.swift`:

```swift
import Testing
import AppKit
@testable import speak_clean

@Suite("AppConfig.parse")
@MainActor
struct AppConfigParseTests {

    @Test func validBasic() {
        let r = AppConfig.parse("option+space")
        #expect(r?.modifiers == .option)
        #expect(r?.keyCode == 49)
    }

    @Test func uppercaseNormalized() {
        let r = AppConfig.parse("OPTION+SPACE")
        #expect(r?.modifiers == .option)
        #expect(r?.keyCode == 49)
    }

    @Test func whitespaceAroundTokens() {
        let r = AppConfig.parse("option + space")
        #expect(r?.modifiers == .option)
        #expect(r?.keyCode == 49)
    }

    @Test func multipleModifiers() {
        let r = AppConfig.parse("cmd+shift+d")
        #expect(r?.modifiers == [.command, .shift])
        #expect(r?.keyCode == 2)
    }

    @Test func aliasesAccepted() {
        #expect(AppConfig.parse("alt+space")?.modifiers == .option)
        #expect(AppConfig.parse("ctrl+space")?.modifiers == .control)
        #expect(AppConfig.parse("command+space")?.modifiers == .command)
    }

    @Test func rejectsNoModifier() {
        #expect(AppConfig.parse("space") == nil)
    }

    @Test func rejectsUnknownModifier() {
        #expect(AppConfig.parse("fn+space") == nil)
    }

    @Test func rejectsUnknownKey() {
        #expect(AppConfig.parse("option+foo") == nil)
    }

    @Test func rejectsEmpty() {
        #expect(AppConfig.parse("") == nil)
    }

    @Test func rejectsTrailingPlus() {
        #expect(AppConfig.parse("option+") == nil)
    }

    @Test func defaultShortcutParses() {
        #expect(AppConfig.parse(AppConfig.defaultShortcut) != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppConfigParseTests`
Expected: compilation failure — `AppConfig.parse(_:)` and `AppConfig.defaultShortcut` don't exist yet.

- [ ] **Step 3: Refactor `PersonalLibrary.swift`**

In `Sources/speak-clean/PersonalLibrary.swift`:

Add default constants near the top of the enum, just above the `defaults` static:

```swift
/// Registered default for the global recording shortcut.
/// Source of truth for both `defaults.register(...)` and the
/// "Reset to Defaults" button in the Settings view.
static let defaultShortcut = "option+space"

/// Registered default for the Ollama cleanup model tag.
static let defaultCleanupModel = "gemma4:e2b"
```

Change the `defaults.register(defaults:)` call to reference them:

```swift
private static let defaults: UserDefaults = {
    let d = UserDefaults(suiteName: suiteName)!
    d.register(defaults: [
        "shortcut": defaultShortcut,
        "cleanupModel": defaultCleanupModel,
    ])
    return d
}()
```

Replace the existing `parsedShortcut` computed property with a thin wrapper over a new `parse(_:)` function. The new `parse` trims whitespace per token so `"option + space"` parses:

```swift
/// Parse an arbitrary shortcut string like `"cmd+shift+d"` into an
/// `(NSEvent.ModifierFlags, keyCode)` pair. Returns `nil` if the
/// string has no modifiers, uses unknown modifier names, or uses an
/// unknown key. Case-insensitive; tolerant of whitespace around `+`.
///
/// Used by both `parsedShortcut` (on the stored value) and the
/// Settings view (on candidate input before persisting).
static func parse(_ s: String) -> (modifiers: NSEvent.ModifierFlags, keyCode: UInt16)? {
    let parts = s.lowercased()
        .split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard parts.count >= 2 else { return nil }
    var modifiers: NSEvent.ModifierFlags = []
    for part in parts.dropLast() {
        switch part {
        case "option", "alt": modifiers.insert(.option)
        case "command", "cmd": modifiers.insert(.command)
        case "control", "ctrl": modifiers.insert(.control)
        case "shift": modifiers.insert(.shift)
        default: return nil
        }
    }
    guard let keyCode = keyCodeMap[parts.last!] else { return nil }
    return (modifiers, keyCode)
}

/// Parse `shortcut` (the stored preference) into an
/// `(NSEvent.ModifierFlags, keyCode)` pair. Returns `nil` if the
/// stored string is malformed — `installHotkey()` treats this as a
/// no-op and logs a warning.
static var parsedShortcut: (modifiers: NSEvent.ModifierFlags, keyCode: UInt16)? {
    parse(shortcut)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppConfigParseTests`
Expected: all 11 tests pass.

- [ ] **Step 5: Run the full test suite to catch regressions**

Run: `swift test`
Expected: all tests pass. `parsedShortcut` now delegates to `parse(shortcut)`, so any hotkey-install path that read `parsedShortcut` still works, but now also accepts whitespace-padded tokens.

- [ ] **Step 6: Commit**

```bash
git add Sources/speak-clean/PersonalLibrary.swift Tests/SpeakCleanTests/AppConfigParseTests.swift
git -c commit.gpgsign=false commit -m "refactor: extract AppConfig.parse and add default constants"
```

---

## Task 2: Add `reinstallHotkey()` to RecordingCoordinator

**Files:**
- Modify: `Sources/speak-clean/RecordingCoordinator.swift`

**Why no TDD:** `NSEvent.addGlobalMonitorForEvents` and `addLocalMonitorForEvents` require a live `NSApplication`; they cannot be exercised in a unit test without a real run loop. Manual verification via `swift run speak-clean` instead. This task is refactor-only — no behavior change until Task 4 calls it.

- [ ] **Step 1: Extract `removeHotkey()` helper and add `reinstallHotkey()`**

In `Sources/speak-clean/RecordingCoordinator.swift`, find the `// MARK: - Hotkey` section. Add a `removeHotkey()` private helper and a public `reinstallHotkey()` method right above `installHotkey()`:

```swift
/// Tear down any installed global/local `NSEvent` monitors.
/// Safe to call multiple times; idempotent because the handles are
/// nil'd after removal.
private func removeHotkey() {
    if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    if let m = localMonitor  { NSEvent.removeMonitor(m);  localMonitor  = nil }
}

/// Tear down and reinstall the hotkey monitors. Called from the
/// Settings view after the user commits a new `AppConfig.shortcut`,
/// and from the "Reset to Defaults" path.
func reinstallHotkey() {
    removeHotkey()
    installHotkey()
}
```

- [ ] **Step 2: Replace the deinit body with `removeHotkey()`**

Find the existing `deinit` (around line 80):

```swift
@MainActor deinit {
    if let m = globalMonitor { NSEvent.removeMonitor(m) }
    if let m = localMonitor { NSEvent.removeMonitor(m) }
}
```

Replace with:

```swift
@MainActor deinit {
    removeHotkey()
}
```

- [ ] **Step 3: Build and run the existing test suite**

Run: `swift build`
Expected: build succeeds.

Run: `swift test`
Expected: all tests still pass. No behavior change — `deinit` still tears down monitors; `reinstallHotkey()` is not yet called anywhere.

- [ ] **Step 4: Commit**

```bash
git add Sources/speak-clean/RecordingCoordinator.swift
git -c commit.gpgsign=false commit -m "refactor: extract removeHotkey, add reinstallHotkey to RecordingCoordinator"
```

---

## Task 3: Create `SettingsView`

**Files:**
- Create: `Sources/speak-clean/SettingsView.swift`

**Why no TDD:** SwiftUI views inside a `Settings` scene have no practical programmatic driver. The parser is already covered by Task 1's tests; the view-logic (apply-on-commit, red border, reset button) is verified manually in Task 6.

- [ ] **Step 1: Create the SettingsView file**

Create `Sources/speak-clean/SettingsView.swift`:

```swift
import SwiftUI
import AppKit

/// Minimal Settings pane: a `Form` with two text fields and a
/// "Reset to Defaults" button. Each field commits on Return or
/// loss of focus (no Save button). Invalid shortcut input keeps
/// its red-border state and does not persist; the previously
/// installed shortcut keeps working. Model changes trigger a full
/// availability re-check via `AppController.reset()`.
///
/// The view is instantiated inside the `Settings { ... }` scene in
/// `SpeakCleanApp.body` and receives the shared `RecordingCoordinator`
/// by reference.
@MainActor
struct SettingsView: View {
    /// The app's single coordinator. Used to reinstall the hotkey
    /// monitor after a shortcut change and to trigger an availability
    /// re-check after a model change. Not observed — the view does
    /// not render from coordinator state.
    let coordinator: RecordingCoordinator

    @State private var shortcutText: String = AppConfig.shortcut
    @State private var modelText: String = AppConfig.cleanupModel

    /// Parse-based validity. `nil` means the user hasn't typed a
    /// recognizable shortcut yet; we show a red border and do not
    /// persist on commit.
    private var shortcutIsValid: Bool {
        AppConfig.parse(shortcutText.trimmingCharacters(in: .whitespaces)) != nil
    }

    var body: some View {
        Form {
            LabeledContent("Shortcut") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("option+space", text: $shortcutText)
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.red, lineWidth: shortcutIsValid ? 0 : 1)
                        )
                        .onSubmit { commitShortcut() }
                    if !shortcutIsValid {
                        Text("Use e.g. option+space — one or more modifiers plus a known key")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            LabeledContent("Model") {
                TextField("gemma4:e2b", text: $modelText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitModel() }
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") { resetToDefaults() }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func commitShortcut() {
        let trimmed = shortcutText.trimmingCharacters(in: .whitespaces)
        guard AppConfig.parse(trimmed) != nil else { return }
        AppConfig.shortcut = trimmed
        shortcutText = trimmed
        coordinator.reinstallHotkey()
    }

    private func commitModel() {
        let trimmed = modelText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            modelText = AppConfig.cleanupModel
            return
        }
        AppConfig.cleanupModel = trimmed
        modelText = trimmed
        Task { await coordinator.reset() }
    }

    private func resetToDefaults() {
        AppConfig.shortcut = AppConfig.defaultShortcut
        AppConfig.cleanupModel = AppConfig.defaultCleanupModel
        shortcutText = AppConfig.defaultShortcut
        modelText = AppConfig.defaultCleanupModel
        coordinator.reinstallHotkey()
        Task { await coordinator.reset() }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds. The file compiles but is unused until Task 4 wires it in.

- [ ] **Step 3: Commit**

```bash
git add Sources/speak-clean/SettingsView.swift
git -c commit.gpgsign=false commit -m "feat: add SettingsView with shortcut and model fields"
```

---

## Task 4: Wire the Settings scene into `SpeakCleanApp`

**Files:**
- Modify: `Sources/speak-clean/SpeakCleanApp.swift`

- [ ] **Step 1: Add the Settings scene and menu button**

In `Sources/speak-clean/SpeakCleanApp.swift`, replace the `var body: some Scene` block (lines 94–110) with:

```swift
var body: some Scene {
    MenuBarExtra {
        if case .notReady(let reason) = coordinator.controller.state {
            Text(reason).foregroundStyle(.secondary)
            Divider()
        }
        SettingsMenuButton()
        Button("Edit Dictionary…") { coordinator.editDictionary() }
        Button("Reset") { Task { await coordinator.reset() } }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    } label: {
        Image(nsImage: coordinator.statusImage)
            .renderingMode(.template)
            .frame(width: 18, height: 18)
    }
    .menuBarExtraStyle(.menu)

    Settings {
        SettingsView(coordinator: coordinator)
    }
}
```

- [ ] **Step 2: Add the `SettingsMenuButton` helper**

`@Environment(\.openSettings)` can only be read from inside a SwiftUI `View`, not from a `Scene`'s content closure directly. Add a small helper view at the bottom of `SpeakCleanApp.swift`:

```swift
/// Menu-bar button that opens the Settings scene via SwiftUI's
/// `openSettings` action. Split out from the parent `Scene`'s content
/// closure because `@Environment(\.openSettings)` requires a `View`
/// context.
private struct SettingsMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") { openSettings() }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Run the app and verify the menu**

Run: `swift run speak-clean`
Expected: the menu bar icon shows. Click it. The menu now contains "Settings…" above "Edit Dictionary…". Clicking it opens a Settings window with two fields and a Reset button.

Close the app with Cmd+Q or via the menu.

- [ ] **Step 5: Commit**

```bash
git add Sources/speak-clean/SpeakCleanApp.swift
git -c commit.gpgsign=false commit -m "feat: wire Settings scene and menu button into SpeakCleanApp"
```

---

## Task 5: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Architecture section to mention the Settings scene**

In `CLAUDE.md`, find the `speak_clean.swift` bullet under "Architecture" (around line 33). It currently reads:

```
  - `speak_clean.swift` — entry point, `AppDelegate` with 3-item menu (Edit Dictionary / Reset / Quit), global shortcut monitor, streaming record/transcribe/clean/paste flow.
```

The entry point is actually `SpeakCleanApp.swift` (SwiftUI app, not AppDelegate). Rewrite the `speak-clean` executable bullets to match the current structure and mention the Settings scene. Replace the entire `speak-clean` executable section (the bullets for `speak_clean.swift`, `AppController.swift`, `AvailabilityChecker.swift`, `PersonalLibrary.swift`) with:

```
- **`speak-clean`** (executable): menu bar UI, hotkey, recording orchestration.
  - `SpeakCleanApp.swift` — `@main` SwiftUI app. One `MenuBarExtra` scene (menu with Settings…/Edit Dictionary/Reset/Quit) and one `Settings` scene hosting `SettingsView`. `.accessory` activation policy set before the scene renders.
  - `SettingsView.swift` — SwiftUI `Form` with two text fields (shortcut, Ollama model) and a Reset to Defaults button. Apply-on-commit: shortcut triggers `coordinator.reinstallHotkey()`; model triggers `coordinator.reset()`.
  - `RecordingCoordinator.swift` — `@Observable @MainActor` class. Owns the `AppController`, the global/local hotkey `NSEvent` monitors, and the per-press record/stop/paste Task. Exposes `reinstallHotkey()` so the Settings view can apply shortcut changes without restarting the app.
  - `AppController.swift` — `@MainActor` 2-state machine (`.ready` / `.notReady(reason:)`). Owns the `Transcriber`. One public action: `reset()` re-runs availability checks.
  - `AvailabilityChecker.swift` — `runAvailabilityChecks()` free function. Checks, in order: Ollama reachable → model pulled → mic permission → `DictationTranscriber.supportedLocale` → `AssetInventory.assetInstallationRequest`. Any failure produces a user-facing reason string with the shell command to fix it.
  - `PersonalLibrary.swift` — `AppConfig`: UserDefaults-backed `shortcut` and `cleanupModel` (Ollama tag), `defaultShortcut` / `defaultCleanupModel` constants (source of truth for registered defaults and the Reset button), `parse(_:)` shortcut string parser, dictionary file at `~/Library/Application Support/SpeakClean/dictionary.txt`, `loadDictionary()` helper.
```

- [ ] **Step 2: Update the `defaults write` instruction block**

In the Build & Run section (around line 15), update the block that says:

```
# Or switch model (any Ollama tag) — no recompile needed:
# defaults write local.speakclean cleanupModel "llama3.2:3b"
# ollama pull llama3.2:3b
```

Change to:

```
# Or switch model from the Settings window (menu bar → Settings…) or via CLI:
# defaults write local.speakclean cleanupModel "llama3.2:3b"
# ollama pull llama3.2:3b
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git -c commit.gpgsign=false commit -m "docs: update CLAUDE.md for Settings UI"
```

---

## Task 6: End-to-end manual verification

**Files:** none.

This task has no code. Walk through each check. If any check fails, stop and fix before declaring the feature done.

- [ ] **Build and launch**

Run: `swift build -c release && swift run -c release speak-clean`
Expected: menu-bar icon appears (three-dots processing, then the I-beam+waveform idle icon after the first availability check completes, assuming Ollama is running with the default model).

- [ ] **Menu shows "Settings…"**

Click the menu-bar icon. Expected order: "Settings…", "Edit Dictionary…", "Reset", divider, "Quit". If `.notReady`, the reason text appears above them.

- [ ] **Opening Settings**

Click "Settings…". A window opens with:
- A "Shortcut" row containing a text field pre-filled with `option+space` (or your current value).
- A "Model" row containing a text field pre-filled with `gemma4:e2b`.
- A "Reset to Defaults" button below.

- [ ] **Change the shortcut to something valid**

Change the shortcut field to `cmd+shift+d` and press Return. The field keeps the normalized value, no red border, no error message. Close the Settings window. Press the **old** shortcut (option+space) — nothing should happen. Press the **new** shortcut (Cmd+Shift+D) in another app — recording starts.

- [ ] **Enter an invalid shortcut**

Open Settings again. Change the shortcut field to `xyz+foo` and press Return. A red border appears; the error message reads "Use e.g. option+space — one or more modifiers plus a known key". Your previous shortcut (Cmd+Shift+D) still triggers recording.

- [ ] **Enter a valid shortcut with whitespace**

Clear the field and type `option + space` with spaces. Press Return. The field normalizes to `option+space`; the border goes green. Old shortcut (Cmd+Shift+D) stops working; new shortcut (option+space) works.

- [ ] **Change the model to an installed tag**

In a terminal: `ollama list` — pick any currently-installed tag. In Settings, set the Model field to that tag and press Return. The menu-bar icon briefly shows processing dots (availability re-check), then returns to idle.

- [ ] **Change the model to a typo / unpulled tag**

Set the Model field to `gemma4:doesnotexist` and press Return. Menu-bar icon goes to processing, then to processing + reason text in the menu tooltip (e.g. "Gemma model isn't installed. Run: ollama pull gemma4:doesnotexist"). Fix by clicking Reset after `ollama pull` — or use the Settings field to type a valid tag and press Return.

- [ ] **Reset to Defaults**

In Settings, click "Reset to Defaults". Both fields snap back to `option+space` and `gemma4:e2b`. The default shortcut now works; availability re-runs for the default model.

- [ ] **Persistence**

Quit the app. Run again. Open Settings. Fields reflect whatever you last set — not defaults (unless you last clicked Reset).

- [ ] **Memory / window teardown**

Open and close the Settings window a few times. The menu-bar icon remains responsive; recording still works after Settings closes. (Optional: run `leaks $(pgrep speak-clean)` — no new leaks reported.)

- [ ] **If all checks pass, the feature is done.**

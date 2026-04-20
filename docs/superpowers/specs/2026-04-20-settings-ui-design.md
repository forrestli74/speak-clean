# Minimal Settings UI — Design Spec

**Date:** 2026-04-20
**Status:** Approved, ready for implementation plan.

## Goal

Provide a minimal native Settings window for changing the two user-facing preferences that currently require `defaults write` from the terminal: the global recording shortcut and the Ollama cleanup model.

## Non-goals

- Shortcut *recorder* (click-and-press capture). Plain text input only.
- Ollama model *picker* (dropdown from `ollama list`). Plain text input only.
- Detection of shortcut conflicts with other apps (not possible from userspace).
- Multiple shortcuts or per-mode shortcuts.
- Any UI for the custom dictionary — the existing "Edit Dictionary…" flow stays.

## UX

A standard macOS `Settings` scene (Cmd+, convention), opened via a new "Settings…" item in the menu-bar menu. The window is a `Form` with two labeled rows and one button:

```
┌──────────────────────────────────────────┐
│                                          │
│  Shortcut:  [ option+space            ]  │
│                                          │
│     Model:  [ gemma4:e2b              ]  │
│                                          │
│             [ Reset to Defaults ]        │
│                                          │
└──────────────────────────────────────────┘
```

Each field commits on Return or loss of focus (macOS System Settings style — no Save button). Invalid shortcut input shows a red border and an inline error message below the field; nothing is persisted until the input parses. Invalid model input (empty after trimming) is ignored on commit. "Reset to Defaults" unconditionally resets both fields to the registered defaults and applies them.

## Architecture

### Scenes

`SpeakCleanApp.body` currently has one scene: `MenuBarExtra`. Add a second: `Settings { SettingsView(coordinator: coordinator) }`. Both observe the same `@State var coordinator: RecordingCoordinator`.

### Menu-bar entry point

Add a "Settings…" `Button` above "Edit Dictionary…" in the menu. Use SwiftUI's native `@Environment(\.openSettings)` action (available on macOS 14+; the project targets macOS 26+):

```swift
@Environment(\.openSettings) private var openSettings
// ...
Button("Settings…") { openSettings() }
    .keyboardShortcut(",", modifiers: .command)
```

The `Settings` scene itself wires up Cmd+, automatically when the app's focus is on the settings window, but a `MenuBarExtra` menu is a different focus context — hence the explicit `.keyboardShortcut` on the button so Cmd+, works from the menu.

### SettingsView

New file: `Sources/speak-clean/SettingsView.swift`.

```swift
@MainActor
struct SettingsView: View {
    let coordinator: RecordingCoordinator
    @State private var shortcutText = AppConfig.shortcut
    @State private var modelText = AppConfig.cleanupModel

    var body: some View {
        Form {
            TextField("Shortcut", text: $shortcutText)
                .onSubmit { commitShortcut() }
            if !shortcutIsValid {
                Text("Use e.g. option+space — one or more modifiers plus a known key")
                    .foregroundStyle(.red).font(.caption)
            }
            TextField("Model", text: $modelText)
                .onSubmit { commitModel() }
            Button("Reset to Defaults") { resetToDefaults() }
        }
        .padding()
        .frame(width: 380)
    }

    private var shortcutIsValid: Bool { AppConfig.parse(shortcutText) != nil }
    // commitShortcut / commitModel / resetToDefaults — see "Apply semantics"
}
```

One file, one view, no sub-views. The view holds the coordinator by reference (coordinator is `@Observable @MainActor final class`; SwiftUI tracks observable properties automatically).

### AppConfig changes

Two small additions in `Sources/speak-clean/PersonalLibrary.swift`:

1. **Expose default values as named constants** so the Reset button has a single source of truth:

   ```swift
   static let defaultShortcut = "option+space"
   static let defaultCleanupModel = "gemma4:e2b"
   ```

   Update `defaults.register(defaults: [...])` to reference them.

2. **Extract `parse(_:)` from `parsedShortcut`** so `SettingsView` can validate arbitrary candidate strings without going through the `shortcut` property:

   ```swift
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

   static var parsedShortcut: (...)? { parse(shortcut) }
   ```

   The trim-each-token change also fixes `"option + space"` (with spaces) parsing.

### RecordingCoordinator changes

`installHotkey()` today is private and one-shot. Add a public method for re-install and refactor the existing teardown logic (currently only in `deinit`) into a shared helper:

```swift
func reinstallHotkey() {
    removeHotkey()
    installHotkey()
}

private func removeHotkey() {
    if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    if let m = localMonitor  { NSEvent.removeMonitor(m);  localMonitor  = nil }
}

@MainActor deinit { removeHotkey() }
```

No other changes to the coordinator. Model changes route through the existing `coordinator.reset()` (which already re-reads `AppConfig.cleanupModel` at check time per `RecordingCoordinator.init`).

## Apply semantics

Per field, on commit:

**Shortcut:**
```swift
private func commitShortcut() {
    let trimmed = shortcutText.trimmingCharacters(in: .whitespaces)
    guard AppConfig.parse(trimmed) != nil else { return }   // stay red, don't persist
    AppConfig.shortcut = trimmed
    shortcutText = trimmed                                  // normalize the field
    coordinator.reinstallHotkey()
}
```

**Model:**
```swift
private func commitModel() {
    let trimmed = modelText.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { modelText = AppConfig.cleanupModel; return }
    AppConfig.cleanupModel = trimmed
    modelText = trimmed
    Task { await coordinator.reset() }
}
```

**Reset to Defaults:**
```swift
private func resetToDefaults() {
    AppConfig.shortcut = AppConfig.defaultShortcut
    AppConfig.cleanupModel = AppConfig.defaultCleanupModel
    shortcutText = AppConfig.defaultShortcut
    modelText = AppConfig.defaultCleanupModel
    coordinator.reinstallHotkey()
    Task { await coordinator.reset() }
}
```

The invalid-shortcut case leaves the prior working shortcut in effect (`UserDefaults` is unchanged; `reinstallHotkey` is not called). The old `NSEvent` monitor keeps firing for the old shortcut until the user fixes their typo. This matches the "failure model" principle in CLAUDE.md — one recovery mechanism, no partial states.

## Testing

### Unit

Add tests in the existing test target for `AppConfig.parse(_:)`:

| Input | Expected |
|---|---|
| `"option+space"` | `(.option, 49)` |
| `"OPTION+SPACE"` | `(.option, 49)` (lowercased) |
| `"option + space"` | `(.option, 49)` (trimmed tokens) |
| `"cmd+shift+d"` | `([.command, .shift], 2)` |
| `"space"` | `nil` (no modifier) |
| `"fn+space"` | `nil` (unknown modifier) |
| `"option+foo"` | `nil` (unknown key) |
| `""` | `nil` |
| `"option+"` | `nil` |

Existing `parsedShortcut` tests continue to pass (it now delegates to `parse`).

### Manual

SwiftUI views inside a `Settings` scene aren't practical to unit-test (no first-class programmatic driver for the Settings window). Manual checklist:

- [ ] Cmd+, opens Settings window from any app state.
- [ ] "Settings…" menu item opens the same window.
- [ ] Typing a valid shortcut + Return applies immediately — test with a deliberate change (e.g. `cmd+shift+d`), record something via the new shortcut.
- [ ] Typing an invalid shortcut shows red border + message; the old shortcut still works.
- [ ] Changing the model to something valid (and pulled) and pressing Return: state goes `.notReady` briefly (availability re-check), then `.ready`.
- [ ] Changing the model to a typo: state goes `.notReady` with the existing "model isn't installed" reason in the menu tooltip.
- [ ] "Reset to Defaults" restores both fields and applies them.
- [ ] Closing and reopening the window preserves values from `UserDefaults`.
- [ ] Window-closed memory: no `NSWindow` retained after close (inspect via Instruments allocations if time permits).

## File change summary

- **New:** `Sources/speak-clean/SettingsView.swift` (~60 lines)
- **Edit:** `Sources/speak-clean/SpeakCleanApp.swift` — add `Settings { ... }` scene, add "Settings…" menu button
- **Edit:** `Sources/speak-clean/RecordingCoordinator.swift` — add `reinstallHotkey()`, extract `removeHotkey()`
- **Edit:** `Sources/speak-clean/PersonalLibrary.swift` — add `defaultShortcut` / `defaultCleanupModel` constants, extract `parse(_:)`
- **Edit:** tests for `AppConfig.parse` (existing test target)
- **Edit:** `CLAUDE.md` — mention the new Settings scene under Architecture → executable; update "Change with `defaults write …`" notes to mention the GUI alternative.

## Risks & tradeoffs

- **No shortcut conflict detection** — user can enter a system-claimed combo (e.g. `cmd+space` — Spotlight). The monitor silently won't fire. Accepted tradeoff for "minimal."
- **Model-change triggers a full `reset()`** — re-downloads no models, just re-runs availability checks (<1s). Acceptable.
- **Apply-on-commit with no confirmation** — a mistyped valid-but-wrong shortcut (e.g. user types `cmd+w` thinking they're editing the field) would apply and then `cmd+w` starts triggering recording. Survivable: user reopens Settings, fixes it. Not worth a Save button for two fields.

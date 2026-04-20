# SwiftUI Shell Rewrite

**Date:** 2026-04-20
**Branch:** `feature/native-ai`
**Status:** Proposed.
**Scope:** Shell-only. `SpeakCleanCore`, `AppConfig`, `AvailabilityChecker` unchanged. No user-facing feature additions.

## What changes

Replace the AppKit shell (`AppDelegate` + `Main` enum + `NSStatusItem` + `NSMenu` + `@objc` target-action plumbing) with a SwiftUI `App` + `MenuBarExtra` scene + `@Observable` coordinator. Global hotkey (`NSEvent` monitors), synthetic Cmd+V (`CGEvent`), and programmatically drawn menu-bar icons (`NSImage`) remain AppKit-backed — SwiftUI has no equivalents.

## Why

Not for line count. An independent review confirmed the rewritten shell lands around parity with today (~295 lines vs. 298). The substantive code — record/stop/paste `Task`, `NSEvent` hotkey monitor, pasteboard synthesis, `NSImage` drawing — cannot be deleted; it can only move.

The rewrite is for **idiom**:

- Modern macOS 26+ app shape (`App` protocol, `MenuBarExtra`, `@Observable`, `@AppStorage`).
- Drops `NSApplicationDelegate` conformance, `@objc` selectors, `applicationDidFinishLaunching` lifecycle ceremony, and the `onStateChange` closure plumbing that wires `AppController` to the icon.
- Lower cost to add future SwiftUI-shaped features (a `Settings { }` scene is one `Scene` away, if we ever want one).

Option A (`@NSApplicationDelegateAdaptor` wrapping the existing `AppDelegate`) was considered and rejected in favor of a fully-SwiftUI-native shape. A is the smaller-diff option; B is the chosen option.

## User-facing change

One visible change, driven by a `MenuBarExtra` platform limitation:

**Tooltip → disabled menu item.** Today the menu-bar button shows the not-ready reason as an `NSStatusItem.button.toolTip` on hover. `MenuBarExtra` does not expose a tooltip on its label. The replacement: when `controller.state == .notReady(let reason)`, the first menu item (inside the popover) is a disabled `Text(reason)`, rendered above the existing Edit Dictionary / Reset / Quit items. When `.ready`, that item is absent.

Arguably better UX — discoverable without hover, selectable text — but it is a behavior change, not a pure port. Acknowledged.

No other behavior changes: same shortcut, same record/stop flow, same cleanup, same paste, same Reset semantics, same availability checks.

## Architecture

### Files

**New:**

- `Sources/speak-clean/SpeakCleanApp.swift` — the `@main struct SpeakCleanApp: App`. Sets `NSApp.setActivationPolicy(.accessory)` in `init()` (before scene instantiation, to suppress the dock-icon flash). Body is one `MenuBarExtra` scene with a custom label (icon) and a SwiftUI menu. Holds the coordinator as `@State`. Hosts the `MenuBarIcon` enum (the programmatic `NSImage` drawing code, unchanged).
- `Sources/speak-clean/RecordingCoordinator.swift` — `@Observable @MainActor final class`. Owns the `AppController`, installs and holds the `NSEvent` global/local hotkey monitors, owns `isRecording` + `inFlight: Task<Void, Never>?`, and implements `toggleRecording` / `startRecording` / `stopRecording` / `pasteText` / `editDictionary` / `reset` / `bootstrap`.

**Modified:**

- `Sources/speak-clean/AppController.swift` — add `@Observable` macro; delete the `var onStateChange: ((State) -> Void)?` closure and all calls through it. `setState(_:)` keeps its signature but stops firing the closure. SwiftUI observes `state` directly via `@Observable`.

**Deleted:**

- `Sources/speak-clean/speak_clean.swift` — contents are split between `SpeakCleanApp.swift` (MenuBarIcon + App entry) and `RecordingCoordinator.swift` (recording flow).

**Unchanged:**

- `Sources/speak-clean/PersonalLibrary.swift` (`AppConfig`)
- `Sources/speak-clean/AvailabilityChecker.swift`
- `Sources/SpeakCleanCore/*` (`Transcriber`, `TextCleaner`)
- `Tests/**`

### Scene graph

```swift
@main
struct SpeakCleanApp: App {
    @State private var coordinator = RecordingCoordinator()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            // When .notReady, surface the reason as a disabled top item.
            if case .notReady(let reason) = coordinator.controller.state {
                Text(reason)
                Divider()
            }
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
        .task { await coordinator.bootstrap() }
    }
}
```

### Coordinator shape

```swift
@Observable
@MainActor
final class RecordingCoordinator {
    let controller: AppController
    private(set) var isRecording = false
    private var inFlight: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bootstrapped = false

    init() {
        self.controller = AppController(check: { ... })  // same closure as today
    }

    /// View-derived icon. Priority: recording > ready > not-ready/processing.
    var statusImage: NSImage {
        if isRecording { return MenuBarIcon.recording() }
        switch controller.state {
        case .ready: return MenuBarIcon.idle()
        case .notReady: return MenuBarIcon.processing()
        }
    }

    /// Run once. Called from the MenuBarExtra's .task modifier.
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        installHotkey()
        await controller.reset()
    }

    func reset() async { await controller.reset() }
    func editDictionary() { AppConfig.openDictionary() }

    private func installHotkey() { /* NSEvent monitors, store handles */ }
    private func toggleRecording() { /* same logic as AppDelegate today */ }
    private func startRecording() { /* same */ }
    private func stopRecording() { /* same */ }
    private func pasteText(_: String) { /* same */ }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}
```

## Three non-obvious correctness items

1. **Icon-suppression during recording.** Today `AppDelegate.onStateChange` guards with `guard !self.isRecording` on line 114 so a state transition mid-recording doesn't flicker the dot back to idle. In the rewrite, that gate moves into the derived `statusImage` property: `if isRecording { return .recording() }` is the first branch, unconditionally. State-change observation no longer goes through a closure; the view re-renders on any `@Observable` read, and the priority lives in `statusImage`'s switch.

2. **Monitor lifecycle.** `NSEvent.addGlobalMonitorForEvents` returns an opaque handle; today's `AppDelegate` discards it (latent leak, masked by `AppDelegate`'s whole-process lifetime). The coordinator stores `globalMonitor` / `localMonitor` and removes them in `deinit`. Installation is gated by a `bootstrapped` flag and triggered from `.task` on the scene, not from `init()` — SwiftUI does not strictly guarantee `@State` initializers run exactly once.

3. **Template image through the SwiftUI bridge.** `MenuBarIcon` already sets `NSImage.isTemplate = true`; the bridge to `Image(nsImage:)` preserves template semantics. Defensively: `.renderingMode(.template)` on the `Image` ensures the menu bar applies its own recoloring, and an explicit `.frame(width: 18, height: 18)` is added to avoid first-render mis-sizing that has been observed with custom-drawn labels on `MenuBarExtra`. If smoke testing shows the frame override harms rendering on macOS 26, it comes out.

## Data flow (unchanged)

Launch → scene's `.task` runs `coordinator.bootstrap()` → installs hotkey + `controller.reset()` → availability checks → `.ready`. Hotkey press → `coordinator.toggleRecording()` → `transcriber.start()`. Release → `transcriber.stop()` → `TextCleaner.clean(raw, dictionary:, model:)` → `pasteText(cleaned)`. Error anywhere → `controller.setState(.notReady(reason:))` → icon becomes processing, reason appears as top disabled menu item.

## Error handling (unchanged)

Two-state machine in `AppController` (`.ready` / `.notReady(reason:)`). Reset menu item is the single recovery path. No auto-retry, no per-error fallback branches.

## Testing

No test changes. `AppControllerTests` exercises the state machine and is decoupled from the shell. `TextCleanerIntegrationTests` is shell-agnostic. The recording flow (hotkey → paste) was not unit-tested in the AppKit shape and is not unit-tested in the SwiftUI shape either — same posture.

Manual verification before merge:

- `swift build` and `swift run speak-clean` produce a menu-bar-only app (no dock icon, no flash).
- Menu shows Edit Dictionary / Reset / Quit in the `.ready` state; adds a disabled reason line in `.notReady`.
- Global hotkey works when another app is frontmost.
- Recording dot does not flicker to idle if a state transition fires during recording (forced repro: kill Ollama mid-recording).
- Reset from the menu re-runs availability checks and recovers.

## Line-count expectation

Roughly parity with today (~295 lines vs. 298). The rewrite is not for code reduction; it is for shape. If code size matters more than shape, option A (`@NSApplicationDelegateAdaptor`) is the better choice and this spec does not apply.

## Risks

- **`MenuBarExtra` label rendering edge cases.** Programmatically drawn `NSImage`s through `Image(nsImage:)` are well-supported but less common than `Image(systemName:)`. Manual smoke test on macOS 26 is the validation.
- **`@State` coordinator re-init.** Mitigated by the `bootstrapped` flag + `deinit` cleanup; the worst case is a harmless re-install, not a leak.
- **Future additions may tempt `@NSApplicationDelegateAdaptor` anyway.** If we later need `applicationShouldHandleReopen`, `applicationSupportsSecureRestorableState`, or similar AppKit callbacks, we add an adapter at that point. Not adding one preemptively.

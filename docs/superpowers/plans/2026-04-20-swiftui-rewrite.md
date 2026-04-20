# SwiftUI Shell Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the AppKit shell (`AppDelegate` + `Main` enum + `NSStatusItem` + `NSMenu`) with a SwiftUI `App` + `MenuBarExtra` scene + `@Observable RecordingCoordinator`. Pure shell port with one visible change: tooltip becomes a disabled menu item when `.notReady`.

**Architecture:** `SpeakCleanApp` (SwiftUI `App`) owns the scene graph and a `@State` coordinator. `RecordingCoordinator` (`@Observable @MainActor final class`) owns the `AppController`, installs `NSEvent` hotkey monitors, runs the record/stop/paste `Task`, and exposes a derived `statusImage` the menu-bar label reads. `AppController` gets `@Observable` and loses its `onStateChange` closure; SwiftUI observes `state` directly. Global hotkey, pasteboard synthesis, and programmatically drawn `NSImage` icons remain AppKit-backed — SwiftUI has no equivalents.

**Tech Stack:** Swift 6.2, macOS 26+, SwiftUI (`App`, `MenuBarExtra`, `@Observable`, `@State`), AppKit (`NSEvent`, `NSPasteboard`, `CGEvent`, `NSImage`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-04-20-swiftui-rewrite-design.md`

---

## Task 1: Baseline verification

**Files:** none.

- [ ] **Step 1: Confirm working tree is clean**

Run: `git status`
Expected: `nothing to commit, working tree clean`

- [ ] **Step 2: Build the project**

Run: `swift build`
Expected: Exits 0. Warnings OK, errors are a stop.

- [ ] **Step 3: Run tests to establish green baseline**

Run: `swift test`
Expected: All suites pass. `AppControllerTests` has 5 tests including `onStateChangeFiresForEachTransition` — note, this one references the closure we will delete, so we rewrite it in Task 2 before deleting the closure.

---

## Task 2: Rewrite the onStateChange test to not depend on the closure

The closure `AppController.onStateChange` is going away. The existing `onStateChangeFiresForEachTransition` test relies on it to verify that `reset()` flips through an intermediate `"Checking availability…"` state. We rewrite it first — while the closure still exists — to use a capture-from-inside-the-check-closure pattern that survives the closure's removal.

**Files:**
- Modify: `Tests/SpeakCleanTests/AppControllerTests.swift:26-37`

- [ ] **Step 1: Replace the test**

Replace the existing `onStateChangeFiresForEachTransition` test (lines 26–37) with the following:

```swift
    @Test @MainActor func resetFlipsThroughCheckingState() async {
        var capturedDuringCheck: AppController.State?
        var controller: AppController!
        controller = AppController(check: { @MainActor in
            capturedDuringCheck = controller.state
            return .ready
        })
        await controller.reset()
        #expect(capturedDuringCheck == .notReady(reason: "Checking availability…"))
        #expect(controller.state == .ready)
    }
```

- [ ] **Step 2: Run tests to verify pass**

Run: `swift test --filter AppControllerTests`
Expected: All 5 tests pass. `resetFlipsThroughCheckingState` replaces `onStateChangeFiresForEachTransition`; the new name appears in the passing list.

- [ ] **Step 3: Commit**

```bash
git add Tests/SpeakCleanTests/AppControllerTests.swift
git commit -m "test(AppController): capture intermediate state via check closure, not onStateChange

Prepares for the SwiftUI rewrite which deletes onStateChange."
```

---

## Task 3: Write failing test for status-icon priority

Extract the "recording takes precedence over state" priority into a pure static function so it's unit-testable without `@Observable`, `@MainActor`, or a live `AppController`. This is the one non-obvious correctness property the review flagged (flicker regression risk).

**Files:**
- Create: `Tests/SpeakCleanTests/StatusIconTests.swift`

- [ ] **Step 1: Write the failing test file**

Create `Tests/SpeakCleanTests/StatusIconTests.swift`:

```swift
import Testing
@testable import speak_clean

@Suite("StatusIcon priority")
struct StatusIconTests {

    @Test func recordingBeatsReady() {
        #expect(StatusIcon.from(isRecording: true, state: .ready) == .recording)
    }

    @Test func recordingBeatsNotReady() {
        #expect(StatusIcon.from(isRecording: true, state: .notReady(reason: "x")) == .recording)
    }

    @Test func readyWhenNotRecording() {
        #expect(StatusIcon.from(isRecording: false, state: .ready) == .idle)
    }

    @Test func notReadyWhenNotRecording() {
        #expect(StatusIcon.from(isRecording: false, state: .notReady(reason: "x")) == .processing)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StatusIconTests`
Expected: Fails to compile — `StatusIcon` is undefined.

---

## Task 4: Create RecordingCoordinator.swift with the icon priority

Introduce the coordinator file with just enough to make the failing tests pass. No `@Observable` yet, no hotkey logic — just the `StatusIcon` enum and its `from(isRecording:state:)` factory. Expanding the class happens in the next task so each commit has a small, reviewable surface.

**Files:**
- Create: `Sources/speak-clean/RecordingCoordinator.swift`

- [ ] **Step 1: Create the file**

Write `Sources/speak-clean/RecordingCoordinator.swift`:

```swift
import AppKit

/// Which menu-bar icon to show. Priority: recording trumps `AppController`
/// state. Exposed at file scope (non-`@MainActor`) so the flicker-regression
/// property can be unit-tested as a pure function.
enum StatusIcon: Equatable {
    case idle
    case recording
    case processing
}

extension StatusIcon {
    /// Derive the icon from coordinator + controller state.
    /// - Parameters:
    ///   - isRecording: Whether a recording is currently in flight.
    ///   - state: The `AppController` state at read time.
    static func from(isRecording: Bool, state: AppController.State) -> StatusIcon {
        if isRecording { return .recording }
        switch state {
        case .ready: return .idle
        case .notReady: return .processing
        }
    }
}
```

- [ ] **Step 2: Run test to verify pass**

Run: `swift test --filter StatusIconTests`
Expected: All 4 tests pass.

- [ ] **Step 3: Verify whole suite still green**

Run: `swift test`
Expected: All pre-existing tests still pass. No regressions.

- [ ] **Step 4: Commit**

```bash
git add Sources/speak-clean/RecordingCoordinator.swift Tests/SpeakCleanTests/StatusIconTests.swift
git commit -m "feat(shell): introduce StatusIcon priority (pure fn, unit-tested)

First slice of the coordinator file. Encodes the \"recording trumps state\"
priority that AppDelegate.onStateChange used to enforce via a guard."
```

---

## Task 5: Flesh out RecordingCoordinator with hotkey + record/stop/paste

Move the substantive logic from `AppDelegate` (hotkey monitor, toggleRecording, startRecording, stopRecording, pasteText, ms helper) into the coordinator class. Add `@Observable`, `@MainActor`, ownership of `AppController`. Not wired into the entry point yet; the class compiles alongside the existing `AppDelegate`.

**Files:**
- Modify: `Sources/speak-clean/RecordingCoordinator.swift`

- [ ] **Step 1: Append the coordinator class to the file**

Add the following after the existing `StatusIcon` extension in `Sources/speak-clean/RecordingCoordinator.swift`:

```swift
import SpeakCleanCore

/// Top-level IO coordinator for the SwiftUI shell. Owns the `AppController`,
/// the global/local hotkey monitors, and the per-press record/stop/paste
/// `Task`. SwiftUI observes its `@Observable` properties to drive the
/// menu-bar label.
///
/// Lifecycle: constructed as `@State` inside `SpeakCleanApp`. The
/// `bootstrap()` method is called from the scene's `.task` modifier and is
/// idempotent (guarded by `bootstrapped`). `deinit` removes the `NSEvent`
/// monitors — important because we cannot assume SwiftUI will keep `@State`
/// for the process lifetime.
@Observable
@MainActor
final class RecordingCoordinator {
    /// Shared state owner. Read by views for `.state`; used by the
    /// coordinator to drive recording guards and error transitions.
    let controller: AppController

    /// `true` between `startRecording()` and `stopRecording()`. Gates
    /// re-entry of the hotkey handler.
    private(set) var isRecording = false

    /// Pending post-recording Task (stop → clean → paste). Gates
    /// `startRecording` so a second hotkey press cannot race a still-
    /// running stop task whose `Transcriber.session` hasn't been cleared.
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// `NSEvent.addGlobalMonitorForEvents` / `addLocalMonitorForEvents`
    /// handles. Stored so `deinit` can remove them.
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?

    /// Idempotency flag for `bootstrap()`.
    @ObservationIgnored private var bootstrapped = false

    init() {
        self.controller = AppController(check: {
            // Read the user-configured model on the main actor at each
            // check time, so `defaults write local.speakclean cleanupModel …`
            // takes effect on the next Reset.
            let model = await MainActor.run { AppConfig.cleanupModel }
            return await runAvailabilityChecks(cleanupModel: model)
        })
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Derived (for the view)

    /// Icon to show in the menu bar. Priority lives in `StatusIcon.from`
    /// so the flicker-regression property is unit-testable.
    var statusImage: NSImage {
        switch StatusIcon.from(isRecording: isRecording, state: controller.state) {
        case .idle: return MenuBarIcon.idle()
        case .recording: return MenuBarIcon.recording()
        case .processing: return MenuBarIcon.processing()
        }
    }

    // MARK: - Lifecycle

    /// Idempotent. Install the hotkey monitors and kick off the first
    /// availability check. Called from the scene's `.task` modifier.
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        installHotkey()
        await controller.reset()
    }

    /// Manual-recovery action (Reset menu item). Re-runs availability
    /// checks via `AppController.reset()`.
    func reset() async {
        await controller.reset()
    }

    /// Opens `dictionary.txt` in the user's default editor.
    func editDictionary() {
        AppConfig.openDictionary()
    }

    // MARK: - Hotkey

    /// Install global + local `NSEvent` monitors for the configured
    /// shortcut. The global monitor catches presses when other apps are
    /// frontmost; the local one catches presses when this app's menu is
    /// open.
    private func installHotkey() {
        guard let s = AppConfig.parsedShortcut else {
            print("Invalid shortcut: \(AppConfig.shortcut)")
            return
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(s.modifiers) && e.keyCode == s.keyCode {
                self?.toggleRecording()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(s.modifiers) && e.keyCode == s.keyCode {
                self?.toggleRecording()
                return nil
            }
            return e
        }
    }

    // MARK: - Recording flow

    /// Hotkey dispatch. Single shortcut toggles: press starts, press again stops.
    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    /// Begin recording if `.ready` and no outstanding stop task. On error,
    /// flip the controller to `.notReady`.
    ///
    /// Sets `isRecording = true` synchronously before awaiting `start()`
    /// so two rapidly-fired hotkey events in the same main-actor tick
    /// can't both enter the body and then both call `transcriber.start()`.
    private func startRecording() {
        guard case .ready = controller.state, inFlight == nil, !isRecording else { return }
        isRecording = true
        Task { @MainActor in
            do {
                try await controller.transcriber.start()
            } catch {
                print("[recording] start failed: \(error)")
                isRecording = false
                controller.setState(.notReady(reason: "Recording start failed: \(error.localizedDescription)"))
            }
        }
    }

    /// End recording, run the LLM cleanup pass, and paste the result.
    /// All async work lives in `inFlight` so a subsequent hotkey press can
    /// see "still processing" and no-op.
    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        let controller = self.controller
        inFlight = Task { @MainActor [weak self] in
            defer { self?.inFlight = nil }
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let raw = try await controller.transcriber.stop()
                let t1 = CFAbsoluteTimeGetCurrent()
                print("[raw] \(raw.isEmpty ? "(empty)" : raw) — transcribe=\(Self.ms(t1 - t0))ms")
                let cleaned = try await TextCleaner.clean(
                    raw,
                    dictionary: AppConfig.loadDictionary(),
                    model: AppConfig.cleanupModel
                )
                let t2 = CFAbsoluteTimeGetCurrent()
                print("[cleaned] \(cleaned.isEmpty ? "(empty)" : cleaned) — clean=\(Self.ms(t2 - t1))ms total=\(Self.ms(t2 - t0))ms")
                if cleaned.isEmpty && !raw.isEmpty {
                    print("[cleaned] LLM returned empty for non-empty transcript")
                }
                if !cleaned.isEmpty {
                    self?.pasteText(cleaned)
                }
            } catch {
                print("[transcription failed] \(error)")
                controller.setState(.notReady(reason: "Transcription failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Inject `text` into the currently focused app by writing to the
    /// general pasteboard, synthesizing a Cmd+V keystroke, then restoring
    /// the previous clipboard contents ~100 ms later.
    private func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        let kd = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let ku = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        kd?.flags = .maskCommand
        ku?.flags = .maskCommand
        kd?.post(tap: .cghidEventTap)
        ku?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let p = previous {
                pb.clearContents()
                pb.setString(p, forType: .string)
            }
        }
    }

    /// Seconds → whole-millisecond string, for log formatting.
    private static func ms(_ seconds: CFAbsoluteTime) -> String {
        String(Int((seconds * 1000).rounded()))
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Exits 0. The file compiles even though `SpeakCleanApp` doesn't exist yet and the old `AppDelegate` is still live.

- [ ] **Step 3: Run all tests**

Run: `swift test`
Expected: All tests pass (no new behavior was wired to them; `StatusIconTests` still passes; `AppControllerTests` still passes).

- [ ] **Step 4: Commit**

```bash
git add Sources/speak-clean/RecordingCoordinator.swift
git commit -m "feat(shell): add RecordingCoordinator (hotkey + record/stop/paste)

@Observable @MainActor class. Owns AppController, hotkey monitors,
and the recording Task. Not wired to the entry point yet — the old
AppDelegate is still the live shell."
```

---

## Task 6: Create SpeakCleanApp.swift (no @main yet)

Build the SwiftUI scene graph as a separate file. **Do not include `MenuBarIcon` in this file** — it still lives in `speak_clean.swift` at this point and would duplicate. `MenuBarIcon` moves in Task 7 when `speak_clean.swift` is deleted. The scene only references the coordinator's `statusImage`, so it compiles without a direct `MenuBarIcon` dependency here.

Do **not** add `@main` — the old `Main` enum still holds it. The file compiles alongside the old shell; we'll flip the entry point atomically in the next task.

**Files:**
- Create: `Sources/speak-clean/SpeakCleanApp.swift`

- [ ] **Step 1: Write the file**

Create `Sources/speak-clean/SpeakCleanApp.swift`:

```swift
import AppKit
import SwiftUI

/// Menu-bar-only app entry point. One `MenuBarExtra` scene; all IO is
/// coordinated by `RecordingCoordinator` held as `@State`.
///
/// The activation policy is set in `init()` (before the scene instantiates)
/// so `.accessory` is in effect for the first frame and the dock-icon
/// flash that otherwise happens on SwiftUI app launch is suppressed.
struct SpeakCleanApp: App {
    @State private var coordinator = RecordingCoordinator()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            // `.notReady` reason is surfaced inside the popover — replaces
            // the old `NSStatusItem.button.toolTip` which has no
            // `MenuBarExtra` equivalent.
            if case .notReady(let reason) = coordinator.controller.state {
                Text(reason).foregroundStyle(.secondary)
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

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Exits 0. The struct is unused (no `@main`) but compiles. The old `Main` enum is still the entry point.

- [ ] **Step 3: Verify tests still pass**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/speak-clean/SpeakCleanApp.swift
git commit -m "feat(shell): scaffold SwiftUI SpeakCleanApp (MenuBarExtra scene)

App struct only — MenuBarIcon stays in speak_clean.swift for now to
avoid duplicate definitions. Not yet wired as the entry point; the
old Main enum still holds @main. Flipped in the next commit."
```

---

## Task 7: Flip the entry point atomically

Three changes that must land together because they have mutual compile dependencies:

1. Add `@Observable` to `AppController` and delete its `onStateChange` closure.
2. Delete `Sources/speak-clean/speak_clean.swift` (contains the old `AppDelegate`, `MenuBarIcon`, and `Main` enum — `AppDelegate` depends on `onStateChange`, so it must go at the same time the closure goes).
3. Add `@main` to `SpeakCleanApp`.

**Files:**
- Modify: `Sources/speak-clean/AppController.swift`
- Modify: `Sources/speak-clean/SpeakCleanApp.swift`
- Delete: `Sources/speak-clean/speak_clean.swift`

- [ ] **Step 1: Modify `AppController.swift` — add `@Observable`, delete the closure**

Replace the contents of `Sources/speak-clean/AppController.swift` with:

```swift
import Foundation
import SpeakCleanCore

/// Top-level state owner for the menu bar app.
///
/// Two-state machine (`.ready` / `.notReady(reason:)`). Owns the shared
/// `Transcriber` instance and the availability-check closure.
/// `RecordingCoordinator` reads `state` directly; `@Observable` drives
/// SwiftUI re-renders of the menu-bar label.
///
/// Error policy: any failure anywhere in the pipeline flips state to
/// `.notReady(reason:)`. Recovery is a single user-driven Reset — there
/// is no auto-retry.
@Observable
@MainActor
final class AppController {
    /// The only two states the app surfaces to the UI. Ready means the
    /// hotkey will record; NotReady means the hotkey is a no-op and the
    /// `reason` string is shown as a disabled top menu item.
    enum State: Sendable, Equatable {
        case ready
        case notReady(reason: String)
    }

    /// Current state. Mutated only via `setState(_:)` so `@Observable`
    /// change-tracking fires.
    private(set) var state: State = .notReady(reason: "Initializing…")

    /// Availability-check closure. Injected so tests can replace it with
    /// a fake that returns a preset state without touching live APIs.
    @ObservationIgnored private let check: () async -> State

    /// The single recording session holder.
    let transcriber = Transcriber()

    init(check: @escaping () async -> State) {
        self.check = check
    }

    /// Cancel any in-flight transcription, flip to a transient
    /// "Checking availability…" state, then run `check()` and transition
    /// to its result.
    func reset() async {
        await transcriber.cancel()
        setState(.notReady(reason: "Checking availability…"))
        setState(await check())
    }

    /// Write `newState`. Public so `RecordingCoordinator` can force the
    /// app into `.notReady` on recording/cleanup failures.
    func setState(_ newState: State) {
        state = newState
    }
}
```

- [ ] **Step 2: Add `@main` and move `MenuBarIcon` into `SpeakCleanApp.swift`**

Replace the current contents of `Sources/speak-clean/SpeakCleanApp.swift` with the following (adds `@main`, prepends the `MenuBarIcon` enum moved verbatim from `speak_clean.swift`):

```swift
import AppKit
import SwiftUI

// MARK: - Menu bar icons

/// Programmatically drawn menu-bar icons. `isTemplate = true` so macOS
/// recolors them for light/dark menu bars automatically.
enum MenuBarIcon {
    /// Idle: I-beam text cursor plus a small waveform. Shown when ready
    /// and not recording.
    static func idle(height: CGFloat = 18) -> NSImage {
        let width = height
        let scale = height / 36.0
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.black.setStroke()
            let lw: CGFloat = 2.5 * scale
            let cursor = NSBezierPath()
            cursor.lineWidth = lw
            cursor.lineCapStyle = .round
            cursor.move(to: NSPoint(x: 6*scale, y: 6*scale));  cursor.line(to: NSPoint(x: 6*scale, y: 30*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 6*scale));  cursor.line(to: NSPoint(x: 10*scale, y: 6*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 30*scale)); cursor.line(to: NSPoint(x: 10*scale, y: 30*scale))
            cursor.stroke()
            for bar: (CGFloat, CGFloat, CGFloat) in [(16, 14, 22), (21, 8, 28), (26, 11, 25), (31, 14, 22)] {
                let path = NSBezierPath()
                path.lineWidth = lw
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: bar.0*scale, y: bar.1*scale))
                path.line(to: NSPoint(x: bar.0*scale, y: bar.2*scale))
                path.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Recording: filled circle. Shown while the mic is live.
    static func recording(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: true) { rect in
            NSColor.black.setFill()
            let inset = height * 0.15
            NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Processing / not-ready: three dots. Shown on startup, during
    /// transcription + cleanup, and whenever state is `.notReady`. The
    /// disabled reason menu item disambiguates.
    static func processing(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: true) { _ in
            NSColor.black.setFill()
            let r = height * 0.08
            let cy = height / 2
            let gap = height * 0.22
            for i in -1...1 {
                let cx = height/2 + CGFloat(i) * gap
                NSBezierPath(ovalIn: NSRect(x: cx-r, y: cy-r, width: r*2, height: r*2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - App

/// Menu-bar-only app entry point. One `MenuBarExtra` scene; all IO is
/// coordinated by `RecordingCoordinator` held as `@State`.
///
/// The activation policy is set in `init()` (before the scene instantiates)
/// so `.accessory` is in effect for the first frame and the dock-icon
/// flash that otherwise happens on SwiftUI app launch is suppressed.
@main
struct SpeakCleanApp: App {
    @State private var coordinator = RecordingCoordinator()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            if case .notReady(let reason) = coordinator.controller.state {
                Text(reason).foregroundStyle(.secondary)
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

- [ ] **Step 3: Delete the old entry file**

Run: `git rm Sources/speak-clean/speak_clean.swift`
Expected: `rm 'Sources/speak-clean/speak_clean.swift'`

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Exits 0. Possible warnings are acceptable; errors are a stop.

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: All tests pass. `AppControllerTests` (5 tests) green; `StatusIconTests` (4 tests) green; `PersonalLibraryTests`, `TextCleanerTests`, and `TextCleanerIntegrationTests` unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/speak-clean/AppController.swift Sources/speak-clean/SpeakCleanApp.swift
git commit -m "feat(shell): flip entry point to SwiftUI App + MenuBarExtra

Three atomic changes (cannot be split — mutual compile deps):
- AppController gains @Observable, drops onStateChange closure
- Old speak_clean.swift (AppDelegate + Main enum) deleted
- SpeakCleanApp becomes @main

SwiftUI now observes AppController.state directly. The not-ready
reason surfaces as a disabled menu item at the top of the popover
(replaces the old NSStatusItem.button.toolTip, which MenuBarExtra
does not expose)."
```

---

## Task 8: Manual smoke verification

Unit tests cover `AppController` transitions and the `StatusIcon` priority. Everything else — hotkey monitors, scene rendering, pasteboard synthesis, the disabled-reason menu item — is manual. Document the checks so any future maintainer has a script.

**Files:** none (manual).

- [ ] **Step 1: Confirm Ollama is up with the configured model**

Run: `curl -s http://localhost:11434/api/tags | grep -o '"name":"[^"]*"' | head -5`
Expected: Output includes `"name":"gemma4:e2b"` (or whatever `defaults read local.speakclean cleanupModel` returns).

If Ollama is off, start it: `brew services start ollama`. If the model isn't pulled, `ollama pull gemma4:e2b`.

- [ ] **Step 2: Launch the app**

Run: `swift run speak-clean`
Expected: Menu-bar icon appears (three dots initially, then the I-beam + waveform when availability checks finish). **No dock icon appears, no dock flash during launch.**

- [ ] **Step 3: Verify the menu contents in `.ready` state**

Click the menu-bar icon.
Expected: Menu shows three items — `Edit Dictionary…`, `Reset`, `Quit`. No "reason" disabled item at the top.

- [ ] **Step 4: Verify the disabled reason item in `.notReady` state**

In a separate terminal: `brew services stop ollama`.
Click the menu-bar icon → `Reset`. Wait a second, click the icon again.
Expected: Menu now shows a secondary-colored first item (`Ollama isn't running. Run: brew services start ollama`), then a divider, then Edit Dictionary / Reset / Quit. Menu-bar icon is the three-dots "processing" icon.

Restart Ollama: `brew services start ollama`. Click `Reset`. Menu-bar icon goes back to the idle I-beam; disabled reason item disappears.

- [ ] **Step 5: Verify the global hotkey works when another app is frontmost**

With `swift run speak-clean` running, open TextEdit → New Document. Focus TextEdit.
Press the configured shortcut (default: `option+space`). Speak a short sentence. Press the shortcut again.
Expected: After a short cleanup pause, the transcribed + cleaned sentence is pasted into the TextEdit document. Menu-bar icon cycles idle → recording (filled circle) → processing (three dots) → idle.

- [ ] **Step 6: Verify the flicker-suppression property**

With a recording in progress (hold the shortcut), in another terminal: `brew services stop ollama`.
While still recording, the `AppController` state may receive a failure — but the menu-bar icon must **not** flicker back to the idle icon; it must stay on the recording dot for the duration. After you release the shortcut, the app transitions to `.notReady` with the cleanup-failed reason.
Expected: Recording icon stays solid for the whole press-and-hold; only transitions when you release.

Restart Ollama and click `Reset`. Verify the app recovers.

- [ ] **Step 7: Verify clipboard is restored**

Copy some text (Cmd+C) in another app. Press the shortcut, speak, release.
Expected: After paste, wait ~200 ms and Cmd+V in a fresh document. The *original* copied text comes back — the dictation paste did not permanently displace your clipboard.

- [ ] **Step 8: Quit cleanly**

Click menu → `Quit`.
Expected: App exits cleanly, no crash report.

- [ ] **Step 9: Commit the smoke-test script**

No code change; this plan file records the checks. No commit needed for Step 8 itself. If smoke tests reveal bugs, fix them as additional tasks and re-run before finalizing.

---

## Done criteria

- [ ] `swift build` exits 0.
- [ ] `swift test` passes all suites (`AppControllerTests`, `StatusIconTests`, `PersonalLibraryTests`, `TextCleanerTests`, and `TextCleanerIntegrationTests` when Ollama is up).
- [ ] `Sources/speak-clean/speak_clean.swift` is gone from the repo.
- [ ] `Sources/speak-clean/SpeakCleanApp.swift` and `Sources/speak-clean/RecordingCoordinator.swift` exist.
- [ ] `AppController` is `@Observable` and has no `onStateChange` property.
- [ ] Manual smoke tests in Task 8 all pass.
- [ ] All changes committed to `feature/native-ai`.

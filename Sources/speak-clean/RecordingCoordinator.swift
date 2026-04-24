import AppKit

// MARK: - Phase and icon

/// Three-state pipeline phase owned by `RecordingCoordinator`. Mutually
/// exclusive by construction, so the menu-bar icon can be derived from
/// `(phase, availability)` without ever showing two "live" states at once.
enum RecordingPhase: Equatable {
    /// No mic active, no pipeline running.
    case idle
    /// Mic live.
    case recording
    /// stop→clean→paste pipeline in flight.
    case processing
}

/// Which menu-bar icon to show. Exposed at file scope (non-`@MainActor`)
/// so the flicker-regression property can be unit-tested as a pure function.
enum StatusIcon: Equatable {
    case idle
    case recording
    case processing
}

extension StatusIcon {
    /// Derive the icon from coordinator + controller state. Live phases
    /// (`.recording`, `.processing`) outrank availability; `.idle` defers
    /// to availability state.
    /// - Parameters:
    ///   - phase: The coordinator's current `RecordingPhase`.
    ///   - state: The `AppController` state at read time.
    static func from(phase: RecordingPhase, state: AppController.State) -> StatusIcon {
        switch phase {
        case .recording:  return .recording
        case .processing: return .processing
        case .idle:
            switch state {
            case .ready:    return .idle
            case .notReady: return .processing
            }
        }
    }
}

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

    /// Current pipeline phase. Drives the menu-bar icon (via `statusImage`)
    /// and gates hotkey re-entry. Mutated only on the main actor.
    private(set) var phase: RecordingPhase = .idle

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
        // Self-bootstrap. `SwiftUI Scene` has no `.task` modifier, and
        // `MenuBarExtra`'s content closure only renders when the menu is
        // open — neither is a correct place to run the first availability
        // check and install the hotkey. Spawning from `init` is fine
        // because `bootstrap()` is idempotent (guarded by `bootstrapped`).
        Task { [weak self] in
            await self?.bootstrap()
        }
    }

    @MainActor deinit {
        removeHotkey()
    }

    // MARK: - Derived (for the view)

    /// Icon to show in the menu bar. Priority lives in `StatusIcon.from`
    /// so the flicker-regression property is unit-testable.
    var statusImage: NSImage {
        switch StatusIcon.from(phase: phase, state: controller.state) {
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

    /// Hotkey dispatch. Single shortcut: `.idle` starts, `.recording`
    /// stops, `.processing` is a no-op (pipeline still running from the
    /// previous press).
    private func toggleRecording() {
        switch phase {
        case .idle:       startRecording()
        case .recording:  stopRecording()
        case .processing: break
        }
    }

    /// Begin recording if `.ready`, idle, and no outstanding stop task.
    /// On start-time failure, revert `phase` to `.idle` and flip the
    /// controller to `.notReady`.
    ///
    /// Sets `phase = .recording` synchronously before awaiting `start()`
    /// so two rapidly-fired hotkey events in the same main-actor tick
    /// can't both enter the body and then both call `transcriber.start()`.
    private func startRecording() {
        guard case .ready = controller.state, inFlight == nil, phase == .idle else { return }
        phase = .recording
        Task { @MainActor in
            do {
                try await controller.transcriber.start()
            } catch {
                print("[recording] start failed: \(error)")
                phase = .idle
                controller.setState(.notReady(reason: "Recording start failed: \(error.localizedDescription)"))
            }
        }
    }

    /// End recording, run the LLM cleanup pass, and paste the result.
    /// All async work lives in `inFlight` so a subsequent hotkey press can
    /// see `.processing` and no-op.
    ///
    /// Transitions `phase` from `.recording` to `.processing` synchronously,
    /// then back to `.idle` in the task's `defer` (runs on both success and
    /// error paths).
    private func stopRecording() {
        guard phase == .recording else { return }
        phase = .processing

        let controller = self.controller
        inFlight = Task { @MainActor [weak self] in
            defer {
                self?.inFlight = nil
                self?.phase = .idle
            }
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

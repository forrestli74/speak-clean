import Foundation
import SpeakCleanCore

/// Top-level state owner for the menu bar app.
///
/// Two-state machine (`.ready` / `.notReady(reason:)`). Owns the shared
/// `Transcriber` instance and the availability-check closure. `AppDelegate`
/// subscribes to state changes to drive the menu-bar icon + tooltip, and
/// calls `reset()` on launch and from the "Reset" menu item.
///
/// Error policy: any failure anywhere in the pipeline flips state to
/// `.notReady(reason:)`. Recovery is a single user-driven Reset — there
/// is no auto-retry.
@MainActor
final class AppController {
    /// The only two states the app surfaces to the UI. Ready means the
    /// hotkey will record; NotReady means the hotkey is a no-op and the
    /// `reason` string is shown as a menu tooltip.
    enum State: Sendable, Equatable {
        /// Availability checks passed; hotkey is live.
        case ready
        /// Something's blocking use. `reason` is user-facing copy.
        case notReady(reason: String)
    }

    /// Current state. Mutated only via `setState(_:)` so observers fire.
    private(set) var state: State = .notReady(reason: "Initializing…")

    /// Notified on every state change. Set by `AppDelegate` to drive
    /// icon and tooltip updates.
    var onStateChange: ((State) -> Void)?

    /// Availability-check closure. Injected so tests can replace it with
    /// a fake that returns a preset state without touching Apple
    /// Intelligence / SpeechAnalyzer APIs.
    private let check: () async -> State

    /// The single recording session holder. Public read access so the
    /// delegate can call `start/stop/cancel` directly; nothing in the
    /// controller mediates those calls.
    let transcriber = Transcriber()

    /// - Parameter check: Called from `reset()` to re-compute state.
    ///   Production supplies `runAvailabilityChecks`; tests supply a
    ///   closure returning a fixed state.
    init(check: @escaping () async -> State) {
        self.check = check
    }

    /// Cancel any in-flight transcription, flip to a transient
    /// "Checking availability…" state, then run `check()` and transition
    /// to its result. Called on launch and from the "Reset" menu item.
    func reset() async {
        await transcriber.cancel()
        setState(.notReady(reason: "Checking availability…"))
        setState(await check())
    }

    /// Write `newState` and fire `onStateChange`. Also the public entry
    /// point for external callers (`AppDelegate`) that need to force the
    /// app into `.notReady` after a recording/cleanup failure.
    func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }
}

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

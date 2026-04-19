import Foundation
import SpeakCleanCore

@MainActor
final class AppController {
    enum State: Sendable, Equatable {
        case ready
        case notReady(reason: String)
    }

    private(set) var state: State = .notReady(reason: "Initializing…")
    var onStateChange: ((State) -> Void)?

    private let check: @Sendable () async -> State
    let transcriber = Transcriber()

    init(check: @escaping @Sendable () async -> State) {
        self.check = check
    }

    /// Cancel any work, re-run availability checks.
    /// Called on launch and from the "Reset" menu item.
    func reset() async {
        await transcriber.cancel()
        transition(to: .notReady(reason: "Checking availability…"))
        transition(to: await check())
    }

    /// Record a failure (e.g., error thrown during a recording).
    func markFailed(_ reason: String) {
        transition(to: .notReady(reason: reason))
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }
}

import Foundation
import SpeakCleanCore

@MainActor
final class AppController {
    enum State: Sendable, Equatable {
        case ready
        case notReady(reason: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.ready, .ready): return true
            case (.notReady(let a), .notReady(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .notReady(reason: "Initializing…")
    var onStateChange: ((State) -> Void)?

    private let checker: AvailabilityChecker
    let transcriber = Transcriber()
    let cleaner = TextCleaner()

    init(checker: AvailabilityChecker) {
        self.checker = checker
    }

    /// Cancel any work, re-run availability checks, transition to the result.
    /// Called on launch and from the "Reset" menu item.
    func reset() async {
        await transcriber.cancel()

        transition(to: .notReady(reason: "Checking availability…"))
        transition(to: await checker.check())
    }

    /// Record a failure (e.g., error thrown during a recording). Forces Reset
    /// as the recovery path.
    func markFailed(_ reason: String) {
        transition(to: .notReady(reason: reason))
    }

    private func transition(to newState: State) {
        state = newState
        onStateChange?(newState)
    }
}

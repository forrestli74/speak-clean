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

    private let check: () async -> State
    let transcriber = Transcriber()

    init(check: @escaping () async -> State) {
        self.check = check
    }

    /// Cancel any work, re-run availability checks.
    /// Called on launch and from the "Reset" menu item.
    func reset() async {
        await transcriber.cancel()
        setState(.notReady(reason: "Checking availability…"))
        setState(await check())
    }

    func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }
}

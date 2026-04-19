import Testing
@testable import speak_clean

private final class FakeChecker: AvailabilityChecker, @unchecked Sendable {
    var nextResult: AppController.State
    var callCount = 0
    init(_ initial: AppController.State) { self.nextResult = initial }
    func check() async -> AppController.State {
        callCount += 1
        return nextResult
    }
}

@Suite("AppController")
struct AppControllerTests {

    @Test @MainActor func startsInNotReady() {
        let controller = AppController(checker: FakeChecker(.ready))
        if case .notReady = controller.state { } else {
            Issue.record("Expected .notReady at init, got \(controller.state)")
        }
    }

    @Test @MainActor func resetTransitionsToReadyWhenAvailable() async {
        let checker = FakeChecker(.ready)
        let controller = AppController(checker: checker)
        await controller.reset()
        if case .ready = controller.state { } else {
            Issue.record("Expected .ready, got \(controller.state)")
        }
        #expect(checker.callCount == 1)
    }

    @Test @MainActor func resetTransitionsToNotReadyWhenChecksFail() async {
        let checker = FakeChecker(.notReady(reason: "No AI"))
        let controller = AppController(checker: checker)
        await controller.reset()
        if case .notReady(let reason) = controller.state {
            #expect(reason == "No AI")
        } else {
            Issue.record("Expected .notReady, got \(controller.state)")
        }
    }

    @Test @MainActor func onStateChangeFiresForEachTransition() async {
        let checker = FakeChecker(.ready)
        let controller = AppController(checker: checker)
        var log: [String] = []
        controller.onStateChange = { state in
            switch state {
            case .ready: log.append("ready")
            case .notReady(let r): log.append("notReady(\(r))")
            }
        }
        await controller.reset()
        #expect(log == ["notReady(Checking availability…)", "ready"])
    }

    @Test @MainActor func secondResetRerunsChecks() async {
        let checker = FakeChecker(.ready)
        let controller = AppController(checker: checker)
        await controller.reset()
        await controller.reset()
        #expect(checker.callCount == 2)
    }
}

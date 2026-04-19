import Testing
@testable import speak_clean

@Suite("AppController")
struct AppControllerTests {

    @Test @MainActor func startsInNotReady() {
        let controller = AppController(check: { .ready })
        if case .notReady = controller.state { } else {
            Issue.record("Expected .notReady at init, got \(controller.state)")
        }
    }

    @Test @MainActor func resetTransitionsToReadyWhenAvailable() async {
        let controller = AppController(check: { .ready })
        await controller.reset()
        #expect(controller.state == .ready)
    }

    @Test @MainActor func resetTransitionsToNotReadyWhenChecksFail() async {
        let controller = AppController(check: { .notReady(reason: "No AI") })
        await controller.reset()
        #expect(controller.state == .notReady(reason: "No AI"))
    }

    @Test @MainActor func onStateChangeFiresForEachTransition() async {
        let controller = AppController(check: { .ready })
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
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let counter = Counter()
        let controller = AppController(check: {
            counter.count += 1
            return .ready
        })
        await controller.reset()
        await controller.reset()
        #expect(counter.count == 2)
    }
}

import Testing
@testable import speak_clean

@Suite("StatusIcon priority")
struct StatusIconTests {

    // Recording phase dominates over availability state.
    @Test func recordingBeatsReady() {
        #expect(StatusIcon.from(phase: .recording, state: .ready) == .recording)
    }

    @Test func recordingBeatsNotReady() {
        #expect(StatusIcon.from(phase: .recording, state: .notReady(reason: "x")) == .recording)
    }

    // Processing phase dominates over availability state.
    @Test func processingBeatsReady() {
        #expect(StatusIcon.from(phase: .processing, state: .ready) == .processing)
    }

    @Test func processingBeatsNotReady() {
        #expect(StatusIcon.from(phase: .processing, state: .notReady(reason: "x")) == .processing)
    }

    // Idle phase defers to availability state.
    @Test func idleReadyIsIdle() {
        #expect(StatusIcon.from(phase: .idle, state: .ready) == .idle)
    }

    @Test func idleNotReadyIsProcessing() {
        #expect(StatusIcon.from(phase: .idle, state: .notReady(reason: "x")) == .processing)
    }
}

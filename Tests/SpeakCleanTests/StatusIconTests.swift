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

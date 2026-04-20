import AppKit

/// Which menu-bar icon to show. Priority: recording trumps `AppController`
/// state. Exposed at file scope (non-`@MainActor`) so the flicker-regression
/// property can be unit-tested as a pure function.
enum StatusIcon: Equatable {
    case idle
    case recording
    case processing
}

extension StatusIcon {
    /// Derive the icon from coordinator + controller state.
    /// - Parameters:
    ///   - isRecording: Whether a recording is currently in flight.
    ///   - state: The `AppController` state at read time.
    static func from(isRecording: Bool, state: AppController.State) -> StatusIcon {
        if isRecording { return .recording }
        switch state {
        case .ready: return .idle
        case .notReady: return .processing
        }
    }
}

import AppKit
import SwiftUI

/// Menu-bar-only app entry point. One `MenuBarExtra` scene; all IO is
/// coordinated by `RecordingCoordinator` held as `@State`.
///
/// The activation policy is set in `init()` (before the scene instantiates)
/// so `.accessory` is in effect for the first frame and the dock-icon
/// flash that otherwise happens on SwiftUI app launch is suppressed.
struct SpeakCleanApp: App {
    @State private var coordinator = RecordingCoordinator()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            // `.notReady` reason is surfaced inside the popover — replaces
            // the old `NSStatusItem.button.toolTip` which has no
            // `MenuBarExtra` equivalent.
            if case .notReady(let reason) = coordinator.controller.state {
                Text(reason).foregroundStyle(.secondary)
                Divider()
            }
            Button("Edit Dictionary…") { coordinator.editDictionary() }
            Button("Reset") { Task { await coordinator.reset() } }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: coordinator.statusImage)
                .renderingMode(.template)
                .frame(width: 18, height: 18)
        }
        .menuBarExtraStyle(.menu)
    }
}

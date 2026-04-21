import AppKit
import SwiftUI

// MARK: - Menu bar icons

/// Programmatically drawn menu-bar icons. `isTemplate = true` so macOS
/// recolors them for light/dark menu bars automatically.
enum MenuBarIcon {
    /// Idle: I-beam text cursor plus a small waveform. Shown when ready
    /// and not recording.
    static func idle(height: CGFloat = 18) -> NSImage {
        let width = height
        let scale = height / 36.0
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.black.setStroke()
            let lw: CGFloat = 2.5 * scale
            let cursor = NSBezierPath()
            cursor.lineWidth = lw
            cursor.lineCapStyle = .round
            cursor.move(to: NSPoint(x: 6*scale, y: 6*scale));  cursor.line(to: NSPoint(x: 6*scale, y: 30*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 6*scale));  cursor.line(to: NSPoint(x: 10*scale, y: 6*scale))
            cursor.move(to: NSPoint(x: 2*scale, y: 30*scale)); cursor.line(to: NSPoint(x: 10*scale, y: 30*scale))
            cursor.stroke()
            for bar: (CGFloat, CGFloat, CGFloat) in [(16, 14, 22), (21, 8, 28), (26, 11, 25), (31, 14, 22)] {
                let path = NSBezierPath()
                path.lineWidth = lw
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: bar.0*scale, y: bar.1*scale))
                path.line(to: NSPoint(x: bar.0*scale, y: bar.2*scale))
                path.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Recording: filled circle. Shown while the mic is live.
    static func recording(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: true) { rect in
            NSColor.black.setFill()
            let inset = height * 0.15
            NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Processing / not-ready: three dots. Shown on startup, during
    /// transcription + cleanup, and whenever state is `.notReady`. The
    /// disabled reason menu item disambiguates.
    static func processing(height: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: true) { _ in
            NSColor.black.setFill()
            let r = height * 0.08
            let cy = height / 2
            let gap = height * 0.22
            for i in -1...1 {
                let cx = height/2 + CGFloat(i) * gap
                NSBezierPath(ovalIn: NSRect(x: cx-r, y: cy-r, width: r*2, height: r*2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - App

/// Menu-bar-only app entry point. One `MenuBarExtra` scene; all IO is
/// coordinated by `RecordingCoordinator` held as `@State`.
///
/// The activation policy is set in `init()` (before the scene instantiates)
/// so `.accessory` is in effect for the first frame and the dock-icon
/// flash that otherwise happens on SwiftUI app launch is suppressed.
///
/// Bootstrap (first availability check + hotkey install) is triggered
/// from `RecordingCoordinator.init()` via a `Task { await bootstrap() }`
/// rather than a Scene-level modifier — SwiftUI `Scene` has no `.task`,
/// and `MenuBarExtra`'s content closure only renders when the menu is open.
@main
struct SpeakCleanApp: App {
    @State private var coordinator = RecordingCoordinator()

    init() {
        // `NSApp` is nil inside a SwiftUI `@main App`'s init — the shared
        // `NSApplication` isn't created until something accesses `.shared`.
        // Use `.shared` directly to both create and configure it.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            if case .notReady(let reason) = coordinator.controller.state {
                Text(reason).foregroundStyle(.secondary)
                Divider()
            }
            SettingsMenuButton()
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

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

/// Menu-bar button that opens the Settings scene via SwiftUI's
/// `openSettings` action. Split out from the parent `Scene`'s content
/// closure because `@Environment(\.openSettings)` requires a `View`
/// context.
private struct SettingsMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") { openSettings() }
    }
}

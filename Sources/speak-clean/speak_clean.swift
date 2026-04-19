import AppKit
import SpeakCleanCore

// MARK: - Menu bar icons

/// Programmatically drawn menu-bar icons (one for each `AppController`
/// state we surface visually). They're `NSImage.isTemplate = true` so
/// macOS recolors them for light/dark menu bars automatically.
enum MenuBarIcon {
    /// Idle state: I-beam text cursor plus a small waveform. Shown when
    /// `AppController.state == .ready` and nothing is recording.
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

    /// Recording indicator: a filled circle. Shown while the mic is
    /// live (between `startRecording` and `stopRecording`).
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
    /// post-recording transcription + cleanup, and whenever
    /// `AppController.state == .notReady`. Tooltip disambiguates.
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

/// The app's `NSApplicationDelegate`. Owns the menu-bar status item,
/// global hotkey monitors, and the start/stop/paste flow that ties
/// `AppController` together with its `Transcriber` and `TextCleaner`.
/// Intentionally thin: all multi-step state lives in `AppController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu-bar item itself. Created in
    /// `applicationDidFinishLaunching`; displays icon + tooltip + menu.
    private var statusItem: NSStatusItem?

    /// `true` between `startRecording()` and `stopRecording()`. Gates
    /// re-entry of the hotkey handler and suppresses `onStateChange`
    /// icon updates while the recording icon is showing.
    private var isRecording = false

    /// The pending post-recording Task (stop → clean → paste). Gates
    /// `startRecording` so a second hotkey press can't race a still-
    /// running stop task whose `Transcriber.session` hasn't been
    /// cleared yet; if we skipped this, `transcriber.start()` would
    /// throw `alreadyRecording`.
    private var inFlight: Task<Void, Never>?

    /// The shared state owner. Set at launch.
    let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    /// Assign a template image to the status-bar button.
    private func setIcon(_ icon: NSImage) { statusItem?.button?.image = icon }

    /// App-startup entry point. Builds the status item + menu, hooks
    /// `controller.onStateChange` up to the icon/tooltip, registers the
    /// global hotkey, and kicks off the first availability check via
    /// `controller.reset()`.
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = buildMenu()
        setIcon(MenuBarIcon.processing())

        controller.onStateChange = { [weak self] state in
            guard let self, !self.isRecording else { return }
            switch state {
            case .ready:
                self.setIcon(MenuBarIcon.idle())
                self.statusItem?.button?.toolTip = "Ready"
            case .notReady(let reason):
                self.setIcon(MenuBarIcon.processing())
                self.statusItem?.button?.toolTip = reason
            }
        }

        setupGlobalShortcut()
        Task { await controller.reset() }
    }

    /// Construct the three-item status-bar menu: Edit Dictionary… /
    /// Reset / Quit.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit Dictionary…", action: #selector(editDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(resetController), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    /// Opens `dictionary.txt` in the user's default editor.
    @objc private func editDictionary() { AppConfig.openDictionary() }

    /// Manual-recovery action: re-runs availability checks via
    /// `AppController.reset()`. The single user-facing recovery path.
    @objc private func resetController() {
        Task { await controller.reset() }
    }

    /// Install both a global and a local `NSEvent` monitor for the
    /// configured shortcut. The global monitor catches presses when
    /// other apps are frontmost; the local one catches presses when
    /// this app's menu is open (rare, but important for `.accessory`
    /// apps). Both invoke `toggleRecording()`.
    private func setupGlobalShortcut() {
        guard let s = AppConfig.parsedShortcut else {
            print("Invalid shortcut: \(AppConfig.shortcut)")
            return
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(s.modifiers) && e.keyCode == s.keyCode {
                self?.toggleRecording()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.contains(s.modifiers) && e.keyCode == s.keyCode {
                self?.toggleRecording()
                return nil
            }
            return e
        }
    }

    /// Hotkey dispatch. Single shortcut toggles: press starts, press
    /// again stops.
    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    /// Begin recording if the controller is `.ready` and there's no
    /// outstanding stop task. On error, flips the app to `.notReady`
    /// (user must hit Reset).
    private func startRecording() {
        guard case .ready = controller.state, inFlight == nil else { return }
        Task { @MainActor in
            do {
                try await controller.transcriber.start()
                isRecording = true
                setIcon(MenuBarIcon.recording())
            } catch {
                print("[recording] start failed: \(error)")
                controller.setState(.notReady(reason: "Recording start failed: \(error.localizedDescription)"))
            }
        }
    }

    /// End recording, run the LLM cleanup pass, and paste the result.
    /// All the async work lives in the stored `inFlight` Task so a
    /// subsequent hotkey press can see "still processing" and no-op.
    /// Logs the raw transcript and per-stage timings to stderr.
    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        setIcon(MenuBarIcon.processing())

        let controller = self.controller
        inFlight = Task { @MainActor [weak self] in
            defer { self?.inFlight = nil }
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let raw = try await controller.transcriber.stop()
                let t1 = CFAbsoluteTimeGetCurrent()
                print("[raw] \(raw.isEmpty ? "(empty)" : raw) — transcribe=\(Self.ms(t1 - t0))ms")
                let cleaned = try await TextCleaner.clean(raw, dictionary: AppConfig.loadDictionary())
                let t2 = CFAbsoluteTimeGetCurrent()
                print("[cleaned] \(cleaned.isEmpty ? "(empty)" : cleaned) — clean=\(Self.ms(t2 - t1))ms total=\(Self.ms(t2 - t0))ms")
                if !cleaned.isEmpty {
                    self?.pasteText(cleaned)
                }
                self?.setIcon(MenuBarIcon.idle())
            } catch {
                print("[transcription failed] \(error)")
                controller.setState(.notReady(reason: "Transcription failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Seconds → whole-millisecond string, for log formatting.
    private static func ms(_ seconds: CFAbsoluteTime) -> String {
        String(Int((seconds * 1000).rounded()))
    }

    /// Inject `text` into the currently focused app by writing to the
    /// general pasteboard, synthesizing a Cmd+V keystroke, then
    /// restoring the previous clipboard contents ~100 ms later.
    private func pasteText(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .hidSystemState)
        let kd = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let ku = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        kd?.flags = .maskCommand
        ku?.flags = .maskCommand
        kd?.post(tap: .cghidEventTap)
        ku?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let p = previous {
                pb.clearContents()
                pb.setString(p, forType: .string)
            }
        }
    }
}

/// Executable entry point. Wires the shared `AppController` + its
/// production `runAvailabilityChecks` to the `AppDelegate` and starts
/// the AppKit run loop in `.accessory` activation policy (menu-bar only
/// — no window, no dock icon).
@main
enum Main {
    /// Constructs the app and starts the main run loop. Never returns.
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(check: runAvailabilityChecks)
        let delegate = AppDelegate(controller: controller)
        app.delegate = delegate
        app.run()
    }
}

import AppKit
import SpeakCleanCore

// MARK: - Menu bar icons

enum MenuBarIcon {
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var isRecording = false
    private var inFlight: Task<Void, Never>?
    let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    private func setIcon(_ icon: NSImage) { statusItem?.button?.image = icon }

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

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Edit Dictionary…", action: #selector(editDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset", action: #selector(resetController), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func editDictionary() { AppConfig.openDictionary() }

    @objc private func resetController() {
        Task { await controller.reset() }
    }

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

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

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

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        setIcon(MenuBarIcon.processing())

        let controller = self.controller
        inFlight = Task { @MainActor [weak self] in
            defer { self?.inFlight = nil }
            do {
                let raw = try await controller.transcriber.stop()
                let cleaned = try await TextCleaner.clean(raw, dictionary: AppConfig.loadDictionary())
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

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(check: runAvailabilityChecks)
        let delegate = AppDelegate(controller: controller)
        app.delegate = delegate
        app.run()
    }
}

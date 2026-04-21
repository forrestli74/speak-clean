import SwiftUI

/// Minimal Settings pane: a `Form` with two text fields and a
/// "Reset to Defaults" button. Each field commits on Return or
/// loss of focus (no Save button). Invalid shortcut input keeps
/// its red-border state and does not persist; the previously
/// installed shortcut keeps working. Model changes trigger a full
/// availability re-check via `AppController.reset()`.
///
/// The view is instantiated inside the `Settings { ... }` scene in
/// `SpeakCleanApp.body` and receives the shared `RecordingCoordinator`
/// by reference.
@MainActor
struct SettingsView: View {
    /// The app's single coordinator. Used to reinstall the hotkey
    /// monitor after a shortcut change and to trigger an availability
    /// re-check after a model change. Not observed — the view does
    /// not render from coordinator state.
    let coordinator: RecordingCoordinator

    @State private var shortcutText: String = AppConfig.shortcut
    @State private var modelText: String = AppConfig.cleanupModel
    @FocusState private var shortcutFocused: Bool
    @FocusState private var modelFocused: Bool

    /// Parse-based validity. `nil` means the user hasn't typed a
    /// recognizable shortcut yet; we show a red border and do not
    /// persist on commit.
    private var shortcutIsValid: Bool {
        AppConfig.parse(shortcutText.trimmingCharacters(in: .whitespaces)) != nil
    }

    var body: some View {
        Form {
            LabeledContent("Shortcut") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("option+space", text: $shortcutText)
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.red, lineWidth: shortcutIsValid ? 0 : 1)
                        )
                        .focused($shortcutFocused)
                        .onSubmit { commitShortcut() }
                        .onChange(of: shortcutFocused) { wasFocused, isFocused in
                            if wasFocused && !isFocused { commitShortcut() }
                        }
                    if !shortcutIsValid {
                        Text("Use e.g. option+space — one or more modifiers plus a known key")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            LabeledContent("Model") {
                TextField("gemma4:e2b", text: $modelText)
                    .textFieldStyle(.roundedBorder)
                    .focused($modelFocused)
                    .onSubmit { commitModel() }
                    .onChange(of: modelFocused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { commitModel() }
                    }
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") { resetToDefaults() }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func commitShortcut() {
        let trimmed = shortcutText.trimmingCharacters(in: .whitespaces)
        guard AppConfig.parse(trimmed) != nil else { return }
        AppConfig.shortcut = trimmed
        shortcutText = trimmed
        coordinator.reinstallHotkey()
    }

    private func commitModel() {
        let trimmed = modelText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            modelText = AppConfig.cleanupModel
            return
        }
        AppConfig.cleanupModel = trimmed
        modelText = trimmed
        Task { await coordinator.reset() }
    }

    private func resetToDefaults() {
        AppConfig.shortcut = AppConfig.defaultShortcut
        AppConfig.cleanupModel = AppConfig.defaultCleanupModel
        shortcutText = AppConfig.defaultShortcut
        modelText = AppConfig.defaultCleanupModel
        coordinator.reinstallHotkey()
        Task { await coordinator.reset() }
    }
}

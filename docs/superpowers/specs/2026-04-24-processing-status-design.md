# Processing Status Indicator — Design

## Problem

Today, the menu-bar icon goes straight from `.recording` (red dot) back to `.idle` (cursor + waveform) the moment the user releases the hotkey. The pipeline that actually produces output — `transcriber.stop()` finalization plus the Ollama `TextCleaner.clean()` round-trip — can take several seconds, during which the UI gives no signal that the app is working. If Ollama is slow or hung, the user has no way to tell whether the app "heard" them or silently dropped the recording.

## Goal

Surface the stop→clean→paste window as a distinct "processing" phase: show the existing 3-dot icon and a `Transcribing…` message in the menu for as long as the pipeline is in flight. When it completes (paste lands, or an error surfaces), the UI returns to its prior behavior.

Out of scope: progress granularity (separate "finalizing transcription" vs "cleaning up" states), cancellation of an in-flight pipeline, any change to `AppController.State`.

## Approach

Replace `RecordingCoordinator.isRecording: Bool` with an explicit three-state `RecordingPhase` enum. The coordinator already derives the icon via a pure function (`StatusIcon.from`); hoisting the recording state to an enum one level up enforces mutual exclusion by the type system rather than by convention across two booleans.

## Components

### `RecordingPhase` (new)

Added to `Sources/speak-clean/RecordingCoordinator.swift` alongside `StatusIcon`.

```swift
enum RecordingPhase: Equatable {
    case idle         // no mic active, no pipeline running
    case recording    // mic live
    case processing   // stop→clean→paste pipeline in flight
}
```

### `RecordingCoordinator`

- `private(set) var isRecording: Bool` → `private(set) var phase: RecordingPhase = .idle`
- `toggleRecording()` switches on `phase`:
  - `.recording` → `stopRecording()`
  - `.idle` → `startRecording()`
  - `.processing` → no-op (explicit; today this is an implicit no-op via the `inFlight == nil` guard)
- `startRecording()` guard becomes `case .ready = controller.state, inFlight == nil, phase == .idle`. Sets `phase = .recording` synchronously before awaiting `transcriber.start()`; the catch block reverts `phase = .idle` on failure (and flips controller to `.notReady`, same as today).
- `stopRecording()` guard becomes `phase == .recording`. Sets `phase = .processing` synchronously before dispatching the `inFlight` task. The existing `defer { self?.inFlight = nil }` gains one line: `self?.phase = .idle`. This runs on both success and error paths.

### `StatusIcon.from` (signature change)

```swift
static func from(phase: RecordingPhase, state: AppController.State) -> StatusIcon {
    switch phase {
    case .recording:  return .recording
    case .processing: return .processing
    case .idle:
        switch state {
        case .ready:    return .idle
        case .notReady: return .processing
        }
    }
}
```

Priority is now explicit: live phases (`.recording`, `.processing`) outrank availability; `.idle` defers to availability.

### Menu (`SpeakCleanApp.swift`)

Add a mutually-exclusive branch above the existing `.notReady` branch:

```swift
if coordinator.phase == .processing {
    Text("Transcribing…").foregroundStyle(.secondary)
    Divider()
} else if case .notReady(let reason) = coordinator.controller.state {
    Text(reason).foregroundStyle(.secondary)
    Divider()
}
```

The `else if` matters. If the pipeline errors, the catch block flips controller to `.notReady` **before** the defer sets `phase = .idle`. When the dust settles: `phase == .idle && state == .notReady` — the actionable error reason wins over the transient "Transcribing…" label.

## State transition table

| Trigger                                    | Phase change                  | Controller state change |
|--------------------------------------------|-------------------------------|-------------------------|
| `startRecording()` passes guards           | `.idle` → `.recording`        | —                       |
| `transcriber.start()` throws               | `.recording` → `.idle`        | → `.notReady(reason:)`  |
| `stopRecording()` enters                   | `.recording` → `.processing`  | —                       |
| `inFlight` task completes (success)        | `.processing` → `.idle`       | —                       |
| `inFlight` task throws                     | `.processing` → `.idle`       | → `.notReady(reason:)`  |

## User-visible behavior

- **Normal flow:** press hotkey → red dot → release → 3 dots + "Transcribing…" in menu → paste lands → cursor+waveform. Today the middle step is invisible.
- **Hotkey pressed during processing:** swallowed silently. Icon stays on 3 dots, menu keeps "Transcribing…". User can start a new recording once the icon returns to idle.
- **Pipeline error:** icon stays on 3 dots (shared with `.notReady` by design), menu swaps from "Transcribing…" to the specific error reason (e.g. "Transcription failed: …"). User can hit Reset.
- **Start-time error** (unchanged): icon drops the red dot and lands on 3 dots with "Recording start failed: …".

## Testing

`Tests/SpeakCleanTests/StatusIconTests.swift` — rewrite against the new signature. Six cases, from the table above:

| `phase`       | `state`      | Expected icon  |
|---------------|--------------|----------------|
| `.recording`  | `.ready`     | `.recording`   |
| `.recording`  | `.notReady`  | `.recording`   |
| `.processing` | `.ready`     | `.processing`  |
| `.processing` | `.notReady`  | `.processing`  |
| `.idle`       | `.ready`     | `.idle`        |
| `.idle`       | `.notReady`  | `.processing`  |

No new integration tests — pipeline behavior is unchanged; this is a UI-derivation change. Manual verification: record a short utterance, release, confirm the 3-dot icon + "Transcribing…" menu item appear until paste lands.

## Files touched

- `Sources/speak-clean/RecordingCoordinator.swift` — add `RecordingPhase`, rewire guards, rename/rewrite `StatusIcon.from`, update `statusImage` switch.
- `Sources/speak-clean/SpeakCleanApp.swift` — add processing branch to `MenuBarExtra` content.
- `Tests/SpeakCleanTests/StatusIconTests.swift` — rewrite to new signature, six cases.

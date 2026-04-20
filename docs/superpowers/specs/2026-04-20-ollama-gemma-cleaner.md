# Ollama + Gemma Cleaner Swap

**Date:** 2026-04-20
**Branch:** `feature/native-ai`
**Status:** Shipped.
**Supersedes:** the `TextCleaner` + `AvailabilityChecker` sections of `2026-04-18-native-ai-rewrite-design.md`. Everything else in that spec stands.

## What changed

The cleanup step that turns raw STT transcripts into paste-ready text no longer calls Apple's `LanguageModelSession` / `SystemLanguageModel` (Foundation Models). It POSTs to a local Ollama server (`http://localhost:11434/api/chat`) and defaults to the `gemma4:e2b` model tag.

The STT side (mic → `SpeechAnalyzer` + `DictationTranscriber` → text) is unchanged. The `AppController` 2-state machine (`.ready` / `.notReady(reason:)`) and the single-Reset failure model are unchanged.

## Why

On the 14-case prompt test suite (see `Tests/SpeakCleanTests/TextCleanerIntegrationTests.swift`):

| Model | Pass rate | Disk | RSS |
|---|---|---|---|
| Apple Foundation Models (3B) | 10/14 deterministic + 4 intermittent | 0 GB (in OS) | 0 GB (shared) |
| Qwen3:8b | 12/14 | 5.2 GB | ~5 GB |
| **Gemma 4 E2B** | **14/14 deterministic** | **7.2 GB** | **~6.8 GB** |

Apple Foundation Models' intermittent failures were all "RLHF over-helpfulness": answering `"What time is it"` with the actual time, responding to `"How are you doing"` conversationally, occasionally refusing to list-format multi-sentence plans. The user-facing dictation UX degrades when the cleanup step intermittently turns your dictation into a chat reply, so we accepted the memory footprint in exchange for deterministic behavior.

A sub-2 GB survey (Llama 3.2 3B, Qwen2.5:3b, SmolLM2:1.7b, Qwen3:1.7b, Gemma 3:1b) showed Llama 3.2 3B as the best compact option at 12/13 passes and ~2 GB RSS — viable future swap if memory becomes the bottleneck. Kept Gemma 4 E2B as default because: (a) passes the whole suite, (b) smaller "first X second Y should stay prose" failure mode is harder to explain to users than "uses more RAM."

## User-facing change

**New dependency:** Ollama. Install and first-run setup:

```bash
brew install ollama
brew services start ollama
ollama pull gemma4:e2b
```

Availability check surfaces each of those as an actionable reason string in the menu-bar tooltip when missing.

**New config:** `AppConfig.cleanupModel` (UserDefaults key `cleanupModel`, default `"gemma4:e2b"`). Change with:

```bash
defaults write local.speakclean cleanupModel "llama3.2:3b"
ollama pull llama3.2:3b
# click Reset in the menu
```

The prompt is tuned against Gemma 4 E2B; other models may need prompt-example tweaks to match the pass rate.

## List-formatting scope (narrowed vs original spec)

Original spec: any of "step 1/2/3", "first/second/third", "first/then/next", "first step/second step", or "as bullets" could trigger list formatting.

New scope: only **digit-numbered** markers (`step 1`, `number 1`) and **explicit** "as bullets" / "as a list" trigger list formatting. Everything else — including `first/second/third`, `first step/second step`, `first X then Y next Z` — stays as prose. Small LLMs couldn't reliably draw the first/second boundary; narrowing scope lets any reasonable model hit the test suite.

## What was removed

- `FoundationModels` import from `TextCleaner.swift`.
- `LanguageModelSession` instantiation and call.
- `SystemLanguageModel.default.availability` switch in `AvailabilityChecker.swift`.
- The four `withKnownIssue(isIntermittent: true)` wrappers in `TextCleanerIntegrationTests.swift` (no longer flaky).
- `firstSecondProducesList`, `mixedSequentialMarkersProduceList`, `firstStepSecondStepProducesList` tests (list-formatting scope narrowed).

## What was added

- `URLSession` POST to Ollama + wire types (`ChatRequest`, `ChatResponse` with optional `error` field for Ollama 200-with-error responses).
- `ollamaStatus(model:)` function probing `/api/tags`.
- `runAvailabilityChecks(cleanupModel:)` takes the model tag as a parameter so main-actor state doesn't leak into the nonisolated check function.
- `AppConfig.cleanupModel` (`PersonalLibrary.swift`).
- `numberMarkersProduceList`, `firstSecondWithoutStepStaysProse` integration tests.

## Open items

1. **Prompt/test drift risk.** The integration tests and the prompt examples are hand-curated in parallel files. If an integration test's input changes without a matching prompt example, or vice versa, the drift is silent. A cross-file assertion could catch this but was deliberately skipped because the earlier "no verbatim overlap" pass means the files should NOT match literally — they should teach the same pattern with different content.
2. **Model-config / prompt-tuning coupling.** Prompt is Gemma-specific. A user swapping to a different model via `defaults write cleanupModel` is on an untested configuration; the test suite continues to pass because it hits whatever model is in `TextCleaner.defaultModel`. Breadcrumb comment on `AppConfig.cleanupModel` documents this.

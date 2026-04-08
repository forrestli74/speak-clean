# Download Manager Design

## Overview

A `DownloadManager` type in `SpeakCleanCore` that handles file downloading with resume, checksum verification, and cache reuse. `ModelManager` delegates all file fetching to it.

## File Lifecycle

```
(nothing) -> .download (partial) -> .download (complete, verified) -> final file
```

States:
1. **No file, no temp** -- fresh download
2. **`.download` exists** -- resume from byte offset
3. **Final file exists** -- skip entirely (cache hit, no checksum, no network)

## Types

### DownloadManager

```swift
public struct DownloadManager {
    /// Downloads file with resume + checksum verification.
    /// No-ops if destination already exists.
    func fetch(
        from url: URL,
        to destination: URL,
        expectedSHA256: String?
    ) async throws
}
```

Generic -- knows nothing about HuggingFace or models. Takes a URL, a destination, and an optional checksum.

### ModelManager changes

`ModelManager` owns HuggingFace-specific logic:
- Fetches expected SHA256 from HF API before calling `DownloadManager.fetch()`
- Constructs HF download URLs
- Delegates all downloading to `DownloadManager`

```swift
// ModelManager usage
let sha = try await fetchSHA256(for: filename)  // HF API call
try await downloadManager.fetch(from: fileURL, to: localURL, expectedSHA256: sha)
```

## Resume Flow

1. Check if `destination` exists -- return (cache hit, no network)
2. Check if `destination.download` exists -- get its byte size
3. If partial exists, create `URLRequest` with `Range: bytes=<size>-` header
4. Handle response:
   - **200** -- server doesn't support Range or file changed; delete partial, restart
   - **206 Partial Content** -- append to existing `.download` file
   - **416 Range Not Satisfiable** -- partial is invalid; delete and restart
5. Stream response bytes to `.download` file (append mode for 206, write mode for 200)
6. After download completes, verify SHA256 checksum
7. Atomic move `.download` -> final destination

## Checksum Flow

1. `ModelManager` fetches expected SHA256 from HF API (`GET /api/models/{repo}/tree/main`)
2. If HF API fails and no cached file exists -- download proceeds without checksum (best effort)
3. `DownloadManager.fetch()` receives `expectedSHA256` (or nil if API failed)
4. After download completes, if `expectedSHA256` is non-nil:
   - Hash the `.download` file with SHA256
   - Match -- move `.download` to final location
   - Mismatch -- delete `.download`, throw `checksumMismatch` error
5. If `expectedSHA256` is nil -- move `.download` to final location without verification

Once a file is in its final location, it is trusted forever. Checksum only gates the `.download` -> final move. The only way to force re-download is `cleanCache()`.

## Error Handling

| Scenario | Behavior |
|---|---|
| Network fails mid-download | `.download` stays on disk, next attempt resumes |
| Checksum mismatch | Delete `.download`, throw `checksumMismatch` |
| Server returns 416 | Delete `.download`, retry fresh (one retry) |
| HF API unreachable, no cache | Download without checksum (best effort) |
| Disk full | `.download` stays partial, next attempt resumes |

## Error Types

```swift
public enum DownloadError: Error, LocalizedError {
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
}
```

## File Layout

```
~/Library/Application Support/SpeakClean/models/
  ggml-base.en.bin              # final model (trusted)
  ggml-base.en.bin.download     # partial/in-progress download
  ggml-base.en-encoder.mlmodelc.zip.download  # partial CoreML download
  ggml-base.en-encoder.mlmodelc/              # extracted CoreML encoder
```

## Scope

- New file: `Sources/SpeakCleanCore/DownloadManager.swift`
- Modified file: `Sources/SpeakCleanCore/ModelManager.swift` (delegate to DownloadManager, add HF SHA256 fetch)
- Applies to both GGML model and CoreML encoder zip downloads

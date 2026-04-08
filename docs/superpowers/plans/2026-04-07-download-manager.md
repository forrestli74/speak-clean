# Download Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the naive download in `ModelManager` with a `DownloadManager` that supports resume, SHA256 checksum verification, and cache reuse.

**Architecture:** New `DownloadManager` struct handles generic HTTP downloading with resume (Range headers) and checksum. `ModelManager` delegates to it and owns HuggingFace-specific logic (SHA256 lookup, URL construction). Cancellation handled via Swift cooperative cancellation.

**Tech Stack:** Swift 6.2, Foundation (URLSession, CryptoKit), Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-04-07-download-manager-design.md`

---

### File Map

| File | Action | Responsibility |
|---|---|---|
| `Sources/SpeakCleanCore/DownloadManager.swift` | Create | Generic download with resume + checksum |
| `Sources/SpeakCleanCore/ModelManager.swift` | Modify | Delegate to DownloadManager, add HF SHA256 fetch |
| `Tests/SpeakCleanTests/DownloadManagerTests.swift` | Create | Unit tests for DownloadManager |

---

### Task 1: DownloadManager — cache hit + fresh download

**Files:**
- Create: `Tests/SpeakCleanTests/DownloadManagerTests.swift`
- Create: `Sources/SpeakCleanCore/DownloadManager.swift`

- [ ] **Step 1: Write failing test for cache hit**

```swift
import Testing
import Foundation
@testable import SpeakCleanCore

@Suite("DownloadManager")
struct DownloadManagerTests {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test func skipsDownloadWhenDestinationExists() async throws {
        let destination = tempDir.appendingPathComponent("existing-file.bin")
        try "cached content".write(to: destination, atomically: true, encoding: .utf8)

        let dm = DownloadManager()
        // URL doesn't matter — should never be hit
        let fakeURL = URL(string: "https://localhost:1/nonexistent")!
        try await dm.fetch(from: fakeURL, to: destination, expectedSHA256: nil)

        // File unchanged
        let content = try String(contentsOf: destination, encoding: .utf8)
        #expect(content == "cached content")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DownloadManagerTests/skipsDownloadWhenDestinationExists 2>&1`
Expected: FAIL — `DownloadManager` type does not exist

- [ ] **Step 3: Write minimal DownloadManager with cache hit and fresh download**

```swift
import Foundation
import CryptoKit

public struct DownloadManager: Sendable {
    public init() {}

    public func fetch(
        from url: URL,
        to destination: URL,
        expectedSHA256: String?
    ) async throws {
        // Cache hit — file already exists, trust it
        if FileManager.default.fileExists(atPath: destination.path) {
            return
        }

        let tempURL = destination.appendingPathExtension("download")

        // Check for partial download
        var existingBytes: Int64 = 0
        if FileManager.default.fileExists(atPath: tempURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
           let size = attrs[.size] as? Int64 {
            existingBytes = size
        }

        // Build request with Range header if resuming
        var request = URLRequest(url: url)
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.downloadFailed(url.lastPathComponent)
        }

        switch httpResponse.statusCode {
        case 200:
            // Server doesn't support Range or file changed — start fresh
            if existingBytes > 0 {
                try? FileManager.default.removeItem(at: tempURL)
            }
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        case 206:
            // Partial content — will append
            break

        case 416:
            // Range not satisfiable — delete partial and retry once
            try? FileManager.default.removeItem(at: tempURL)
            try await fetchFresh(from: url, to: destination, tempURL: tempURL, expectedSHA256: expectedSHA256)
            return

        default:
            throw DownloadError.downloadFailed(url.lastPathComponent)
        }

        // Stream bytes to temp file
        let handle = try FileHandle(forWritingTo: tempURL)
        if httpResponse.statusCode == 206 {
            handle.seekToEndOfFile()
        }

        var buffer = Data()
        let chunkSize = 256 * 1024  // 256KB flush interval

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= chunkSize {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
        }
        handle.closeFile()

        // Verify checksum
        if let expected = expectedSHA256 {
            let actual = try sha256(of: tempURL)
            if actual != expected.lowercased() {
                try? FileManager.default.removeItem(at: tempURL)
                throw DownloadError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        // Atomic move to final destination
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func fetchFresh(
        from url: URL,
        to destination: URL,
        tempURL: URL,
        expectedSHA256: String?
    ) async throws {
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DownloadError.downloadFailed(url.lastPathComponent)
        }

        let handle = try FileHandle(forWritingTo: tempURL)
        var buffer = Data()
        let chunkSize = 256 * 1024

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= chunkSize {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
        }
        handle.closeFile()

        if let expected = expectedSHA256 {
            let actual = try sha256(of: tempURL)
            if actual != expected.lowercased() {
                try? FileManager.default.removeItem(at: tempURL)
                throw DownloadError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DownloadError: Error, LocalizedError {
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let name):
            return "Failed to download: \(name)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected), got \(actual)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DownloadManagerTests/skipsDownloadWhenDestinationExists 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SpeakCleanCore/DownloadManager.swift Tests/SpeakCleanTests/DownloadManagerTests.swift
git commit -m "Add DownloadManager with cache hit, resume, and checksum"
```

---

### Task 2: DownloadManager — checksum verification test

**Files:**
- Modify: `Tests/SpeakCleanTests/DownloadManagerTests.swift`

- [ ] **Step 1: Write failing test for checksum mismatch**

We need a local HTTP server to test real downloads. Add a minimal test helper and checksum test:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP server for tests. Serves `data` at any path.
final class TestHTTPServer {
    let port: UInt16
    private var listener: Task<Void, Never>?
    private let data: Data

    init(data: Data, port: UInt16 = 0) throws {
        self.data = data
        // Use a random available port
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = port.bigEndian
        var addrCopy = addr
        let bindResult = withUnsafePointer(to: &addrCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0, "bind failed")
        listen(socket, 1)

        // Get assigned port
        var assignedAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &assignedAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &len)
            }
        }
        self.port = UInt16(bigEndian: assignedAddr.sin_port)

        Darwin.close(socket)
        // We'll use a simpler approach — URLProtocol stub
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func stop() {
        listener?.cancel()
    }
}
```

Actually, a raw socket server is complex and brittle for tests. A simpler approach: create a temp file, use `file://` URL, and test checksum logic. But `DownloadManager` uses URLSession which doesn't support Range for `file://`. Instead, use `URLProtocol` stubbing:

```swift
/// URLProtocol stub that serves fixed data for tests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var responseHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: Self.responseHeaders
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

However, `URLSession.shared` won't use custom URLProtocol. We need to inject a `URLSession` into `DownloadManager`. Update the approach:

Update `DownloadManager.init` to accept an optional `URLSession`:

```swift
public struct DownloadManager: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }
    // ... use self.session instead of URLSession.shared
}
```

Then in tests, create a session with the stub protocol:

```swift
extension DownloadManagerTests {
    func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

Now write the checksum tests:

```swift
@Test func rejectsChecksumMismatch() async throws {
    let data = Data("test file content".utf8)
    StubURLProtocol.responseData = data
    StubURLProtocol.statusCode = 200

    let dm = DownloadManager(session: makeSession())
    let destination = tempDir.appendingPathComponent("checksum-test.bin")

    await #expect(throws: DownloadError.self) {
        try await dm.fetch(
            from: URL(string: "https://test/file.bin")!,
            to: destination,
            expectedSHA256: "0000000000000000000000000000000000000000000000000000000000000000"
        )
    }

    // Temp file should be cleaned up
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(
        atPath: destination.appendingPathExtension("download").path))
}

@Test func acceptsCorrectChecksum() async throws {
    // Note: add `import CryptoKit` at top of test file
    let data = Data("test file content".utf8)
    let expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

    StubURLProtocol.responseData = data
    StubURLProtocol.statusCode = 200

    let dm = DownloadManager(session: makeSession())
    let destination = tempDir.appendingPathComponent("checksum-pass.bin")

    try await dm.fetch(
        from: URL(string: "https://test/file.bin")!,
        to: destination,
        expectedSHA256: expectedHash
    )

    #expect(FileManager.default.fileExists(atPath: destination.path))
    let downloaded = try Data(contentsOf: destination)
    #expect(downloaded == data)
}

@Test func downloadsWithoutChecksumWhenNil() async throws {
    let data = Data("no checksum needed".utf8)
    StubURLProtocol.responseData = data
    StubURLProtocol.statusCode = 200

    let dm = DownloadManager(session: makeSession())
    let destination = tempDir.appendingPathComponent("no-checksum.bin")

    try await dm.fetch(
        from: URL(string: "https://test/file.bin")!,
        to: destination,
        expectedSHA256: nil
    )

    #expect(FileManager.default.fileExists(atPath: destination.path))
}
```

- [ ] **Step 2: Update DownloadManager to accept injected URLSession**

Change `DownloadManager`:
```swift
public struct DownloadManager: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }
    // Replace all URLSession.shared with self.session
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `swift test --filter DownloadManagerTests 2>&1`
Expected: All 4 tests PASS

- [ ] **Step 4: Commit**

```bash
git add Tests/SpeakCleanTests/DownloadManagerTests.swift Sources/SpeakCleanCore/DownloadManager.swift
git commit -m "Add checksum verification tests with URLProtocol stub"
```

---

### Task 3: Refactor ModelManager to use DownloadManager

**Files:**
- Modify: `Sources/SpeakCleanCore/ModelManager.swift`

- [ ] **Step 1: Write failing test for HF SHA256 fetch**

```swift
@Suite("ModelManager")
struct ModelManagerTests {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ModelManagerTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test func fetchesSHA256FromHuggingFaceAPI() async throws {
        // Stub HF API response for /api/models/ggerganov/whisper.cpp/tree/main
        let hfResponse = """
        [{"type":"file","oid":"abc123","size":141874554,"path":"ggml-base.en.bin",
          "lfs":{"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","size":141874554}}]
        """
        StubURLProtocol.responseData = Data(hfResponse.utf8)
        StubURLProtocol.statusCode = 200

        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [StubURLProtocol.self]
            return c
        }())

        let manager = ModelManager(modelsDir: tempDir, session: session)
        let sha = try await manager.fetchSHA256(for: "ggml-base.en.bin")
        #expect(sha == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func fetchSHA256ReturnsNilOnAPIFailure() async throws {
        StubURLProtocol.statusCode = 500
        StubURLProtocol.responseData = Data()

        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.protocolClasses = [StubURLProtocol.self]
            return c
        }())

        let manager = ModelManager(modelsDir: tempDir, session: session)
        let sha = try await manager.fetchSHA256(for: "ggml-base.en.bin")
        #expect(sha == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelManagerTests 2>&1`
Expected: FAIL — `fetchSHA256` method doesn't exist, `ModelManager` doesn't accept `session` parameter

- [ ] **Step 3: Refactor ModelManager**

Replace the `download()` method and add HF API integration:

```swift
import Foundation

public final class ModelManager: Sendable {
    private let modelsDir: URL
    private let downloadManager: DownloadManager
    private let session: URLSession

    private static let hfRepo = "ggerganov/whisper.cpp"
    private static let hfBaseURL = "https://huggingface.co/\(hfRepo)/resolve/main/"
    private static let hfAPIURL = "https://huggingface.co/api/models/\(hfRepo)/tree/main"

    public init(modelsDir: URL, session: URLSession = .shared) {
        self.modelsDir = modelsDir
        self.session = session
        self.downloadManager = DownloadManager(session: session)
    }

    public func modelURL(for model: String) async throws -> URL {
        let filename = "ggml-\(model).bin"
        let localURL = modelsDir.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: localURL.path) {
            let sha = try await fetchSHA256(for: filename)
            let remoteURL = URL(string: "\(Self.hfBaseURL)\(filename)")!
            try await downloadManager.fetch(from: remoteURL, to: localURL, expectedSHA256: sha)
        }

        // CoreML encoder
        let coremlDir = modelsDir.appendingPathComponent("ggml-\(model)-encoder.mlmodelc")
        if !FileManager.default.fileExists(atPath: coremlDir.path) {
            try await downloadCoreML(model: model)
        }

        return localURL
    }

    /// Fetches SHA256 for a file from HuggingFace API. Returns nil on failure (best effort).
    public func fetchSHA256(for filename: String) async -> String? {
        guard let apiURL = URL(string: Self.hfAPIURL) else { return nil }

        do {
            let (data, response) = try await session.data(from: apiURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            struct HFFile: Decodable {
                let path: String
                let lfs: LFS?
                struct LFS: Decodable {
                    let sha256: String
                }
            }

            let files = try JSONDecoder().decode([HFFile].self, from: data)
            return files.first(where: { $0.path == filename })?.lfs?.sha256
        } catch {
            return nil
        }
    }

    public func cleanCache() throws {
        if FileManager.default.fileExists(atPath: modelsDir.path) {
            try FileManager.default.removeItem(at: modelsDir)
            print("Model cache cleaned.")
        }
    }

    private func downloadCoreML(model: String) async throws {
        let zipFilename = "ggml-\(model)-encoder.mlmodelc.zip"
        let zipURL = modelsDir.appendingPathComponent(zipFilename)

        let sha = try await fetchSHA256(for: zipFilename)
        let remoteURL = URL(string: "\(Self.hfBaseURL)\(zipFilename)")!
        try await downloadManager.fetch(from: remoteURL, to: zipURL, expectedSHA256: sha)

        // Unzip
        print("Extracting \(zipFilename)...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipURL.path, "-d", modelsDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelError.extractFailed(zipFilename)
        }

        try? FileManager.default.removeItem(at: zipURL)
        print("CoreML encoder ready: ggml-\(model)-encoder.mlmodelc")
    }
}

public enum ModelError: Error, LocalizedError {
    case extractFailed(String)

    public var errorDescription: String? {
        switch self {
        case .extractFailed(let name): return "Failed to extract: \(name)"
        }
    }
}
```

Note: `ModelError.downloadFailed` is removed — `DownloadError` handles that now.

- [ ] **Step 4: Update callers that reference `ModelError.downloadFailed`**

Search for `ModelError.downloadFailed` in the codebase. If any callers catch it, update to catch `DownloadError.downloadFailed` instead.

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1`
Expected: All tests PASS (TextCleaner + DownloadManager + ModelManager tests)

- [ ] **Step 6: Commit**

```bash
git add Sources/SpeakCleanCore/ModelManager.swift Tests/SpeakCleanTests/DownloadManagerTests.swift
git commit -m "Refactor ModelManager to delegate downloads to DownloadManager"
```

---

### Task 4: Manual integration test

**Files:** None (verification only)

- [ ] **Step 1: Clean model cache and test fresh download**

```bash
rm -rf ~/Library/Application\ Support/SpeakClean/models/
swift run speak-clean --audio output/recording-2026-04-08T05-14-39Z.wav
```

Expected: Downloads GGML model + CoreML encoder with checksum verification, then transcribes.

- [ ] **Step 2: Test cache hit (second run)**

```bash
swift run speak-clean --audio output/recording-2026-04-08T05-14-39Z.wav
```

Expected: No download, uses cached model, transcribes immediately.

- [ ] **Step 3: Test resume (interrupt mid-download)**

```bash
rm -rf ~/Library/Application\ Support/SpeakClean/models/
# Start download, then Ctrl+C after a few seconds
swift run speak-clean --audio output/recording-2026-04-08T05-14-39Z.wav
# Verify .download file exists
ls ~/Library/Application\ Support/SpeakClean/models/
# Resume
swift run speak-clean --audio output/recording-2026-04-08T05-14-39Z.wav
```

Expected: First run leaves `.download` file. Second run resumes and completes.

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "Fix issues found during integration testing"
```

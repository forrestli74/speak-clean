import CryptoKit
import Foundation
import Testing
@testable import SpeakCleanCore

// MARK: - URLProtocol stub for testing

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseData: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Tests
// Outer suite serializes all tests that share StubURLProtocol global state.

@Suite("NetworkTests", .serialized)
struct NetworkTests {

    @Suite("DownloadManager")
    struct DownloadManagerTests {
        @Test func cacheHitReturnsImmediately() async throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let destination = tmp.appendingPathComponent("model.bin")
            let sentinel = Data("cached".utf8)
            try sentinel.write(to: destination)

            // Use default session — fetch should never hit the network because file exists
            let manager = DownloadManager()
            try await manager.fetch(
                from: URL(string: "https://should-not-be-called.invalid/model.bin")!,
                to: destination,
                expectedSHA256: nil
            )

            // File should be unchanged (proves no download happened)
            let contents = try Data(contentsOf: destination)
            #expect(contents == sentinel)
        }

        @Test func rejectsChecksumMismatch() async throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let payload = Data("hello checksum".utf8)
            StubURLProtocol.responseData = payload
            StubURLProtocol.statusCode = 200

            let destination = tmp.appendingPathComponent("file.bin")
            let wrongSHA = "0000000000000000000000000000000000000000000000000000000000000000"
            let manager = DownloadManager(session: makeStubSession())

            await #expect(throws: DownloadError.self) {
                try await manager.fetch(
                    from: URL(string: "https://stub.test/file.bin")!,
                    to: destination,
                    expectedSHA256: wrongSHA
                )
            }

            // No final file and no .download temp file should remain
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("download").path))
        }

        @Test func acceptsCorrectChecksum() async throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let payload = Data("good data".utf8)
            let expectedSHA = SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }.joined()

            StubURLProtocol.responseData = payload
            StubURLProtocol.statusCode = 200

            let destination = tmp.appendingPathComponent("file.bin")
            let manager = DownloadManager(session: makeStubSession())

            try await manager.fetch(
                from: URL(string: "https://stub.test/file.bin")!,
                to: destination,
                expectedSHA256: expectedSHA
            )

            let contents = try Data(contentsOf: destination)
            #expect(contents == payload)
        }

        @Test func downloadsWithoutChecksumWhenNil() async throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let payload = Data("no checksum needed".utf8)
            StubURLProtocol.responseData = payload
            StubURLProtocol.statusCode = 200

            let destination = tmp.appendingPathComponent("file.bin")
            let manager = DownloadManager(session: makeStubSession())

            try await manager.fetch(
                from: URL(string: "https://stub.test/file.bin")!,
                to: destination,
                expectedSHA256: nil
            )

            #expect(FileManager.default.fileExists(atPath: destination.path))
            let contents = try Data(contentsOf: destination)
            #expect(contents == payload)
        }

        @Test func downloadFailsOnHttpError() async throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            StubURLProtocol.responseData = Data()
            StubURLProtocol.statusCode = 500

            let destination = tmp.appendingPathComponent("file.bin")
            let manager = DownloadManager(session: makeStubSession())

            await #expect(throws: DownloadError.self) {
                try await manager.fetch(
                    from: URL(string: "https://stub.test/file.bin")!,
                    to: destination,
                    expectedSHA256: nil
                )
            }
        }
    }

    @Suite("ModelManager")
    struct ModelManagerTests {
        @Test func fetchesSHA256FromHuggingFaceAPI() async throws {
            let hfResponse = """
            [{"type":"file","path":"ggml-base.en.bin","lfs":{"sha256":"abcd1234"}}]
            """
            StubURLProtocol.responseData = Data(hfResponse.utf8)
            StubURLProtocol.statusCode = 200

            let session = makeStubSession()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let manager = ModelManager(modelsDir: tmp, session: session)
            let sha = await manager.fetchSHA256(for: "ggml-base.en.bin")
            #expect(sha == "abcd1234")
        }

        @Test func fetchSHA256ReturnsNilOnAPIFailure() async throws {
            StubURLProtocol.statusCode = 500
            StubURLProtocol.responseData = Data()

            let session = makeStubSession()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let manager = ModelManager(modelsDir: tmp, session: session)
            let sha = await manager.fetchSHA256(for: "ggml-base.en.bin")
            #expect(sha == nil)
        }
    }
}

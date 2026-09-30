import Foundation
import Testing
@testable import NeuralLoopCore

/// Answers requests from a script and records them, so the Drive client's REST calls can be checked without a network.
final class DriveStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen: [(method: String, url: String, body: Data?)] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            body = data
        }
        Self.lock.lock()
        Self.seen.append((request.httpMethod ?? "GET", request.url!.absoluteString, body))
        let (status, headers, data) = Self.handler!(request, body)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func stubbedDrive() -> GoogleDrive {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DriveStub.self]
    return GoogleDrive(session: URLSession(configuration: configuration)) { "token-1" }
}

@Suite(.serialized) struct GoogleDriveTests {
    @Test func listingFollowsPagesInTheAppFolder() async throws {
        DriveStub.seen = []
        DriveStub.handler = { request, _ in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
            let page2 = request.url!.query!.contains("pageToken=p2")
            let json = page2 ? #"{"files":[{"id":"b","name":"books/x/book.json","md5Checksum":"m2","size":"7"}]}"#
                : #"{"nextPageToken":"p2","files":[{"id":"a","name":"inbox/u.pdf","md5Checksum":"m1","size":"3"}]}"#
            return (200, [:], Data(json.utf8))
        }
        let files = try await stubbedDrive().list()
        #expect(files == [SyncFile(path: "inbox/u.pdf", md5: "m1", size: 3, id: "a"), SyncFile(path: "books/x/book.json", md5: "m2", size: 7, id: "b")])
        #expect(DriveStub.seen.count == 2 && DriveStub.seen[0].url.contains("spaces=appDataFolder"))
    }

    @Test func uploadsStartAResumableSessionThenSendTheBytes() async throws {
        DriveStub.seen = []
        DriveStub.handler = { request, _ in
            if request.httpMethod == "POST" || request.httpMethod == "PATCH" {
                return (200, ["Location": "https://www.googleapis.com/upload/session/42"], Data())
            }
            return (200, [:], Data(#"{"id":"n1","name":"books/x/media/01-podcast.m4a","md5Checksum":"abc","size":"5"}"#.utf8))
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try Data("audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stored = try await stubbedDrive().upload(source, as: "books/x/media/01-podcast.m4a", replacing: nil)
        #expect(stored == SyncFile(path: "books/x/media/01-podcast.m4a", md5: "abc", size: 5, id: "n1"))
        #expect(DriveStub.seen.map(\.method) == ["POST", "PUT"])
        let metadata = try JSONSerialization.jsonObject(with: DriveStub.seen[0].body ?? Data()) as? [String: Any]
        #expect(metadata?["name"] as? String == "books/x/media/01-podcast.m4a" && metadata?["parents"] as? [String] == ["appDataFolder"])
        #expect(DriveStub.seen[1].url == "https://www.googleapis.com/upload/session/42" && DriveStub.seen[1].body == Data("audio".utf8))

        DriveStub.seen = []
        _ = try await stubbedDrive().upload(source, as: "books/x/media/01-podcast.m4a", replacing: "n1")
        #expect(DriveStub.seen.map(\.method) == ["PATCH", "PUT"] && DriveStub.seen[0].url.contains("/files/n1?"))
    }

    @Test func downloadsAndDeletesUseTheFileID() async throws {
        DriveStub.seen = []
        DriveStub.handler = { request, _ in (request.httpMethod == "DELETE" ? 204 : 200, [:], Data("bytes".utf8)) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)/book.json")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let drive = stubbedDrive()
        try await drive.download(SyncFile(path: "books/x/book.json", md5: "", size: 5, id: "f9"), to: destination)
        #expect(try Data(contentsOf: destination) == Data("bytes".utf8))
        try await drive.delete(SyncFile(path: "inbox/u.pdf", md5: "", size: 0, id: "f3"))
        #expect(DriveStub.seen.map { "\($0.method) \($0.url)" } == [
            "GET https://www.googleapis.com/drive/v3/files/f9?alt=media", "DELETE https://www.googleapis.com/drive/v3/files/f3"])
    }

    @Test func theTokenOnlyGoesToGoogle() async throws {
        DriveStub.seen = []
        DriveStub.handler = { _, _ in (200, ["Location": "https://evil.example/upload/session/42"], Data()) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try Data("audio".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: DriveError.badResponse) { try await stubbedDrive().upload(source, as: "books/x/book.json", replacing: nil) }
        #expect(DriveStub.seen.map(\.method) == ["POST"])  // no PUT to the other host
        // File ids never reshape the request URL.
        DriveStub.seen = []
        await #expect(throws: DriveError.badResponse) { try await stubbedDrive().delete(SyncFile(path: "x", md5: "", size: 0, id: "../about")) }
        await #expect(throws: DriveError.badResponse) {
            try await stubbedDrive().download(SyncFile(path: "x", md5: "", size: 0, id: "a?b"), to: source)
        }
        #expect(DriveStub.seen.isEmpty)
    }

    @Test func aDownloadReplacesTheOldFileWhole() async throws {
        DriveStub.handler = { _, _ in (200, [:], Data("new".utf8)) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("book.json")
        try Data("old".utf8).write(to: destination)
        try await stubbedDrive().download(SyncFile(path: "books/x/book.json", md5: "", size: 3, id: "f1"), to: destination)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["book.json"])  // no staging files left
    }

    @Test func driveErrorsBecomePlainWords() async throws {
        DriveStub.handler = { _, _ in (403, [:], Data(#"{"error":{"message":"Rate limit exceeded"}}"#.utf8)) }
        await #expect(throws: DriveError.http(403, "Rate limit exceeded")) { try await stubbedDrive().list() }
        #expect(DriveError.http(401, "").errorDescription?.contains("Sign in again") == true)
    }

    @Test func anExpiredTokenIsRefreshedOnceAndTheRequestTriedAgain() async throws {
        DriveStub.seen = []
        DriveStub.handler = { request, _ in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                ? (200, [:], Data(#"{"files":[{"id":"a","name":"inbox/u.pdf","md5Checksum":"m1","size":"3","modifiedTime":"2026-09-30T10:00:00.250Z"}]}"#.utf8))
                : (401, [:], Data(#"{"error":{"message":"Invalid Credentials"}}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DriveStub.self]
        let forced = Counter()
        let drive = GoogleDrive(session: URLSession(configuration: configuration)) { force in
            if force { await forced.bump() }
            return force ? "fresh" : "stale"
        }
        let files = try await drive.list()
        let refreshes = await forced.value
        #expect(files.map(\.path) == ["inbox/u.pdf"] && DriveStub.seen.count == 2 && refreshes == 1)
        #expect(files[0].modified == Date(timeIntervalSince1970: 1_790_762_400.25))
        // Still refused after a fresh token: say so, don't loop.
        DriveStub.seen = []
        DriveStub.handler = { _, _ in (401, [:], Data()) }
        await #expect(throws: DriveError.http(401, "")) { try await drive.list() }
        #expect(DriveStub.seen.count == 2)
    }
}

actor Counter {
    var value = 0
    func bump() { value += 1 }
}

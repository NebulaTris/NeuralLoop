// The person's Google Drive app folder (drive.appdata scope: private to NeuralLoop, invisible in Drive's UI), and an
// in-memory stand-in with the same behaviour for tests. Files are flat, named by their library path (see SyncPlan).

import Foundation

public protocol DriveStore: Sendable {
    func list() async throws -> [SyncFile]
    func download(_ file: SyncFile, to destination: URL) async throws
    /// Creates the file, or replaces it when `replacing` is Drive's id for it. Returns the stored file.
    @discardableResult func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile
    func delete(_ file: SyncFile) async throws
}

public enum DriveError: LocalizedError, Equatable {
    case notSignedIn
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in with Google to sync your library."
        case .http(401, _), .http(403, _): "Google Drive didn't accept the sign-in. Sign in again in Settings → Account."
        case .http(let code, let message): "Google Drive answered \(code)\(message.isEmpty ? "" : ": \(message)"). Pip will try again soon."
        case .badResponse: "Google Drive sent something Pip didn't understand. Pip will try again soon."
        }
    }
}

/// Google Drive's REST API (v3), with a bearer token from `token()` (refreshed by the caller when it expires).
public struct GoogleDrive: DriveStore {
    let token: @Sendable () async throws -> String
    let session: URLSession
    let api: String
    let uploadAPI: String

    /// `base` is Google's API host; development builds can point it at a local stand-in (scripts/fake_drive.py).
    public init(session: URLSession = .shared, base: String = "https://www.googleapis.com",
                token: @escaping @Sendable () async throws -> String) {
        (self.session, self.token) = (session, token)
        api = "\(base)/drive/v3/files"
        uploadAPI = "\(base)/upload/drive/v3/files"
    }

    public func list() async throws -> [SyncFile] {
        var files: [SyncFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: api)!
            components.queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,md5Checksum,size)"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let (data, _) = try await send(URLRequest(url: components.url!))
            let page = try JSONDecoder().decode(FilePage.self, from: data)
            files += page.files.map(\.syncFile)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    public func download(_ file: SyncFile, to destination: URL) async throws {
        guard let id = file.id else { throw DriveError.badResponse }
        var request = URLRequest(url: URL(string: "\(api)/\(id)?alt=media")!)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (temporary, response) = try await session.download(for: request)
        try check(response, data: nil)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        // Resumable upload: one request for the session, one PUT with the bytes (works for podcasts and videos).
        var start = URLRequest(url: URL(string: id.map { "\(uploadAPI)/\($0)?uploadType=resumable&fields=id,name,md5Checksum,size" }
                                        ?? "\(uploadAPI)?uploadType=resumable&fields=id,name,md5Checksum,size")!)
        start.httpMethod = id == nil ? "POST" : "PATCH"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let metadata: [String: Any] = id == nil ? ["name": path, "parents": ["appDataFolder"]] : [:]
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (_, response) = try await send(start)
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), let url = URL(string: location) else {
            throw DriveError.badResponse
        }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, done) = try await session.upload(for: put, fromFile: source)
        try check(done, data: data)
        return try JSONDecoder().decode(DriveFile.self, from: data).syncFile
    }

    public func delete(_ file: SyncFile) async throws {
        guard let id = file.id else { return }
        var request = URLRequest(url: URL(string: "\(api)/\(id)")!)
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try check(response, data: data)
        return (data, response)
    }

    private func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw DriveError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw DriveError.http(http.statusCode, message)
        }
    }

    struct DriveFile: Decodable {
        let id: String
        let name: String
        let md5Checksum: String?
        let size: String?
        var syncFile: SyncFile { SyncFile(path: name, md5: md5Checksum ?? "", size: Int64(size ?? "0") ?? 0, id: id) }
    }

    struct FilePage: Decodable {
        let files: [DriveFile]
        let nextPageToken: String?
    }
}

/// An in-memory Drive app folder with the same behaviour (ids, MD5s, replace in place), for tests and previews.
public actor MemoryDrive: DriveStore {
    public private(set) var files: [String: (file: SyncFile, data: Data)] = [:]  // by id
    private var nextId = 1
    public private(set) var uploads = 0

    public init() {}

    public func list() async throws -> [SyncFile] { files.values.map(\.file).sorted { $0.path < $1.path } }

    public func download(_ file: SyncFile, to destination: URL) async throws {
        guard let id = file.id, let stored = files[id] else { throw DriveError.http(404, "File not found") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stored.data.write(to: destination, options: .atomic)
    }

    public func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        let data = try Data(contentsOf: source)
        let fileId: String
        if let id, files[id] != nil { fileId = id } else { fileId = "f\(nextId)"; nextId += 1 }
        let file = SyncFile(path: path, md5: FileHash.md5(data), size: Int64(data.count), id: fileId)
        files[fileId] = (file, data)
        uploads += 1
        return file
    }

    public func delete(_ file: SyncFile) async throws { if let id = file.id { files[id] = nil } }

    /// Test helper: what's stored at a path.
    public func data(at path: String) -> Data? { files.values.first { $0.file.path == path }?.data }
}

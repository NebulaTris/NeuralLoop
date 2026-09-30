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
    case tooBig

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in with Google to sync your library."
        case .http(401, _), .http(403, _): "Google Drive didn't accept the sign-in. Sign in again in Settings → Account."
        case .http(let code, let message): "Google Drive answered \(code)\(message.isEmpty ? "" : ": \(message)"). Pip will try again soon."
        case .badResponse: "Google Drive sent something Pip didn't understand. Pip will try again soon."
        case .tooBig: "This file is bigger than 2 GB, so Pip left it in Google Drive."
        }
    }
}

/// Google Drive's REST API (v3), with a bearer token from `token(forceRefresh)`: the caller refreshes it when it
/// expires, and when asked to (Google refused it with a 401, say after the clock jumped or the token was revoked).
public struct GoogleDrive: DriveStore {
    let token: @Sendable (_ forceRefresh: Bool) async throws -> String
    let session: URLSession
    let api: String
    let uploadAPI: String
    static let fields = "id,name,md5Checksum,size,modifiedTime"

    /// `base` is Google's API host; development builds can point it at a local stand-in (scripts/fake_drive.py).
    public init(session: URLSession = .shared, base: String = "https://www.googleapis.com",
                token: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        (self.session, self.token) = (session, token)
        api = "\(base)/drive/v3/files"
        uploadAPI = "\(base)/upload/drive/v3/files"
    }

    /// A token that never needs refreshing (tests, the development stand-in).
    public init(session: URLSession = .shared, base: String = "https://www.googleapis.com",
                token: @escaping @Sendable () async throws -> String) {
        self.init(session: session, base: base) { _ in try await token() }
    }

    public func list() async throws -> [SyncFile] {
        var files: [SyncFile] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: api)!
            components.queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fields))"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let (data, _) = try await send(URLRequest(url: components.url!))
            let page = try JSONDecoder().decode(FilePage.self, from: data)
            files += page.files.map(\.syncFile)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return files
    }

    public func download(_ file: SyncFile, to destination: URL) async throws {
        guard let id = file.id, Self.isFileID(id) else { throw DriveError.badResponse }
        var request = URLRequest(url: URL(string: "\(api)/\(id)?alt=media")!)
        request.setValue("Bearer \(try await token(false))", forHTTPHeaderField: "Authorization")
        var (temporary, response) = try await session.download(for: request)
        let fm = FileManager.default
        if (response as? HTTPURLResponse)?.statusCode == 401 {  // refused: one fresh token, one more try
            try? fm.removeItem(at: temporary)
            request.setValue("Bearer \(try await token(true))", forHTTPHeaderField: "Authorization")
            (temporary, response) = try await session.download(for: request)
        }
        defer { try? fm.removeItem(at: temporary) }
        try check(response, data: nil)
        let size = ((try? fm.attributesOfItem(atPath: temporary.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= SyncLayout.maxDownloadBytes else { throw DriveError.tooBig }
        // Next to the destination first (same volume), then swapped in whole: a reader never sees half a file.
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download.tmp")
        try fm.moveItem(at: temporary, to: staged)
        do {
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staged) }
            else { try fm.moveItem(at: staged, to: destination) }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    public func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        // Resumable upload: one request for the session, one PUT with the bytes (works for podcasts and videos).
        if let id, !Self.isFileID(id) { throw DriveError.badResponse }
        var start = URLRequest(url: URL(string: id.map { "\(uploadAPI)/\($0)?uploadType=resumable&fields=\(Self.fields)" }
                                        ?? "\(uploadAPI)?uploadType=resumable&fields=\(Self.fields)")!)
        start.httpMethod = id == nil ? "POST" : "PATCH"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let metadata: [String: Any] = id == nil ? ["name": path, "parents": ["appDataFolder"]] : [:]
        start.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        let (_, response) = try await send(start)
        // The upload session must be on the same host: the bearer token only ever goes to Google (or the dev stand-in).
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), let url = URL(string: location),
              let expected = URL(string: uploadAPI), url.scheme == expected.scheme, url.host == expected.host, url.port == expected.port
        else { throw DriveError.badResponse }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(try await token(false))", forHTTPHeaderField: "Authorization")
        let (data, done) = try await session.upload(for: put, fromFile: source)
        try check(done, data: data)
        return try JSONDecoder().decode(DriveFile.self, from: data).syncFile
    }

    public func delete(_ file: SyncFile) async throws {
        guard let id = file.id else { return }
        guard Self.isFileID(id) else { throw DriveError.badResponse }
        var request = URLRequest(url: URL(string: "\(api)/\(id)")!)
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// Drive's file ids are letters, digits, "-" and "_"; anything else never goes into a request URL.
    static func isFileID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 200 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Sends with the current token; if Google refuses it (401), gets a fresh one and tries once more.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.setValue("Bearer \(try await token(false))", forHTTPHeaderField: "Authorization")
        var (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            request.setValue("Bearer \(try await token(true))", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
        }
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
        let modifiedTime: String?
        var syncFile: SyncFile {
            SyncFile(path: name, md5: md5Checksum ?? "", size: Int64(size ?? "0") ?? 0, id: id, modified: modifiedTime.flatMap(Self.date))
        }

        /// Drive's RFC 3339 times ("2026-09-30T10:00:00.250Z"), with or without fractional seconds.
        static func date(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
    }

    struct FilePage: Decodable {
        let files: [DriveFile]
        let nextPageToken: String?
    }
}

/// An in-memory Drive app folder with Google's behaviour (ids, MD5s, modified times, replace in place, 404 for ids that
/// are gone, several files allowed under one name, no promised order), for tests and previews.
public actor MemoryDrive: DriveStore {
    public private(set) var files: [String: (file: SyncFile, data: Data)] = [:]  // by id
    private var nextId = 1
    private var clock = 1_000_000.0
    private let shuffled: Bool
    public private(set) var uploads = 0

    /// `shuffled`: list in a different order every time, as Google may.
    public init(shuffled: Bool = true) { self.shuffled = shuffled }

    public func list() async throws -> [SyncFile] {
        let all = files.values.map(\.file)
        return shuffled ? all.shuffled() : all.sorted { $0.path < $1.path }
    }

    public func download(_ file: SyncFile, to destination: URL) async throws {
        guard let id = file.id, let stored = files[id] else { throw DriveError.http(404, "File not found") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stored.data.write(to: destination, options: .atomic)
    }

    public func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        let data = try Data(contentsOf: source)
        if let id, files[id] == nil { throw DriveError.http(404, "File not found") }
        uploads += 1
        return store(data, as: path, id: id)
    }

    public func delete(_ file: SyncFile) async throws {
        guard let id = file.id else { return }
        guard files[id] != nil else { throw DriveError.http(404, "File not found") }
        files[id] = nil
    }

    /// Test helper: a new file under this name, even if one exists (how duplicates appear in the Drive).
    @discardableResult public func insert(_ data: Data, as path: String) -> SyncFile { store(data, as: path, id: nil) }

    /// Test helper: what's stored at a path (the newest, if there are several).
    public func data(at path: String) -> Data? {
        files.values.filter { $0.file.path == path }.max { ($0.file.modified ?? .distantPast) < ($1.file.modified ?? .distantPast) }?.data
    }

    private func store(_ data: Data, as path: String, id: String?) -> SyncFile {
        let fileId = id ?? "f\(nextId)"
        if id == nil { nextId += 1 }
        clock += 1
        let file = SyncFile(path: path, md5: FileHash.md5(data), size: Int64(data.count), id: fileId,
                            modified: Date(timeIntervalSince1970: clock))
        files[fileId] = (file, data)
        return file
    }
}

// One sync between this device's library folder and the Drive app folder: look at both sides, make a SyncPlan, carry
// it out. On disk (<app data>/):
//   books/<id>/…                    the book folder (the Mac's pipeline output; a pad's downloaded copy)
//   books/<id>/progress.json        this device's own progress (only its own study time goes in here)
//   books/<id>/devices/<dev>.json   other devices' progress, downloaded (merged when read)
//   inbox/<uuid>.{pdf,epub,json}    books added on a pad, on their way to the Mac (and received there)
//   sync-state.json                 file hashes (so big media isn't re-hashed), inbox bookkeeping

import CryptoKit
import Foundation

public enum FileHash {
    public static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct SyncReport: Equatable, Sendable {
    public var uploaded = 0
    public var downloaded = 0
    public var deleted = 0
    public var bytes: Int64 = 0
    /// Mac: inbox books that just arrived, ready to prepare (the book file; its sidecar JSON sits next to it).
    public var arrived: [URL] = []
    public var problems: [String] = []
    public init() {}
}

struct SyncState: Codable {
    struct Hash: Codable { var size: Int64; var modified: Double; var md5: String }
    var hashes: [String: Hash] = [:]
    var taken: Set<String> = []   // Mac: inbox paths already turned into books
    var sent: Set<String> = []    // pad: inbox paths uploaded
}

public actor SyncEngine {
    let root: URL
    let device: String
    let role: SyncRole
    let store: DriveStore
    private var state: SyncState

    var books: URL { root.appendingPathComponent("books", isDirectory: true) }
    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("sync-state.json") }

    public init(root: URL, device: String, role: SyncRole, store: DriveStore) {
        (self.root, self.device, self.role, self.store) = (root, device, role, store)
        let saved = try? Data(contentsOf: root.appendingPathComponent("sync-state.json"))
        state = saved.flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState()
    }

    /// The Mac has made a book from an inbox upload: remember it, so the upload (and its sidecar) leave the Drive.
    public func markTaken(_ bookFile: URL) {
        let name = bookFile.deletingPathExtension().lastPathComponent
        for ext in [bookFile.pathExtension, "json"] {
            state.taken.insert("inbox/\(name).\(ext)")
            try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(name).\(ext)"))
        }
        save()
    }

    public func sync(wantedMedia: Set<String> = []) async throws -> SyncReport {
        let remote = try await store.list()
        let local = scan()
        // A pad never re-sends an inbox book it already sent (once it's gone from the Drive, the Mac has it).
        let settled = role == .mac ? state.taken : state.sent
        let plan = SyncPlan.make(local: local, remote: remote, device: device, role: role, wantedMedia: wantedMedia, takenInbox: settled)
        var report = SyncReport()
        for file in plan.uploads {
            do {
                guard let source = localURL(file.path) else { continue }
                try await store.upload(source, as: file.path, replacing: file.id)
                report.uploaded += 1
                report.bytes += file.size
                if SyncLayout.isInbox(file.path) { state.sent.insert(file.path) }
            } catch { report.problems.append("\(file.path): \(error.localizedDescription)") }
        }
        for file in plan.downloads {
            do {
                guard let destination = localURL(file.path) else { continue }  // never outside the library folder
                try await store.download(file, to: destination)
                report.downloaded += 1
                report.bytes += file.size
                remember(file.path, destination, md5: file.md5)
                if role == .mac, SyncLayout.isInbox(file.path), destination.pathExtension != "json" { report.arrived.append(destination) }
            } catch { report.problems.append("\(file.path): \(error.localizedDescription)") }
        }
        for file in plan.deletes {
            do {
                try await store.delete(file)
                report.deleted += 1
                state.taken.remove(file.path)
            } catch { report.problems.append("\(file.path): \(error.localizedDescription)") }
        }
        if role == .pad {
            // Books the Mac has picked up: their uploads are gone from the Drive, so the local copies can go too.
            let there = Set(remote.map(\.path))
            for path in state.sent where !there.contains(path) && !plan.uploads.contains(where: { $0.path == path }) {
                if let url = localURL(path) { try? FileManager.default.removeItem(at: url) }
                state.sent.remove(path)
            }
        }
        save()
        return report
    }

    // MARK: local side

    /// This device's files in Drive layout.
    func scan() -> [SyncFile] {
        var files: [SyncFile] = []
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: books, includingPropertiesForKeys: nil)) ?? [] where folder.hasDirectoryPath {
            let id = folder.lastPathComponent
            guard BookID.isValid(id) else { continue }
            let own = folder.appendingPathComponent("progress.json")
            if let file = hashed(own, as: SyncLayout.progressPath(book: id, device: device)) { files.append(file) }
            let devices = folder.appendingPathComponent("devices", isDirectory: true)
            for other in (try? fm.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? [] where other.pathExtension == "json" {
                let name = other.deletingPathExtension().lastPathComponent
                if let file = hashed(other, as: SyncLayout.progressPath(book: id, device: name)) { files.append(file) }
            }
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            let prefix = folder.standardizedFileURL.path + "/"
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                guard !SyncLayout.isPrivate(relative) else { continue }
                if let file = hashed(url, as: "books/\(id)/\(relative)") { files.append(file) }
            }
        }
        for url in (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [] where !url.hasDirectoryPath {
            if let file = hashed(url, as: "inbox/\(url.lastPathComponent)") { files.append(file) }
        }
        return files
    }

    /// Where a Drive path lives on this device: inside a book's folder or the inbox, or nowhere (nil) for anything else.
    func localURL(_ path: String) -> URL? {
        if let id = SyncLayout.book(path), let owner = SyncLayout.progressDevice(path) {
            let folder = books.appendingPathComponent(id, isDirectory: true)
            return owner == device ? folder.appendingPathComponent("progress.json")
                : folder.appendingPathComponent("devices", isDirectory: true).appendingPathComponent("\(owner).json")
        }
        let container: URL
        if let id = SyncLayout.book(path) { container = books.appendingPathComponent(id, isDirectory: true) }
        else if SyncLayout.isInbox(path) { container = inbox }
        else { return nil }
        let url = root.appendingPathComponent(path).standardizedFileURL
        return url.path.hasPrefix(container.standardizedFileURL.path + "/") ? url : nil
    }

    private func hashed(_ url: URL, as path: String) -> SyncFile? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return nil }
        let modified = ((attributes[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
        if let cached = state.hashes[url.path], cached.size == size, cached.modified == modified {
            return SyncFile(path: path, md5: cached.md5, size: size)
        }
        guard let md5 = try? FileHash.md5(of: url) else { return nil }
        state.hashes[url.path] = SyncState.Hash(size: size, modified: modified, md5: md5)
        return SyncFile(path: path, md5: md5, size: size)
    }

    private func remember(_ path: String, _ url: URL, md5: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return }
        let modified = ((attributes[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
        state.hashes[url.path] = SyncState.Hash(size: size, modified: modified, md5: md5)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }
}

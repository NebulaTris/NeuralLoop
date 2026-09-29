// What to upload, download, and delete so this device and the library in the person's Google Drive app folder agree
// (spec 07). Files are stored flat in the app folder, named by their path:
//   books/<id>/book.json, books/<id>/chapters/…, books/<id>/media/…, books/<id>/knowledge-graph.json
//   books/<id>/progress/<deviceId>.json   each device's own progress: only that device ever writes it
//   inbox/<uuid>.{pdf,epub} + inbox/<uuid>.json   books added on a device that can't prepare them
// The Mac prepares books, so it owns book files; other devices only read them. Media downloads when a chapter is opened.

import Foundation

public enum SyncRole: String, Sendable { case mac, pad }

/// A file in the library, as this device or Drive sees it. `path` uses the Drive layout above.
public struct SyncFile: Equatable, Sendable {
    public let path: String
    public let md5: String
    public let size: Int64
    public var id: String?  // Drive's file id (remote files only)
    public init(path: String, md5: String, size: Int64, id: String? = nil) { (self.path, self.md5, self.size, self.id) = (path, md5, size, id) }
}

public struct SyncPlan: Equatable, Sendable {
    public var uploads: [SyncFile] = []      // local files to send (with the remote id when replacing)
    public var downloads: [SyncFile] = []    // remote files to fetch
    public var deletes: [SyncFile] = []      // remote files to remove (inbox books the Mac has taken)
    public var isEmpty: Bool { uploads.isEmpty && downloads.isEmpty && deletes.isEmpty }
}

public enum SyncLayout {
    /// "books/<id>/…" → the book id.
    public static func book(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts[0] == "books" && BookID.isValid(String(parts[1])) ? String(parts[1]) : nil
    }

    /// "books/<id>/progress/<device>.json" → the device (device ids are letters, digits, and dashes, like book ids).
    public static func progressDevice(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "books", parts[2] == "progress", parts[3].hasSuffix(".json") else { return nil }
        let device = String(parts[3].dropLast(5))
        return BookID.isValid(device) ? device : nil
    }

    public static func progressPath(book: String, device: String) -> String { "books/\(book)/progress/\(device).json" }

    /// "inbox/<name>.{pdf,epub,json}": one file, its name made only of letters, digits, and dashes (a pad uses a UUID).
    public static func isInbox(_ path: String) -> Bool {
        guard path.hasPrefix("inbox/") else { return false }
        let name = path.dropFirst(6)
        guard let dot = name.lastIndex(of: "."), ["pdf", "epub", "json"].contains(name[name.index(after: dot)...]) else { return false }
        return BookID.isValid(String(name[..<dot]))
    }

    /// The biggest file sync will download (a long video is well under this); bigger ones are left in the Drive.
    public static let maxDownloadBytes: Int64 = 2 << 30

    /// Whether a path from the Drive is one this app could have written, so it's safe to place on disk. The Drive app
    /// folder is only as trustworthy as the account and every device signed in to it: names that climb out of a
    /// folder ("..", "."), empty segments, backslashes or NULs, and the device's private files are never downloaded.
    public static func isSafeRemote(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") || $0.contains("\0") }) else { return false }
        if isInbox(path) { return true }
        if progressDevice(path) != nil { return book(path) != nil }
        guard book(path) != nil else { return false }
        return !isPrivate(parts.dropFirst(2).joined(separator: "/"))
    }

    /// Media and original PDF pages: big, fetched when a chapter is opened. "media/03-podcast.m4a" → chapter 3.
    public static func mediaChapter(_ path: String) -> Int? {
        guard book(path) != nil else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 4 else { return nil }
        let isMedia = parts[2] == "media" || (parts[2] == "chapters" && parts.count == 4 && parts[3].hasSuffix(".pdf"))
        guard isMedia, let digits = parts[3].prefix(while: \.isNumber).nonEmpty, let n = Int(digits) else { return nil }
        return n
    }

    /// Files that never leave the device they're on (logs, locks, run state, the pipeline's working files).
    public static func isPrivate(_ relative: String) -> Bool {
        let name = relative.split(separator: "/").last.map(String.init) ?? relative
        let top = relative.split(separator: "/").first.map(String.init) ?? ""
        return ["raw", "devices"].contains(top) || name.hasPrefix(".") || name.hasSuffix(".tmp") || name.hasSuffix(".wav")
            || ["pipeline.log", "state.json", "meta.json", "progress.json", "book-data.js"].contains(relative)
            || ["index.html", "styles.css", "app.js", "pip-poses.js"].contains(relative)  // the old study site, in older books
            || relative.hasPrefix("source.") || relative.hasPrefix("progress.json.unreadable")
            || relative.contains("podcast-lines/")
    }
}

extension Substring {
    var nonEmpty: Substring? { isEmpty ? nil : self }
}

extension SyncPlan {
    /// - local: this device's files in Drive layout (its own progress already at books/<id>/progress/<device>.json).
    /// - wantedMedia: "bookId:chapter" keys whose media this device wants (a pad fetches media on demand).
    /// - takenInbox: inbox paths this Mac has already turned into books (to delete remotely).
    public static func make(local: [SyncFile], remote: [SyncFile], device: String, role: SyncRole,
                            wantedMedia: Set<String> = [], takenInbox: Set<String> = []) -> SyncPlan {
        var plan = SyncPlan()
        let localByPath = Dictionary(local.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByPath = Dictionary(remote.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        for file in local {
            let theirs = remoteByPath[file.path]
            if let owner = SyncLayout.progressDevice(file.path) {
                // Only ever our own progress goes up.
                if owner == device, theirs?.md5 != file.md5 { plan.uploads.append(SyncFile(path: file.path, md5: file.md5, size: file.size, id: theirs?.id)) }
            } else if SyncLayout.isInbox(file.path) {
                if role == .pad, theirs == nil, !takenInbox.contains(file.path) { plan.uploads.append(file) }
            } else if SyncLayout.book(file.path) != nil, role == .mac, theirs?.md5 != file.md5 {
                plan.uploads.append(SyncFile(path: file.path, md5: file.md5, size: file.size, id: theirs?.id))
            }
        }

        for file in remote where SyncLayout.isSafeRemote(file.path) && file.size <= SyncLayout.maxDownloadBytes {
            let mine = localByPath[file.path]
            if let owner = SyncLayout.progressDevice(file.path) {
                if owner != device, mine?.md5 != file.md5 { plan.downloads.append(file) }
            } else if SyncLayout.isInbox(file.path) {
                if role == .mac {
                    if takenInbox.contains(file.path) { plan.deletes.append(file) } else if mine?.md5 != file.md5 { plan.downloads.append(file) }
                }
            } else if let id = SyncLayout.book(file.path), role == .pad, mine?.md5 != file.md5 {
                if let n = SyncLayout.mediaChapter(file.path), !wantedMedia.contains("\(id):\(n)") { continue }
                plan.downloads.append(file)
            }
        }
        return plan
    }
}

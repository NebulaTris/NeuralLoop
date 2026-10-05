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
    /// Mac: inbox books waiting to be prepared (the book file; its sidecar JSON sits next to it). Every sync offers
    /// each one not yet taken, with a back-off after it couldn't be prepared (`markFailed`).
    public var arrived: [URL] = []
    /// Books removed on any device whose folder is still here: this device should let go of them (stop preparing,
    /// remove the folder). Offered every sync until the folder is gone.
    public var removedElsewhere: [String] = []
    /// Another device writes this device's progress files (they share an id): nothing was uploaded; take a new id.
    public var deviceClash = false
    /// Every device signed in to this library, this one first, then by name.
    public var devices: [DeviceInfo] = []
    public var problems: [String] = []
    public init() {}
}

/// A device on the library, as its own note in the Drive says (`deviceinfo/<id>.json`).
public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: SyncRole
    public var lastSync: Double  // Unix ms
    public var isThisDevice = false

    public init(id: String, name: String, kind: SyncRole, lastSync: Double, isThisDevice: Bool = false) {
        (self.id, self.kind, self.lastSync, self.isThisDevice) = (id, kind, lastSync, isThisDevice)
        self.name = Self.clean(name, kind: kind)
    }

    enum CodingKeys: String, CodingKey { case name, kind, lastSync }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(lastSync, forKey: .lastSync)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)).flatMap(SyncRole.init(rawValue:)) ?? .mac
        self.init(id: "", name: (try? c.decode(String.self, forKey: .name)) ?? "", kind: kind,
                  lastSync: (try? c.decode(Double.self, forKey: .lastSync)) ?? 0)
    }

    /// A note not rewritten for this long (by the Drive's clock, never a device's) belongs to a device that's gone
    /// (signed out, wiped, sold): it isn't listed, and any device may delete it.
    public static let staleAfter = 90 * 86_400_000.0

    /// Another device's note: shown as plain text, so it's kept to one sensible line, and its time to one that could be
    /// true (never before 1970, never more than a day ahead of this device's clock).
    public static func read(_ data: Data, id: String, now: Date = Date()) -> DeviceInfo? {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              var info = try? JSONDecoder().decode(DeviceInfo.self, from: data) else { return nil }
        info.id = id
        info.lastSync = clamped(info.lastSync, now: now)
        return info
    }

    static func clamped(_ ms: Double, now: Date) -> Double {
        guard ms.isFinite else { return 0 }
        return min(max(ms, 0), now.timeIntervalSince1970 * 1000 + 86_400_000)
    }

    /// One entry per device (the first wins), so a list never shows a device twice.
    public static func unique(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.id).inserted }
    }

    /// Names are shown as plain text: whitespace of any kind becomes one space, and invisible characters (controls,
    /// format characters such as bidi overrides and marks, zero-width spaces and the byte-order mark, private-use and
    /// unassigned code points) go. Format characters that are part of how a name is written stay: the zero-width joiner
    /// and non-joiner (joined emoji like 👩‍💻, Persian words) and tag characters (flags like England's).
    static func clean(_ name: String, kind: SyncRole) -> String {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .privateUse, .surrogate, .unassigned]
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
            } else if keptFormat(scalar) || !hidden.contains(scalar.properties.generalCategory) {
                scalars.append(scalar)
            }
        }
        let one = String(String(scalars).split(separator: " ").joined(separator: " ").prefix(60))
        return one.isEmpty ? (kind == .mac ? "A Mac" : "An iPad") : one
    }

    /// Never shown, named here so no rule above lets them through: bidi embeddings, overrides, isolates and marks
    /// (which can flip how a name reads), zero-width space, word joiner, byte-order mark.
    static let invisible: Set<UInt32> = Set(Array(0x202A...0x202E) + Array(0x2066...0x2069) + [0x200E, 0x200F, 0x061C, 0x200B, 0x2060, 0xFEFF])

    /// Format characters a name may need: ZWNJ (U+200C), ZWJ (U+200D), and tag characters (U+E0020–U+E007F).
    private static func keptFormat(_ scalar: Unicode.Scalar) -> Bool {
        guard !invisible.contains(scalar.value) else { return false }
        return scalar.value == 0x200C || scalar.value == 0x200D || (0xE0020...0xE007F).contains(scalar.value)
    }
}

struct SyncState: Codable {
    struct Hash: Codable { var size: Int64; var modified: Double; var md5: String }
    struct Attempt: Codable { var count: Int; var last: Double }
    var hashes: [String: Hash] = [:]
    var taken: Set<String> = []   // Mac: inbox paths already turned into books
    var sent: Set<String> = []    // pad: inbox paths uploaded
    var removed: Set<String> = []          // books removed on any device (never synced again)
    var removeFromDrive: Set<String> = []  // removed here, still to be taken out of the Drive
    var uploaded: [String: String] = [:]   // our own progress paths → the md5 we last saw there (ours)
    var tries: [String: Attempt] = [:]     // Mac: inbox book paths that couldn't be prepared yet
    var dropInbox: Set<String> = []        // inbox paths to take out of the Drive ("Remove all books")
    var dropInboxBefore: Double?           // … and every inbox upload older than this (Unix ms)
    var noteAt: Double?                    // when this device last wrote its note (Unix ms)
    var noteName: String?                  // … the name in it
    var noteDevice: String?                // … and the id it went up under (another id: never written)
    var notes: [String: Note] = [:]        // other devices' notes, by device id (re-read when their md5 changes)
    struct Note: Codable { var md5: String; var info: DeviceInfo }

    init() {}
    init(from decoder: Decoder) throws {  // older state files lack the newer fields
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hashes = (try? c.decode([String: Hash].self, forKey: .hashes)) ?? [:]
        taken = (try? c.decode(Set<String>.self, forKey: .taken)) ?? []
        sent = (try? c.decode(Set<String>.self, forKey: .sent)) ?? []
        removed = (try? c.decode(Set<String>.self, forKey: .removed)) ?? []
        removeFromDrive = (try? c.decode(Set<String>.self, forKey: .removeFromDrive)) ?? []
        uploaded = (try? c.decode([String: String].self, forKey: .uploaded)) ?? [:]
        tries = (try? c.decode([String: Attempt].self, forKey: .tries)) ?? [:]
        dropInbox = (try? c.decode(Set<String>.self, forKey: .dropInbox)) ?? []
        dropInboxBefore = try? c.decode(Double.self, forKey: .dropInboxBefore)
        noteAt = try? c.decode(Double.self, forKey: .noteAt)
        noteName = try? c.decode(String.self, forKey: .noteName)
        noteDevice = try? c.decode(String.self, forKey: .noteDevice)
        notes = (try? c.decode([String: Note].self, forKey: .notes)) ?? [:]
    }

    static func load(_ root: URL) -> SyncState {
        let saved = try? Data(contentsOf: root.appendingPathComponent("sync-state.json"))
        return saved.flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState()
    }
}

public actor SyncEngine {
    let root: URL
    let device: String
    let role: SyncRole
    let store: DriveStore
    /// What this device calls itself in the device list ("Sam's MacBook Pro").
    let name: String
    private var state: SyncState
    /// Signed out (or signing out): this device's note is never written, even by a sync already underway, until the
    /// next sign-in (`signedIn()`). Kept in memory only, so a sign-out cut short never keeps the note off for good.
    private var noteRemoved = false
    /// How often a device rewrites its note while syncing (it says when it last synced).
    static let noteEvery = 15 * 60 * 1000.0

    var books: URL { root.appendingPathComponent("books", isDirectory: true) }
    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var stateFile: URL { root.appendingPathComponent("sync-state.json") }

    public init(root: URL, device: String, role: SyncRole, store: DriveStore, name: String = "") {
        (self.root, self.device, self.role, self.store, self.name) = (root, device, role, store, name)
        state = SyncState.load(root)
        state.uploaded = state.uploaded.filter { SyncLayout.progressDevice($0.key) == device }  // an id we gave up
    }

    /// Books removed on any device, as last saved here (readable before signing in, so removed ids are never reused).
    public static func removedBooks(savedIn root: URL) -> Set<String> { SyncState.load(root).removed }

    /// The Mac has made a book from an inbox upload: remember it, so the upload (and its sidecar) leave the Drive.
    public func markTaken(_ bookFile: URL) {
        let name = bookFile.deletingPathExtension().lastPathComponent
        for ext in [bookFile.pathExtension, "json"] {
            state.taken.insert("inbox/\(name).\(ext)")
            state.tries["inbox/\(name).\(ext)"] = nil
            try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(name).\(ext)"))
        }
        save()
    }

    /// The Mac couldn't prepare an inbox book this time: offer it again later (see `InboxRetry`).
    public func markFailed(_ bookFile: URL, now: Date = Date()) {
        let path = "inbox/\(bookFile.lastPathComponent)"
        state.tries[path] = SyncState.Attempt(count: (state.tries[path]?.count ?? 0) + 1, last: now.timeIntervalSince1970 * 1000)
        save()
    }

    /// Books removed on any device (so a new book never reuses one of their ids).
    public var removedBooks: Set<String> { state.removed }

    /// The person removed a book on this device: it leaves the Drive on the next sync, and every other device drops it.
    public func remove(book id: String) {
        guard BookID.isValid(id) else { return }
        state.removed.insert(id)
        state.removeFromDrive.insert(id)
        save()
    }

    /// "Remove all books": every book waiting in the inbox leaves the Drive too (whether sent from here or not yet
    /// taken by the Mac), on the next sync. The caller empties the local inbox folder.
    public func forgetInbox(now: Date = Date()) {
        let local = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .map { "inbox/\($0.lastPathComponent)" }
        state.dropInbox.formUnion(state.sent.union(local).filter(SyncLayout.isInbox))
        state.dropInboxBefore = now.timeIntervalSince1970 * 1000
        state.tries = [:]
        save()
    }

    public func sync(wantedMedia: Set<String> = [], now: Date = Date()) async throws -> SyncReport {
        var remote = try await store.list()
        var report = SyncReport()
        let local = scan()
        let localByPath = Dictionary(local.map { ($0.path, $0.md5) }, uniquingKeysWith: { a, _ in a })
        // Someone else writes our progress files (a copied device id): touch nothing, so we never overwrite theirs.
        if DeviceClash.found(remote: remote, device: device, lastUploaded: state.uploaded, local: localByPath) {
            report.deviceClash = true
            save()
            return report
        }
        // Removals: ours go up (a marker, then the book's files leave the Drive); others' come down.
        for id in state.removeFromDrive {
            let marker = root.appendingPathComponent(".removed-\(id).json")
            try? Data(#"{"removedBy":"\#(device)"}"#.utf8).write(to: marker)
            defer { try? FileManager.default.removeItem(at: marker) }
            do {
                if !remote.contains(where: { $0.path == SyncLayout.removedPath(id) }) {
                    try await store.upload(marker, as: SyncLayout.removedPath(id), replacing: nil)
                }
                state.removeFromDrive.remove(id)
            } catch { report.problems.append("removing \(id): \(error.localizedDescription)") }
        }
        state.removed.formUnion(remote.compactMap { SyncLayout.removedBook($0.path) })
        // Whatever is left of a removed book (from a device that was offline, say) leaves the Drive, whoever sees it.
        var gone = Set<String>()
        for file in remote where SyncLayout.book(file.path).map(state.removed.contains) ?? false {
            do {
                try await deleteRemote(file)
                report.deleted += 1
                gone.insert(file.id ?? file.path)
            } catch { report.problems.append("\(file.path): \(error.localizedDescription)") }
        }
        remote.removeAll { gone.contains($0.id ?? $0.path) }
        for id in state.removed.sorted() where FileManager.default.fileExists(atPath: books.appendingPathComponent(id).path) {
            report.removedElsewhere.append(id)
        }
        // "Remove all books": inbox uploads leave the Drive.
        if !state.dropInbox.isEmpty || state.dropInboxBefore != nil {
            var failed = false
            for file in remote where SyncLayout.isInbox(file.path) && dropsFromInbox(file) {
                do {
                    try await deleteRemote(file)
                    report.deleted += 1
                    gone.insert(file.id ?? file.path)
                    state.sent.remove(file.path)
                } catch { failed = true; report.problems.append("\(file.path): \(error.localizedDescription)") }
            }
            remote.removeAll { gone.contains($0.id ?? $0.path) }
            if !failed { state.dropInbox = []; state.dropInboxBefore = nil }
        }
        // Our own progress already matching the Drive counts as ours (so a later clash is noticed).
        for file in remote where SyncLayout.progressDevice(file.path) == device && localByPath[file.path] == file.md5 {
            state.uploaded[file.path] = file.md5
        }
        // A pad never re-sends an inbox book it already sent (once it's gone from the Drive, the Mac has it).
        let settled = role == .mac ? state.taken : state.sent
        let plan = SyncPlan.make(local: local, remote: remote, device: device, role: role, wantedMedia: wantedMedia,
                                 takenInbox: settled, removed: state.removed)
        for file in plan.uploads {
            do {
                guard let source = localURL(file.path) else { continue }
                let stored: SyncFile
                do { stored = try await store.upload(source, as: file.path, replacing: file.id) }
                catch DriveError.http(404, _) where file.id != nil {  // deleted since we looked: create it again
                    stored = try await store.upload(source, as: file.path, replacing: nil)
                }
                report.uploaded += 1
                report.bytes += file.size
                if SyncLayout.isInbox(file.path) { state.sent.insert(file.path) }
                if SyncLayout.progressDevice(file.path) == device { state.uploaded[file.path] = stored.md5.isEmpty ? file.md5 : stored.md5 }
            } catch { report.problems.append("\(file.path): \(error.localizedDescription)") }
        }
        for file in plan.downloads {
            do {
                guard let destination = localURL(file.path) else { continue }  // never outside the library folder
                try await store.download(file, to: destination)
                report.downloaded += 1
                report.bytes += file.size
                remember(file.path, destination, md5: file.md5)
            } catch { report.problems.append("\(file.path): \(error.localizedDescription)") }
        }
        var undeleted = Set<String>()
        for file in plan.deletes {
            do {
                try await deleteRemote(file)
                report.deleted += 1
            } catch { undeleted.insert(file.path); report.problems.append("\(file.path): \(error.localizedDescription)") }
        }
        // A taken inbox upload is settled once every copy of it has left the Drive.
        for file in plan.deletes where state.taken.contains(file.path) && !undeleted.contains(file.path) { state.taken.remove(file.path) }
        if role == .mac { offerInbox(&report, remote: Set(remote.map(\.path)), now: now.timeIntervalSince1970 * 1000) }
        if role == .pad {
            // Books the Mac has picked up: their uploads are gone from the Drive, so the local copies can go too.
            let there = Set(remote.map(\.path))
            for path in state.sent where !there.contains(path) && !plan.uploads.contains(where: { $0.path == path }) {
                if let url = localURL(path) { try? FileManager.default.removeItem(at: url) }
                state.sent.remove(path)
            }
        }
        report.devices = await deviceList(remote: remote, now: now, report: &report)
        save()
        return report
    }

    /// This device's note goes up when it's missing from the Drive, its name or id changed, or every `noteEvery` (never
    /// after signing out, `noteRemoved`); the other devices' notes are read (again only when they change). After a new
    /// id, the old id's note leaves the Drive (a device still using that id writes it again on its next sync). Notes the
    /// Drive hasn't seen rewritten for `DeviceInfo.staleAfter` aren't listed and are deleted: that goes by the Drive's
    /// own clock (each note's `modified` against the newest change there), so no device's wrong clock hides or deletes
    /// anyone's note. A note that can't be written, read, or deleted is a problem, never a failed sync.
    private func deviceList(remote: [SyncFile], now: Date, report: inout SyncReport) async -> [DeviceInfo] {
        let nowMs = now.timeIntervalSince1970 * 1000
        let path = SyncLayout.deviceInfoPath(device)
        // One copy of each note: the plan deletes the other copies along with the rest of the duplicates.
        let notes = SyncPlan.deduplicated(remote.filter { SyncLayout.deviceInfo($0.path) != nil }).kept
        let mine = notes.first { $0.path == path }
        let writtenAt = state.noteDevice == device ? state.noteAt : nil
        var retired = Set<String>()
        // The Drive's "now": the newest change it reports (our own note's is at most `noteEvery` old, or just written).
        var driveNow = remote.compactMap(\.modified).max()
        if !noteRemoved, mine == nil || writtenAt == nil || state.noteName != name || nowMs - (writtenAt ?? 0) >= Self.noteEvery {
            let note = DeviceInfo(id: device, name: name, kind: role, lastSync: nowMs)
            let file = root.appendingPathComponent(".deviceinfo-\(device).json")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try JSONEncoder().encode(note).write(to: file, options: .atomic)
                let stored: SyncFile
                do { stored = try await store.upload(file, as: path, replacing: mine?.id) }
                catch DriveError.http(404, _) where mine?.id != nil {  // deleted since we looked: create it again
                    stored = try await store.upload(file, as: path, replacing: nil)
                }
                if noteRemoved {  // signed out while it was on its way up: take it back down
                    try? await deleteRemote(stored)
                    throw CancellationError()
                }
                if let modified = stored.modified { driveNow = max(driveNow ?? modified, modified) }
                if let old = state.noteDevice, old != device, BookID.isValid(old) {
                    retired.insert(old)
                    for stale in notes where stale.path == SyncLayout.deviceInfoPath(old) {
                        do { try await deleteRemote(stale) } catch { report.problems.append("\(stale.path): \(error.localizedDescription)") }
                    }
                }
                (state.noteAt, state.noteName, state.noteDevice) = (nowMs, name, device)
            } catch is CancellationError {  // taken back down (signed out meanwhile): not a problem
            } catch { report.problems.append("\(path): \(error.localizedDescription)") }
        }
        var others: [DeviceInfo] = []
        var present = Set<String>()
        for file in notes {
            guard let id = SyncLayout.deviceInfo(file.path), id != device, !retired.contains(id) else { continue }
            var info: DeviceInfo
            if let cached = state.notes[id], cached.md5 == file.md5, !file.md5.isEmpty {
                info = cached.info
                info.id = id
            } else {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("deviceinfo-\(UUID().uuidString).json")
                defer { try? FileManager.default.removeItem(at: temp) }
                do {
                    guard file.size < 4096 else { continue }
                    try await store.download(file, to: temp)
                    guard let read = DeviceInfo.read(try Data(contentsOf: temp), id: id, now: now) else { continue }
                    info = read
                } catch { report.problems.append("\(file.path): \(error.localizedDescription)"); continue }
            }
            info.lastSync = DeviceInfo.clamped(info.lastSync, now: now)
            if let written = file.modified, let driveNow,
               driveNow.timeIntervalSince(written) * 1000 > DeviceInfo.staleAfter {  // a device long gone: tidy its note away
                do { try await deleteRemote(file) } catch { report.problems.append("\(file.path): \(error.localizedDescription)") }
                continue
            }
            state.notes[id] = SyncState.Note(md5: file.md5, info: info)
            present.insert(id)
            others.append(info)
        }
        state.notes = state.notes.filter { present.contains($0.key) }
        // This device synced just now, whether or not its note needed rewriting.
        let me = DeviceInfo(id: device, name: name, kind: role, lastSync: nowMs, isThisDevice: true)
        return DeviceInfo.unique([me] + others.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    /// Signing out of the library: this device's note leaves the Drive (every copy of it), so other devices stop
    /// listing it, and no sync writes it again (not even one already underway) until `signedIn()`.
    public func removeNote() async throws {
        noteRemoved = true
        (state.noteAt, state.noteName, state.noteDevice) = (nil, nil, nil)
        save()
        for file in try await store.list() where file.path == SyncLayout.deviceInfoPath(device) {
            try await deleteRemote(file)
        }
    }

    /// Signed in (again): this device's note goes up on the next sync.
    public func signedIn() { noteRemoved = false }

    /// Deleting something that's already gone is fine (another device got there first).
    private func deleteRemote(_ file: SyncFile) async throws {
        do { try await store.delete(file) } catch DriveError.http(404, _) {}
    }

    private func dropsFromInbox(_ file: SyncFile) -> Bool {
        if state.dropInbox.contains(file.path) { return true }
        guard let before = state.dropInboxBefore else { return false }
        return (file.modified.map { $0.timeIntervalSince1970 * 1000 } ?? 0) < before
    }

    /// Mac: every inbox book here that isn't taken yet, unless it's waiting out a back-off or Pip gave up on it.
    /// A book whose sidecar is in the Drive but not here yet waits for it (so it gets its title).
    private func offerInbox(_ report: inout SyncReport, remote: Set<String>, now: Double) {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where ["pdf", "epub"].contains(url.pathExtension.lowercased()) && SyncLayout.isInbox("inbox/\(url.lastPathComponent)") {
            let path = "inbox/\(url.lastPathComponent)"
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            guard !state.taken.contains(path) else { continue }
            if !FileManager.default.fileExists(atPath: sidecar.path), remote.contains("inbox/\(sidecar.lastPathComponent)") { continue }
            let attempt = state.tries[path]
            if InboxRetry.gaveUp(attempts: attempt?.count ?? 0) {
                let title = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any])?["title"] as? String
                report.problems.append("Pip couldn't prepare \(title.map { "“\($0)”" } ?? "a book") from your other device after "
                    + "\(InboxRetry.maxAttempts) tries. Add it again there to give it another go.")
            } else if InboxRetry.isDue(attempts: attempt?.count ?? 0, last: attempt?.last ?? 0, now: now) {
                report.arrived.append(url)
            }
        }
    }

    // MARK: local side

    /// This device's files in Drive layout.
    func scan() -> [SyncFile] {
        seen = []
        defer { state.hashes = state.hashes.filter { seen.contains($0.key) } }  // forget files that are gone
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

    private var seen: Set<String> = []

    private func hashed(_ url: URL, as path: String) -> SyncFile? {
        seen.insert(url.path)
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

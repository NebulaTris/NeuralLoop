// The shelf: books in the library folder, adding a book (which starts the pipeline), live progress, and the background
// loop that keeps it all current (resuming unfinished books, NotebookLM's usage, notifications, and Pip's nudges).
// Preparing books is the Mac's job (#if os(macOS)): the iPad reads the same folder, which sync fills, and hands new
// books to the Mac through inbox/.

import Foundation
#if os(macOS)
import AppKit
#endif
import NeuralLoopCore
import Observation

/// One book on the shelf, with this Mac's study progress for it.
struct BookEntry: Identifiable, Equatable {
    let id: String
    let folder: URL
    var book: Book?
    var progress: StudyProgress
    var preparing: Bool
    var lastLine: String
    /// What the pipeline is making right now (its activity.json), for the progress loader.
    var activity: PrepActivity? = nil

    var title: String { book?.title ?? id.replacingOccurrences(of: "-", with: " ") }
    var readyChapters: Int { book?.chapters.filter { $0.status["study"] == .done }.count ?? 0 }
}

/// What one look at a book folder found (read off the main thread).
private struct Scanned: Sendable {
    let id: String
    let folder: URL
    let book: Book?
    let bookModified: Date?
    let progress: StudyProgress
    let progressModified: Date?
    let addedAt: Double
    let media: String
    let dryRun: Bool
    let sourcePath: String?
    let logModified: Double
    let elsewhere: (n: Int, item: String)?
    let elsewhereLine: String?
    let activity: PrepActivity?
}

@MainActor @Observable
final class Library {
    var entries: [BookEntry] = []
    var path: [String] = []
    var isPicking = false
    /// The guided tour, asked for from Help (Mac) or Settings (iPad).
    var showingTour = false
    var message: String?

    /// Show the guided tour. Asking again always works, even if an earlier request never made it on screen (the flag
    /// is lowered first, so the sheet sees it rise again).
    func requestTour() {
        guard showingTour else { showingTour = true; return }
        showingTour = false
        Task { @MainActor in self.showingTour = true }
    }
    /// NotebookLM's live usage (five-hour and weekly windows), refreshed every few minutes.
    var usage: NotebookLMUsage?

    #if os(macOS)
    @ObservationIgnored private var runs: [String: PipelineRunner] = [:]
    @ObservationIgnored private var records: [String: RunRecord] = Library.loadRecords()
    @ObservationIgnored private var usageCheckedAt = Date.distantPast
    /// Runs stopped on purpose (the book was removed): their ending isn't a failure to record or announce.
    @ObservationIgnored private var stopping: Set<String> = []
    /// Books whose source file is still being copied in (they show as getting started).
    @ObservationIgnored private var adding: Set<String> = []
    #endif
    /// Books on their way out (waiting for a run to stop before the folder goes): off the shelf, never resumed.
    @ObservationIgnored private var removing: Set<String> = []
    @ObservationIgnored private var scanned: [String: Scanned] = [:]
    /// What each book looked like when notifications were last worked out; separate from `entries`, which live progress
    /// lines update early, so "chapter ready" is never missed.
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var started = false

    /// Same folder as the earlier desktop app, so existing books and progress carry over.
    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("app.neuralloop.books/books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func entry(_ id: String) -> BookEntry? { entries.first { $0.id == id } }

    // MARK: the background loop

    #if os(macOS)
    /// Runs for as long as the app does, with or without a window open (Pip lives in the menu bar).
    func start() {
        guard !started else { return }
        started = true
        Notifier.shared.start()
        Notifier.shared.openBook = { [weak self] id in if !id.isEmpty { self?.path = [id] } }
        // A visit counts from when you leave too, so time away is measured from then.
        for visit in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: visit, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Nudger.engaged() }
            }
        }
        Task {
            await refresh()
            await refreshUsage(force: true)
            resumeUnfinished()
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await refresh()
                ticks += 1
                if ticks % 75 == 0 {  // every ~5 minutes: usage, retries whose limit lifted, and maybe a gentle nudge
                    Task { await self.refreshUsage() }  // never lets a slow check hold up the shelf
                    resumeUnfinished()
                    Nudger.tick(entries)
                }
            }
        }
    }

    func refreshUsage(force: Bool = false) async {
        guard force || Date().timeIntervalSince(usageCheckedAt) > 300 else { return }
        usageCheckedAt = Date()
        let (_, lines) = await PipelineRunner.once(["--usage"], timeout: .seconds(60))
        if let fresh = lines.compactMap(NotebookLMUsage.parse).first { usage = fresh }
    }
    #else
    /// The iPad only reads the shelf: it looks again every few seconds (sync writes into the same folder).
    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.removeItem(at: Self.incoming)  // copies a previous launch didn't finish
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
    #endif

    /// True while this app is running the pipeline for a book, or copying it in to start (the Mac; the iPad never
    /// prepares books).
    private func runningHere(_ id: String) -> Bool {
        #if os(macOS)
        runs[id] != nil || adding.contains(id)
        #else
        false
        #endif
    }

    /// Look at the shelf again soon (after adding a book, a run ending, …).
    func reload() { Task { await refresh() } }

    /// Reads every book folder off the main thread (reusing what hasn't changed on disk), then updates the shelf.
    func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            let previous = scanned
            let fresh = await Task.detached(priority: .utility) { Self.scan(previous: previous) }.value
            apply(fresh)
        } while refreshAgain
    }

    private func apply(_ all: [Scanned]) {
        let fresh = all.filter { !removing.contains($0.id) }
        scanned = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        let updated = fresh.map { item -> BookEntry in
            let running = runningHere(item.id)
            let line = running ? (entry(item.id)?.lastLine ?? "")
                : item.elsewhereLine ?? item.elsewhere.map { $0.n == 0 ? "Pip is getting started…" : "Making the \(Self.itemName($0.item)) for chapter \($0.n)…" } ?? ""
            let preparing = running || item.elsewhere != nil
            return BookEntry(id: item.id, folder: item.folder, book: item.book, progress: item.progress,
                             preparing: preparing, lastLine: line, activity: preparing ? item.activity : nil)
        }
        #if os(macOS)
        announce(updated)
        #endif
        if updated != entries { entries = updated }  // unchanged shelves don't redraw every view
    }

    #if os(macOS)
    /// "Chapter 2 is ready" (`ChapterReady`): once per chapter, only for the chapter you can study next, and only when
    /// its whole loop is ready, podcast and video included. Chapters being watched are remembered across launches.
    private func announce(_ updated: [BookEntry]) {
        let saved = Nudger.watchingChapters
        var watching = saved.filter { id, _ in updated.contains { $0.id == id } }
        let allowed = Nudger.settings.allows(.chapterReady) && Nudger.scheduledAllowed
        for entry in updated {
            guard let book = entry.book else { continue }
            let step = ChapterReady.step(book: book, progress: entry.progress, watching: Set(watching[entry.id] ?? []))
            watching[entry.id] = step.watching.isEmpty ? nil : step.watching.sorted()
            if let chapter = step.announce, allowed {
                Notifier.shared.post(title: "Chapter \(chapter.n) is ready to study",
                                     body: "“\(chapter.title)” in \(entry.title): its whole loop is ready. Pip saved you a spot.", bookId: entry.id)
            }
        }
        if watching != saved { Nudger.watchingChapters = watching }
    }
    #endif

    nonisolated private static func scan(previous: [String: Scanned]) -> [Scanned] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        func modified(_ url: URL) -> Date? { (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
        return folders
            .filter { BookID.isValid($0.lastPathComponent) && $0.hasDirectoryPath }
            .map { folder -> Scanned in
                let id = folder.lastPathComponent
                let old = previous[id]
                let bookFile = folder.appendingPathComponent("book.json")
                let bookModified = modified(bookFile) ?? modified(folder.appendingPathComponent("book-data.js"))
                let book = old != nil && old?.bookModified == bookModified ? old?.book : loadBook(folder)
                let progressModified = modified(folder.appendingPathComponent("progress.json"))
                let progress = old != nil && old?.progressModified == progressModified ? old!.progress : ProgressFile.loadMerged(from: folder).merged
                let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json")))) as? [String: Any]
                let options = meta?["options"] as? [String: Any]
                // A run started elsewhere (the command line, or before a relaunch) holds the book's lock.
                #if os(macOS)
                let elsewhere = runningElsewhere(folder) ? (working(book) ?? (0, "study")) : nil
                #else
                let elsewhere: (n: Int, item: String)? = nil
                #endif
                let log = folder.appendingPathComponent("pipeline.log")
                return Scanned(
                    id: id, folder: folder, book: book, bookModified: bookModified, progress: progress, progressModified: progressModified,
                    addedAt: meta?["addedAt"] as? Double ?? 0, media: options?["media"] as? String ?? "1-2",
                    dryRun: options?["dryRun"] as? Bool ?? false, sourcePath: meta?["path"] as? String,
                    logModified: (modified(log)?.timeIntervalSince1970 ?? 0) * 1000,
                    elsewhere: elsewhere,
                    elsewhereLine: elsewhereLine(elsewhere != nil, log: log),
                    activity: (try? Data(contentsOf: folder.appendingPathComponent("activity.json"))).flatMap(PrepActivity.read)
                )
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    nonisolated private static func elsewhereLine(_ running: Bool, log: URL) -> String? {
        #if os(macOS)
        running ? LogFollower.lastProgress(in: log).flatMap(describe) : nil
        #else
        nil
        #endif
    }

    // MARK: book folder helpers

    /// Books added before the app kept copies still point at the original file: copy it in once and remember that.
    nonisolated static func keepCopy(of path: String, in folder: URL) -> String? {
        guard !path.hasPrefix(folder.path) else { return nil }
        let original = URL(fileURLWithPath: path)
        let copy = folder.appendingPathComponent("source.\(original.pathExtension.lowercased())")
        guard FileManager.default.fileExists(atPath: copy.path) || (try? FileManager.default.copyItem(at: original, to: copy)) != nil else { return nil }
        updateMeta(folder) { meta in
            meta["path"] = copy.path
            meta["originalPath"] = path
        }
        return copy.path
    }

    nonisolated static func updateMeta(_ folder: URL, _ change: (inout [String: Any]) -> Void) {
        let file = folder.appendingPathComponent("meta.json")
        var meta = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]) ?? [:]
        change(&meta)
        try? JSONSerialization.data(withJSONObject: meta).write(to: file, options: .atomic)
    }

    #if os(macOS)
    /// True while a pipeline run holds this book's lock (the pipeline keeps an OS lock on `.running` for the whole run,
    /// released even if it's killed; a leftover file never counts).
    nonisolated static func runningElsewhere(_ folder: URL) -> Bool {
        let fd = open(folder.appendingPathComponent(".running").path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
    #endif

    /// The first item Pip is making right now, if any.
    nonisolated static func working(_ book: Book?) -> (n: Int, item: String)? {
        for chapter in book?.chapters ?? [] {
            if let item = chapter.status.first(where: { $0.value == .working })?.key { return (chapter.n, item) }
        }
        return nil
    }

    /// book.json, or book-data.js from books made before the app existed.
    nonisolated static func loadBook(_ folder: URL) -> Book? {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: folder.appendingPathComponent("book.json")) {
            return try? decoder.decode(Book.self, from: data)
        }
        guard var text = try? String(contentsOf: folder.appendingPathComponent("book-data.js"), encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("window.BOOK = ") { text.removeFirst("window.BOOK = ".count) }
        if text.hasSuffix(";") { text.removeLast() }
        return try? decoder.decode(Book.self, from: Data(text.utf8))
    }

    // MARK: adding and preparing

    /// Where books added on a device that can't prepare them wait for the Mac (sync uploads them to Drive's inbox/).
    nonisolated static let inbox: URL = root.deletingLastPathComponent().appendingPathComponent("inbox", isDirectory: true)

    // MARK: removing books

    /// Removes a book from this device (its folder goes to the Trash) and, through sync, from every device. A run
    /// preparing it is stopped first (this app's own, or one started elsewhere that holds the book's lock).
    func removeBook(_ id: String) {
        guard BookID.isValid(id), let entry = entry(id) else { return }
        letGo(id, folder: entry.folder)
        DriveSync.shared.removed(book: id)
    }

    /// Every book goes: folders to the Trash, books waiting in the inbox (here and in the Drive), and how runs ended.
    func removeAllBooks() {
        for entry in entries { removeBook(entry.id) }
        DriveSync.shared.forgetInbox()
        forget(Self.inbox)
        #if os(macOS)
        try? FileManager.default.removeItem(at: Self.recordsFile)
        records = [:]
        #endif
    }

    /// Another device removed this book: stop preparing it and let the folder go here too. Sync asks again every time
    /// while the folder is still here, so a removal that didn't finish is retried.
    func removedElsewhere(_ id: String) {
        guard BookID.isValid(id), !removing.contains(id) else { return }
        letGo(id, folder: Self.root.appendingPathComponent(id, isDirectory: true))
    }

    /// Off the shelf now; the folder goes once any run preparing the book has stopped (or after a few seconds).
    private func letGo(_ id: String, folder: URL) {
        removing.insert(id)
        if path.contains(id) { path.removeAll() }
        entries.removeAll { $0.id == id }
        MediaCenter.shared.forget(folder: folder)  // its podcast or video stops, and the lock screen lets go
        #if os(macOS)
        if let run = runs[id] {
            stopping.insert(id)
            run.stop()
        } else {
            Self.stopRunElsewhere(folder)
        }
        #endif
        Task {
            #if os(macOS)
            await Task.detached(priority: .userInitiated) { await Self.waitUntilUnlocked(folder, seconds: 3) }.value
            #endif
            forget(folder)
            removing.remove(id)
            reload()
        }
    }

    #if os(macOS)
    /// A run this app didn't start (the command line, or before a relaunch): its process id is in `.running`, trusted
    /// only while that run holds the lock on it.
    nonisolated private static func stopRunElsewhere(_ folder: URL) {
        guard runningElsewhere(folder),
              let text = try? String(contentsOf: folder.appendingPathComponent(".running"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1, pid != getpid()
        else { return }
        kill(pid, SIGTERM)
    }

    /// Waits (off the main thread) until no run holds the book's lock, for at most `seconds`.
    nonisolated private static func waitUntilUnlocked(_ folder: URL, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while runningElsewhere(folder), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
    #endif

    /// To the Trash when there is one (so a slip can be undone), otherwise removed.
    private func forget(_ folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if (try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// How much room the library takes on this device.
    nonisolated static func librarySize() -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Where a book added on the iPad is copied before it goes into the inbox (sync never looks here, so it never
    /// sends half a file).
    nonisolated static let incoming: URL = root.deletingLastPathComponent().appendingPathComponent("incoming", isDirectory: true)

    /// The iPad's "Add a book": keep a copy in inbox/ with a {title, addedAt} sidecar, for the Mac to prepare. The copy
    /// is made off the main thread under incoming/, the sidecar written first, then the book moved into inbox/ whole.
    func addToInbox(_ file: URL) {
        guard ["pdf", "epub"].contains(file.pathExtension.lowercased()) else {
            message = "Pip can read PDF and EPUB books."
            return
        }
        let title = PipelineCommand.bookTitle(given: nil, file: file)
        let id = UUID().uuidString.lowercased()
        let ext = file.pathExtension.lowercased()
        let staged = Self.incoming.appendingPathComponent("\(id).\(ext)")
        let scoped = file.startAccessingSecurityScopedResource()  // a file picked in Files
        try? FileManager.default.createDirectory(at: Self.incoming, withIntermediateDirectories: true)
        // Instant when the file is already on this device (a hard link), so a caller may tidy its own copy right after.
        let linked = (try? FileManager.default.linkItem(at: file, to: staged)) != nil
        Task {
            let copied = linked ? true : await Task.detached(priority: .userInitiated) {
                (try? FileManager.default.copyItem(at: file, to: staged)) != nil
            }.value
            if scoped { file.stopAccessingSecurityScopedResource() }
            let added = copied ? await Task.detached(priority: .userInitiated) { Self.moveIntoInbox(staged, id: id, ext: ext, title: title) }.value : false
            if added {
                message = "Your Mac will prepare “\(title)” the next time it syncs."
            } else {
                try? FileManager.default.removeItem(at: staged)
                message = "Pip couldn't copy “\(file.lastPathComponent)”. Check that the file has finished downloading, then try again."
            }
        }
    }

    /// The sidecar first, then the book file moved in whole (same volume, so it's one rename).
    nonisolated private static func moveIntoInbox(_ staged: URL, id: String, ext: String, title: String) -> Bool {
        let fm = FileManager.default
        let sidecar = inbox.appendingPathComponent("\(id).json")
        do {
            try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
            let details: [String: Any] = ["title": title, "addedAt": Date().timeIntervalSince1970 * 1000]
            try JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]).write(to: sidecar, options: .atomic)
            try fm.moveItem(at: staged, to: inbox.appendingPathComponent("\(id).\(ext)"))
            return true
        } catch {
            try? fm.removeItem(at: sidecar)
            return false
        }
    }

    #if os(macOS)

    /// "You never press generate": carry on with any book that still has work, unless its last run needs something
    /// from the person first (setup, a readable book) or keeps failing (then it backs off).
    func resumeUnfinished() {
        let now = Date().timeIntervalSince1970 * 1000
        for item in scanned.values where runs[item.id] == nil && item.elsewhere == nil && !adding.contains(item.id) {
            guard let book = item.book,
                  AutoResume.hasWork(book, usage: usage, logModified: item.logModified, now: now),
                  AutoResume.mayStart(after: records[item.id], settingsChangedAt: AISettings.changedAt, now: now),
                  var path = item.sourcePath, FileManager.default.fileExists(atPath: path)
            else { continue }
            path = Self.keepCopy(of: path, in: item.folder) ?? path
            let retry = book.chapters.contains { $0.status.values.contains(.waiting) }
            prepare(id: item.id, book: URL(fileURLWithPath: path), options: .init(media: item.media, dryRun: item.dryRun, retry: retry))
        }
    }

    /// A book added on another device, waiting in the inbox: prepare it like a dropped book. Returns true once it's on
    /// the shelf (so sync can take it out of the inbox); the copy is quick (same disk) and done before answering.
    func addFromInbox(_ file: URL, title: String?) -> Bool {
        let title = PipelineCommand.bookTitle(given: title, file: file)  // never the inbox file's UUID
        guard let (id, folder, copy) = newBook(file, title: title) else { return false }
        guard Self.copySource(file, to: copy) else {
            couldNotCopy(file, folder: folder)
            return false
        }
        startNew(id, folder: folder, copy: copy, original: file, practice: false, title: title)
        return true
    }

    /// A dropped or picked book: the copy is made off the main thread (it may be big, or on another disk), then Pip
    /// starts preparing it. Returns false only when it isn't a book Pip can read.
    @discardableResult
    func add(_ file: URL, practice: Bool = false, title: String? = nil) -> Bool {
        let title = PipelineCommand.bookTitle(given: title, file: file)
        guard let (id, folder, copy) = newBook(file, title: title) else { return false }
        adding.insert(id)
        reload()
        Task {
            let copied = await Task.detached(priority: .userInitiated) { Self.copySource(file, to: copy) }.value
            adding.remove(id)
            if copied { startNew(id, folder: folder, copy: copy, original: file, practice: practice, title: title) } else { couldNotCopy(file, folder: folder) }
        }
        return true
    }

    /// A fresh id (never one on disk, on the shelf, or removed on any device) and its folder.
    private func newBook(_ file: URL, title: String) -> (id: String, folder: URL, copy: URL)? {
        guard ["pdf", "epub"].contains(file.pathExtension.lowercased()) else {
            message = "Pip can read PDF and EPUB books."
            return nil
        }
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: Self.root.path)) ?? [])
        let taken = Set(entries.map(\.id)).union(DriveSync.shared.removedBooks).union(onDisk).union(adding).union(removing)
        let id = BookID.unique(base: BookID.slug(title), taken: taken)
        let folder = Self.root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep our own copy: the book still works if the original moves, and later runs never need to reach into
        // Desktop or Documents (which macOS guards with a permission prompt).
        return (id, folder, folder.appendingPathComponent("source.\(file.pathExtension.lowercased())"))
    }

    nonisolated private static func copySource(_ file: URL, to copy: URL) -> Bool {
        (try? FileManager.default.copyItem(at: file, to: copy)) != nil
    }

    /// No ghost books: the folder made for it goes again.
    private func couldNotCopy(_ file: URL, folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        message = "Pip couldn't copy “\(file.lastPathComponent)”. Check that the file isn't still downloading, then try again."
        reload()
    }

    /// The chosen title goes into meta.json, so every later run (resumed, "Prepare more") names the book the same way,
    /// even when the first run stopped before the pipeline saved anything.
    private func startNew(_ id: String, folder: URL, copy: URL, original: URL, practice: Bool, title: String) {
        let meta: [String: Any] = ["path": copy.path, "originalPath": original.path, "addedAt": Date().timeIntervalSince1970 * 1000,
                                   "title": title, "options": ["media": "1-2", "dryRun": practice]]
        try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
        prepare(id: id, book: copy, options: .init(media: "1-2", dryRun: practice), title: title)
        reload()
    }

    /// Podcasts and videos for every chapter, and another try for anything that failed. Remembered, so later automatic
    /// runs keep making media for every chapter.
    func prepareMore(_ id: String) {
        guard startable(id), let folder = entry(id)?.folder, let path = sourcePath(id) else { return }
        Self.updateMeta(folder) { meta in
            var options = meta["options"] as? [String: Any] ?? [:]
            options["media"] = "all"
            meta["options"] = options
        }
        prepare(id: id, book: URL(fileURLWithPath: path), options: .init(media: "all", retry: true))
        reload()
    }

    /// Make a book's waiting items right now with your own AI instead of waiting for NotebookLM.
    func makeWithMyAI(_ id: String) {
        guard startable(id), let path = sourcePath(id) else { return }
        prepare(id: id, book: URL(fileURLWithPath: path), options: .init(media: scanned[id]?.media ?? "1-2", retry: true, engine: "local"))
        reload()
    }

    private func sourcePath(_ id: String) -> String? {
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("\(id)/meta.json")))) as? [String: Any]
        return meta?["path"] as? String
    }

    private func startable(_ id: String) -> Bool {
        guard runs[id] == nil, entry(id)?.preparing != true else {
            message = "Pip is already working on this book. Give it a moment to finish, then try again."
            return false
        }
        return true
    }

    /// The title saved when the book was added; books added before that was saved are named after their original file.
    nonisolated private static func savedTitle(_ folder: URL) -> String? {
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json")))) as? [String: Any]
        if let title = meta?["title"] as? String { return PipelineCommand.bookTitle(given: title, file: folder) }
        return (meta?["originalPath"] as? String).map { PipelineCommand.bookTitle(given: nil, file: URL(fileURLWithPath: $0)) }
    }

    private func prepare(id: String, book: URL, options: PipelineCommand.Options, title: String? = nil) {
        let out = Self.root.appendingPathComponent(id, isDirectory: true)
        let title = title ?? Self.savedTitle(out)
        let runner = PipelineRunner()
        runs[id] = runner
        do {
            try runner.start(arguments: PipelineCommand.arguments(book: book.path, out: out.path, options: options, title: title),
                             log: out.appendingPathComponent("pipeline.log")) { [weak self] line in
                Task { @MainActor in self?.handle(id, line) }
            } onExit: { [weak self] code, tail in
                Task { @MainActor in self?.finished(id, code: code, tail: tail) }
            }
        } catch {
            runs[id] = nil
            message = "Pip couldn't start preparing: \(error.localizedDescription)"
        }
    }

    private func handle(_ id: String, _ raw: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let line = PipelineLine.parse(raw)
        entries[index].lastLine = Self.describe(line) ?? entries[index].lastLine
        if case .made = line { reload() }  // the book on screen catches up; notifications compare against their own snapshot
    }

    private func finished(_ id: String, code: Int32, tail: [String]) {
        if stopping.remove(id) != nil {  // stopped on purpose (removed): not a failure
            runs[id] = nil
            reload()
            return
        }
        runs[id] = nil
        let alreadyRunning = tail.contains { $0.contains("already being prepared") }
        if !alreadyRunning {
            records[id] = RunRecord.after(records[id], code: code, now: Date().timeIntervalSince1970 * 1000)
            Self.saveRecords(records)
        }
        reload()
        let outcome = Self.outcome(title: entry(id)?.title ?? "Your book", code: code, tail: tail)
        message = code == 0 ? nil : outcome  // success is announced by a notification, not an alert
    }

    // MARK: run records (how each book's last run ended, so automatic runs know when to wait)

    private static let recordsFile = root.deletingLastPathComponent().appendingPathComponent("runs.json")

    private static func loadRecords() -> [String: RunRecord] {
        (try? JSONDecoder().decode([String: RunRecord].self, from: Data(contentsOf: recordsFile))) ?? [:]
    }

    private static func saveRecords(_ records: [String: RunRecord]) {
        try? JSONEncoder().encode(records).write(to: recordsFile, options: .atomic)
    }
    #endif

    // MARK: words

    /// What to tell the person when a run ends: nothing alarming when another run already has the book, the pipeline's
    /// own advice when setup is needed (exit 3), and the actual last error otherwise.
    static func outcome(title: String, code: Int32, tail: [String]) -> String? {
        if code == 0 { return "“\(title)” is ready." }
        if tail.contains(where: { $0.contains("already being prepared") }) { return nil }
        let reason = tail.last(where: { !$0.hasPrefix("File \"") && !$0.hasPrefix("^") && !$0.hasPrefix("Traceback") }) ?? ""
        if code == 3 { return reason.isEmpty ? "Pip needs a little setup first. Open Settings → Your AI." : reason }
        let detail = reason.isEmpty ? "" : " (\(reason.prefix(160)))"
        return "Pip hit a snag preparing “\(title)”\(detail). Open the book and choose Prepare more to try again; the full story is in its pipeline.log."
    }

    /// Plain words for a progress line, for the book card.
    nonisolated static func describe(_ line: PipelineLine) -> String? {
        switch line {
        case .added(let n): "Reading chapter \(n)…"
        case .made(let n, let item): "Chapter \(n): \(itemName(item)) ready"
        case .fellBack(let n, let item, let to): "Chapter \(n): making the \(itemName(item)) with \(to)"
        case .waiting(let n, let item): "Chapter \(n): \(itemName(item)) will be made later"
        case .failed(let n, let item, _): "Chapter \(n): the \(itemName(item)) needs another try"
        case .setup(let text): text.prefix(1).uppercased() + text.dropFirst()
        case .finished: "All set"
        case .note(let text): text.isEmpty ? nil : text
        }
    }

    nonisolated static func itemName(_ item: String) -> String {
        ["study": "reading guide", "graph": "concept map", "quiz": "quiz", "cards": "flashcards",
         "mindmap": "mind map", "audio": "podcast", "video": "video"][item] ?? item
    }
}

#if os(macOS)
/// Pip's gentle nudges: the settings and history live in UserDefaults; the policy is NeuralLoopCore's `Nudges`.
@MainActor
enum Nudger {
    static var settings: NudgeSettings {
        get { load("nudgeSettings") ?? NudgeSettings() }
        set { store(newValue, "nudgeSettings") }
    }

    static var history: NudgeHistory {
        get { load("nudgeHistory") ?? NudgeHistory() }
        set { store(newValue, "nudgeHistory") }
    }

    /// Scheduled notifications (nudges, "chapter ready") only come from the real app: a development build sends them
    /// only with `-NLNotify YES`, so test copies never pile notifications on top of the real one. Tests from Settings
    /// and the -NLTestNudge flag are asked for, so they always go.
    static var scheduledAllowed: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "NLNotify")
        #else
        true
        #endif
    }

    /// Chapters `ChapterReady` is waiting on, per book (they were still being made when they became current).
    static var watchingChapters: [String: [Int]] {
        get { (UserDefaults.standard.dictionary(forKey: "chapterReadyWatching") as? [String: [Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "chapterReadyWatching") }
    }

    static func tick(_ entries: [BookEntry]) {
        guard scheduledAllowed else { return }
        let books = entries.compactMap { entry in entry.book.map { (book: $0, progress: entry.progress) } }
        let now = Date()
        let today = Activity.dayKey(now.timeIntervalSince1970 * 1000)
        let hour = Calendar.current.component(.hour, from: now)
        guard let nudge = Nudges.decide(books: books, settings: settings, history: history, now: now.timeIntervalSince1970 * 1000,
                                        hour: hour, today: today, appActive: NSApp.isActive) else { return }
        send(nudge, day: today)
    }

    /// `test`: from Settings, so it isn't remembered (it doesn't use up today's nudge or a silly one).
    static func send(_ nudge: Nudge, day: String? = nil, test: Bool = false) {
        let now = Date().timeIntervalSince1970 * 1000
        if !test {
            var h = history
            h.sent(nudge, now: now, day: day ?? Activity.dayKey(now))
            history = h
        }
        // The big Pip only when nothing else is going on; otherwise (or if its sound won't play) the notification
        // carries the sound, keeping to Focus.
        let onScreen = NudgeDelivery.showsBigPip(nudge.mood, settings: settings, moment: NudgeOverlay.moment())
        let playing = onScreen && NudgeOverlay.shared.show(nudge, volume: settings.volume)
        let mood = nudge.mood
        var picture: (@MainActor () -> URL?)?
        if mood != .gentle { picture = { NudgeSounds.picture(mood) } }
        Notifier.shared.post(title: nudge.title, body: nudge.body, bookId: "", sound: playing ? nil : NudgeSounds.sound(mood),
                             picture: picture)
    }

    private static var lastVisit = Date.distantPast

    /// A visit: opening NeuralLoop, leaving it, and every minute or so of studying.
    static func engaged() {
        lastVisit = Date()
        var h = history
        h.engaged(now: lastVisit.timeIntervalSince1970 * 1000)
        history = h
    }

    /// While studying (the study clock's ticks): at most once a minute.
    static func studying() {
        if Date().timeIntervalSince(lastVisit) >= 60 { engaged() }
    }

    static func pauseUntilTomorrow() {
        var s = settings
        s.pausedUntil = Nudges.pauseUntilTomorrow(now: Date(), quietEnd: s.quietEnd)
        settings = s
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
#endif

// The shelf: books in the library folder, adding a book (which starts the pipeline), live progress, and the background
// loop that keeps it all current (resuming unfinished books, NotebookLM's usage, notifications, and Pip's nudges).

import AppKit
import Foundation
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
}

@MainActor @Observable
final class Library {
    var entries: [BookEntry] = []
    var path: [String] = []
    var isPicking = false
    var message: String?
    /// NotebookLM's live usage (five-hour and weekly windows), refreshed every few minutes.
    var usage: NotebookLMUsage?

    @ObservationIgnored private var runs: [String: PipelineRunner] = [:]
    @ObservationIgnored private var scanned: [String: Scanned] = [:]
    /// What each book looked like when notifications were last worked out; separate from `entries`, which live progress
    /// lines update early, so "chapter ready" is never missed.
    @ObservationIgnored private var notified: [String: Book] = [:]
    @ObservationIgnored private var records: [String: RunRecord] = Library.loadRecords()
    @ObservationIgnored private var usageCheckedAt = Date.distantPast
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

    /// Runs for as long as the app does, with or without a window open (Pip lives in the menu bar).
    func start() {
        guard !started else { return }
        started = true
        Notifier.shared.start()
        Notifier.shared.openBook = { [weak self] id in if !id.isEmpty { self?.path = [id] } }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Nudger.engaged() }
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

    private func apply(_ fresh: [Scanned]) {
        scanned = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        let updated = fresh.map { item -> BookEntry in
            let running = runs[item.id] != nil
            let line = running ? (entry(item.id)?.lastLine ?? "")
                : item.elsewhereLine ?? item.elsewhere.map { $0.n == 0 ? "Pip is getting started…" : "Making the \(Self.itemName($0.item)) for chapter \($0.n)…" } ?? ""
            return BookEntry(id: item.id, folder: item.folder, book: item.book, progress: item.progress,
                             preparing: running || item.elsewhere != nil, lastLine: line)
        }
        announce(updated)
        if updated != entries { entries = updated }  // unchanged shelves don't redraw every view
    }

    /// "Chapter 2 is ready to study" and "Your book is ready", for changes seen while the app runs.
    private func announce(_ updated: [BookEntry]) {
        for entry in updated {
            guard let book = entry.book else { continue }
            defer { notified[entry.id] = book }
            guard let before = notified[entry.id] else { continue }
            let news = Notifier.news(before: before, after: book)
            for chapter in news.chapters {
                Notifier.shared.post(title: "Chapter \(chapter.n) is ready to study",
                                     body: "“\(chapter.title)” in \(entry.title). Pip saved you a spot.", bookId: entry.id)
            }
            if news.finished {
                Notifier.shared.post(title: "“\(entry.title)” is ready", body: "Every chapter's loop is prepared. Come take a look!", bookId: entry.id)
            }
        }
    }

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
                let progress = old != nil && old?.progressModified == progressModified ? old!.progress : ProgressFile.load(from: folder)
                let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json")))) as? [String: Any]
                let options = meta?["options"] as? [String: Any]
                // A run started elsewhere (the command line, or before a relaunch) holds the book's lock.
                let elsewhere = runningElsewhere(folder) ? (working(book) ?? (0, "study")) : nil
                let log = folder.appendingPathComponent("pipeline.log")
                return Scanned(
                    id: id, folder: folder, book: book, bookModified: bookModified, progress: progress, progressModified: progressModified,
                    addedAt: meta?["addedAt"] as? Double ?? 0, media: options?["media"] as? String ?? "1-2",
                    dryRun: options?["dryRun"] as? Bool ?? false, sourcePath: meta?["path"] as? String,
                    logModified: (modified(log)?.timeIntervalSince1970 ?? 0) * 1000,
                    elsewhere: elsewhere,
                    elsewhereLine: elsewhere == nil ? nil : LogFollower.lastProgress(in: log).flatMap(describe)
                )
            }
            .sorted { $0.addedAt > $1.addedAt }
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

    /// "You never press generate": carry on with any book that still has work, unless its last run needs something
    /// from the person first (setup, a readable book) or keeps failing (then it backs off).
    func resumeUnfinished() {
        let now = Date().timeIntervalSince1970 * 1000
        for item in scanned.values where runs[item.id] == nil && item.elsewhere == nil {
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

    func add(_ file: URL, practice: Bool = false) {
        guard ["pdf", "epub"].contains(file.pathExtension.lowercased()) else {
            message = "Pip can read PDF and EPUB books."
            return
        }
        let taken = Set(entries.map(\.id))
        let id = BookID.unique(base: BookID.slug(file.deletingPathExtension().lastPathComponent), taken: taken)
        let folder = Self.root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep our own copy: the book still works if the original moves, and later runs never need to reach into
        // Desktop or Documents (which macOS guards with a permission prompt).
        let copy = folder.appendingPathComponent("source.\(file.pathExtension.lowercased())")
        if (try? FileManager.default.copyItem(at: file, to: copy)) == nil {
            message = "Pip couldn't copy “\(file.lastPathComponent)”. Check that the file isn't still downloading, then try again."
            return
        }
        let meta: [String: Any] = ["path": copy.path, "originalPath": file.path, "addedAt": Date().timeIntervalSince1970 * 1000,
                                   "options": ["media": "1-2", "dryRun": practice]]
        try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
        prepare(id: id, book: copy, options: .init(media: "1-2", dryRun: practice))
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

    private func prepare(id: String, book: URL, options: PipelineCommand.Options) {
        let out = Self.root.appendingPathComponent(id, isDirectory: true)
        let runner = PipelineRunner()
        runs[id] = runner
        do {
            try runner.start(arguments: PipelineCommand.arguments(book: book.path, out: out.path, options: options),
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

    static func tick(_ entries: [BookEntry]) {
        let books = entries.compactMap { entry in entry.book.map { (book: $0, progress: entry.progress) } }
        let now = Date()
        let today = Activity.dayKey(now.timeIntervalSince1970 * 1000)
        let hour = Calendar.current.component(.hour, from: now)
        guard let nudge = Nudges.decide(books: books, settings: settings, history: history,
                                        now: now.timeIntervalSince1970 * 1000, hour: hour, today: today) else { return }
        send(nudge, day: today)
    }

    static func send(_ nudge: Nudge, day: String? = nil) {
        var h = history
        h.sent(now: Date().timeIntervalSince1970 * 1000, day: day ?? Activity.dayKey(Date().timeIntervalSince1970 * 1000))
        history = h
        Notifier.shared.post(title: nudge.title, body: nudge.body, bookId: "")
    }

    static func engaged() {
        var h = history
        h.engaged(now: Date().timeIntervalSince1970 * 1000)
        history = h
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

// The shelf: books in the library folder, adding a book (which starts the pipeline), and live progress.

import Foundation
import NeuralLoopCore
import Observation

/// One book on the shelf.
struct BookEntry: Identifiable, Equatable {
    let id: String
    let folder: URL
    var book: Book?
    var preparing: Bool
    var lastLine: String

    var title: String { book?.title ?? id.replacingOccurrences(of: "-", with: " ") }
    var readyChapters: Int { book?.chapters.filter { $0.status["study"] == .done }.count ?? 0 }
}

@MainActor @Observable
final class Library {
    var entries: [BookEntry] = []
    var path: [String] = []
    var isPicking = false
    var message: String?
    private var runs: [String: PipelineRunner] = [:]

    /// Same folder as the earlier desktop app, so existing books and progress carry over.
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("app.neuralloop.books/books", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func entry(_ id: String) -> BookEntry? { entries.first { $0.id == id } }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        entries = folders
            .filter { BookID.isValid($0.lastPathComponent) && $0.hasDirectoryPath }
            .sorted { added($0) > added($1) }
            .map { folder in
                let id = folder.lastPathComponent
                let book = Self.loadBook(folder)
                // A run started elsewhere (the command line, later the iPad's queue) holds the book's lock.
                let working = Self.runningElsewhere(folder) ? Self.working(book) ?? (0, "study") : nil
                let line = runs[id] != nil ? (entry(id)?.lastLine ?? "") : working.map { $0.n == 0 ? "Pip is getting started…" : "Making the \(Self.itemName($0.item)) for chapter \($0.n)…" } ?? ""
                return BookEntry(id: id, folder: folder, book: book, preparing: runs[id] != nil || working != nil, lastLine: line)
            }
    }

    /// Books added before the app kept copies still point at the original file: copy it in once and remember that.
    static func keepCopy(of path: String, in folder: URL, meta: [String: Any]) -> String? {
        guard !path.hasPrefix(folder.path) else { return nil }
        let original = URL(fileURLWithPath: path)
        let copy = folder.appendingPathComponent("source.\(original.pathExtension.lowercased())")
        guard FileManager.default.fileExists(atPath: copy.path) || (try? FileManager.default.copyItem(at: original, to: copy)) != nil else { return nil }
        var updated = meta
        updated["path"] = copy.path
        updated["originalPath"] = path
        try? JSONSerialization.data(withJSONObject: updated).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        return copy.path
    }

    /// True while another pipeline run holds this book's lock (`.running` with a live process id).
    static func runningElsewhere(_ folder: URL) -> Bool {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(".running"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// The first item Pip is making right now, if any.
    static func working(_ book: Book?) -> (n: Int, item: String)? {
        for chapter in book?.chapters ?? [] {
            if let item = chapter.status.first(where: { $0.value == .working })?.key { return (chapter.n, item) }
        }
        return nil
    }

    /// book.json, or book-data.js from books made before the app existed.
    static func loadBook(_ folder: URL) -> Book? {
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

    private func added(_ folder: URL) -> Double {
        let meta = try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any]
        return meta?["addedAt"] as? Double ?? 0
    }

    // MARK: adding and preparing

    /// "You never press generate": on launch, carry on with any book that still has items to make.
    /// A book already being prepared elsewhere keeps its run (the pipeline's lock turns a second run away).
    func resumeUnfinished() {
        for entry in entries where runs[entry.id] == nil && !entry.preparing {
            guard let book = entry.book,
                  book.chapters.contains(where: { $0.status.values.contains { $0 == .todo || $0 == .working } }),
                  let meta = try? JSONSerialization.jsonObject(with: Data(contentsOf: entry.folder.appendingPathComponent("meta.json"))) as? [String: Any],
                  var path = meta["path"] as? String, FileManager.default.fileExists(atPath: path)
            else { continue }
            path = Self.keepCopy(of: path, in: entry.folder, meta: meta) ?? path
            let options = meta["options"] as? [String: Any]
            prepare(id: entry.id, book: URL(fileURLWithPath: path),
                    options: .init(media: options?["media"] as? String ?? "1-2", dryRun: options?["dryRun"] as? Bool ?? false))
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

    func prepareMore(_ id: String) {
        guard let meta = try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appendingPathComponent("\(id)/meta.json"))) as? [String: Any],
              let path = meta["path"] as? String else { return }
        prepare(id: id, book: URL(fileURLWithPath: path), options: .init(media: "all", retry: true))
    }

    private func prepare(id: String, book: URL, options: PipelineCommand.Options) {
        let out = Self.root.appendingPathComponent(id, isDirectory: true)
        let runner = PipelineRunner()
        runs[id] = runner
        do {
            try runner.start(arguments: PipelineCommand.arguments(book: book.path, out: out.path, options: options)) { [weak self] line in
                Task { @MainActor in self?.handle(id, line) }
            } onExit: { [weak self] code in
                Task { @MainActor in self?.finished(id, code: code) }
            }
        } catch {
            runs[id] = nil
            message = "Pip couldn't start preparing: \(error.localizedDescription)"
        }
    }

    private func handle(_ id: String, _ raw: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastLine = Self.describe(PipelineLine.parse(raw)) ?? entries[index].lastLine
        if case .made = PipelineLine.parse(raw) { entries[index].book = Self.loadBook(entries[index].folder) }
    }

    private func finished(_ id: String, code: Int32) {
        runs[id] = nil
        reload()
        message = code == 0 ? "“\(entry(id)?.title ?? "Your book")” is ready." : "Pip hit a snag preparing this book. Open it and choose Prepare more to try again."
    }

    /// Plain words for a progress line, for the book card.
    static func describe(_ line: PipelineLine) -> String? {
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

    static func itemName(_ item: String) -> String {
        ["study": "reading guide", "graph": "concept map", "quiz": "quiz", "cards": "flashcards",
         "mindmap": "mind map", "audio": "podcast", "video": "video"][item] ?? item
    }
}

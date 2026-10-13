// Running the book pipeline: book ids, its command line, and reading its progress lines
// (the "Pipeline CLI" contract in CLAUDE.md).

import Foundation

public enum PipelineLine: Equatable, Sendable {
    case added(chapter: Int)
    case made(chapter: Int, item: String)
    case fellBack(chapter: Int, item: String, to: String)
    case waiting(chapter: Int, item: String)
    case failed(chapter: Int, item: String, reason: String)
    case setup(String)
    case finished
    case note(String)

    public static func parse(_ raw: String) -> PipelineLine {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Book: ") { return .finished }
        if line.hasPrefix("setup:") { return .setup(line.dropFirst("setup:".count).trimmingCharacters(in: .whitespaces)) }
        if let m = line.firstMatch(of: /^added chapter (\d+):/) { return .added(chapter: Int(m.1)!) }
        if let m = line.firstMatch(of: /^✓ chapter (\d+) (\w+) \(/) { return .made(chapter: Int(m.1)!, item: String(m.2)) }
        if let m = line.firstMatch(of: /^↪ chapter (\d+) (\w+): .*making it with (.+)$/) {
            return .fellBack(chapter: Int(m.1)!, item: String(m.2), to: String(m.3))
        }
        if let m = line.firstMatch(of: /^… chapter (\d+) (\w+): .*limit reached/) { return .waiting(chapter: Int(m.1)!, item: String(m.2)) }
        if let m = line.firstMatch(of: /^✗ chapter (\d+) (\w+): (.*)$/) {
            return .failed(chapter: Int(m.1)!, item: String(m.2), reason: String(m.3))
        }
        return .note(line)
    }
}

public enum BookID {
    /// Book ids are folder names we create: lowercase letters, digits, and dashes only.
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 80 && id.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    public static func slug(_ text: String) -> String {
        var out = ""
        for c in text.lowercased() {
            if c.isASCII && (c.isLetter || c.isNumber) { out.append(c) } else if !out.hasSuffix("-") && !out.isEmpty { out.append("-") }
        }
        let trimmed = String(out.drop { $0 == "-" }.reversed().drop { $0 == "-" }.reversed()).prefix(60)
        return trimmed.isEmpty ? "book" : String(trimmed)
    }

    public static func unique(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

public enum PipelineCommand {
    public struct Options: Codable, Equatable, Sendable {
        /// Chapters to prepare (`--chapters`): "all", or the just-ahead window's "1-3" (`PrepWindow`).
        public var chapters: String
        /// Chapters that also get a podcast and video (`--media`).
        public var media: String
        public var dryRun: Bool
        public var retry: Bool
        /// Override the engine from ai.json for this run ("local" = make waiting items with your own AI now).
        public var engine: String?
        public init(chapters: String = "all", media: String = "1-2", dryRun: Bool = false, retry: Bool = false, engine: String? = nil) {
            (self.chapters, self.media, self.dryRun, self.retry, self.engine) = (chapters, media, dryRun, retry, engine)
        }

        /// A run for the chapters in `window`.
        public init(window: PrepWindow, dryRun: Bool = false, retry: Bool = false, engine: String? = nil) {
            self.init(chapters: window.chaptersSpec, media: window.mediaSpec, dryRun: dryRun, retry: retry, engine: engine)
        }
    }

    /// The pipeline's arguments. The engine, models, and voices come from the person's ai.json; keys come only
    /// from environment variables, never the command line.
    /// `title`: what the book is called, for its first run (the pipeline reads the app's copy, `source.pdf`, and names
    /// the book once, when it first splits it).
    public static func arguments(book: String, out: String, options: Options, title: String? = nil) -> [String] {
        var args = [book, "--out", out, "--no-open", "--chapters", options.chapters, "--media", options.media]
        if options.dryRun { args.append("--dry-run") }
        if options.retry { args.append("--retry") }
        if let engine = options.engine { args += ["--engine", engine] }
        if let title { args.append("--title=\(title)") }  // one argument, so a title like "-Draft" isn't read as a flag
        return args
    }

    /// What a new book is called, saved in its meta.json and passed on every run: the name the person gave it (an
    /// iPad's inbox sidecar), else its file's name. Never an inbox file's UUID; "Your book" when nothing fits.
    public static func bookTitle(given: String?, file: URL) -> String {
        let given = clean(given ?? "")
        if !given.isEmpty { return given }
        let stem = file.deletingPathExtension().lastPathComponent
        if UUID(uuidString: stem) != nil { return "Your book" }
        return title(forFile: file) ?? "Your book"
    }

    /// The title to pass on a later run, from meta.json: the saved `title`, else the original file's name, else nil
    /// (then the run keeps the name the pipeline saved). Never the book's folder name.
    public static func savedTitle(title: String?, originalPath: String?) -> String? {
        let saved = clean(title ?? "")
        if !saved.isEmpty { return saved }
        return originalPath.map { bookTitle(given: nil, file: URL(fileURLWithPath: $0)) }
    }

    /// A book's name from its file name: "Agents_guide.pdf" is "Agents guide". Nil when nothing is left.
    public static func title(forFile file: URL) -> String? {
        let name = clean(file.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "))
        return name.isEmpty ? nil : name
    }

    /// Invisible marks that can flip or hide text (bidi embeddings, overrides and isolates, direction marks, zero-width
    /// space, word joiner, byte-order mark). Zero-width (non-)joiners stay: emoji and some scripts need them.
    static let invisible: Set<UInt32> = Set(0x202A...0x202E).union(0x2066...0x2069).union([0x200B, 0x200E, 0x200F, 0x2060, 0xFEFF])

    /// One line of plain words: invisible marks and control characters gone, runs of space collapsed.
    static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !invisible.contains($0.value) })
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true })
            .joined(separator: " ")
    }
}

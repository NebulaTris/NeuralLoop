// Running the book pipeline: book ids, its command line, and reading its progress lines
// (the "Pipeline CLI" contract in CLAUDE.md; same rules as src-tauri/src/pipeline.rs and storage.rs).

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
        if line.hasPrefix("Study site:") { return .finished }
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
        public var media: String
        public var dryRun: Bool
        public var retry: Bool
        public init(media: String = "1-2", dryRun: Bool = false, retry: Bool = false) {
            (self.media, self.dryRun, self.retry) = (media, dryRun, retry)
        }
    }

    /// The pipeline's arguments. The engine, models, and voices come from the person's ai.json; keys come only
    /// from environment variables, never the command line.
    public static func arguments(book: String, out: String, options: Options) -> [String] {
        var args = [book, "--out", out, "--no-open", "--media", options.media]
        if options.dryRun { args.append("--dry-run") }
        if options.retry { args.append("--retry") }
        return args
    }
}

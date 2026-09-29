// When the app may start preparing a book on its own: there's work left, a limit has lifted, and the last run
// didn't end in a way that another automatic run can't fix.

import Foundation

/// How the last run of a book ended, remembered by the app.
public struct RunRecord: Codable, Equatable, Sendable {
    public var exitCode: Int32
    public var endedAt: Double       // Unix ms
    public var failuresInARow: Int
    public init(exitCode: Int32, endedAt: Double, failuresInARow: Int) {
        (self.exitCode, self.endedAt, self.failuresInARow) = (exitCode, endedAt, failuresInARow)
    }

    /// The record after a run ends with `code`.
    public static func after(_ previous: RunRecord?, code: Int32, now: Double) -> RunRecord {
        RunRecord(exitCode: code, endedAt: now, failuresInARow: code == 0 ? 0 : (previous?.failuresInARow ?? 0) + 1)
    }
}

public enum AutoResume {
    static let minuteMs = 60_000.0
    static let waitAfterOtherLimits = 6 * 60 * minuteMs

    /// Items still to make, or items waiting on a limit that has lifted: NotebookLM's live usage says it can make them
    /// again, or (for other AIs) six hours have passed since the log last changed.
    public static func hasWork(_ book: Book, usage: NotebookLMUsage?, logModified: Double, now: Double) -> Bool {
        if book.chapters.contains(where: { $0.status.values.contains { $0 == .todo || $0 == .working } }) { return true }
        let waiting = book.chapters.flatMap { c in c.status.filter { $0.value == .waiting }.map(\.key) }
        guard !waiting.isEmpty else { return false }
        if book.engine != "local", let usage, usage.known { return waiting.contains { usage.canMake($0) } }
        return now - logModified > waitAfterOtherLimits
    }

    /// Exit 2 (the book can't be read) and 3 (setup needed) wait until settings change; another automatic run would
    /// only fail the same way. Other failures back off: 5 minutes, doubling, up to 6 hours.
    public static func mayStart(after last: RunRecord?, settingsChangedAt: Double, now: Double) -> Bool {
        guard let last, last.exitCode != 0 else { return true }
        if last.exitCode == 2 || last.exitCode == 3 { return settingsChangedAt > last.endedAt }
        let wait = min(5 * minuteMs * pow(2, Double(max(last.failuresInARow - 1, 0))), waitAfterOtherLimits)
        return now - last.endedAt >= wait
    }
}

/// Files a book's data points at (media, chapters) must stay inside the book's folder.
public enum BookFiles {
    public static func url(_ relative: String, in folder: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let file = folder.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(root + "/") ? file : nil
    }
}

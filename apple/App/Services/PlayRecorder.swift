// Where what really played goes (spec 09). With the book open, its session keeps it (and ticks Listen & watch off
// at 85%). A podcast playing from the menu bar or the shelf with the book closed is gathered here and written to the
// book's progress.json every 15 seconds; the step ticks itself off there too, but only in an open chapter.

import Foundation
import NeuralLoopCore

@MainActor
final class PlayRecorder {
    static let shared = PlayRecorder()

    private final class Weak { weak var session: BookSession?; init(_ s: BookSession) { session = s } }
    private var sessions: [Weak] = []
    /// Played stretches for books that aren't open, by book folder and chapter, and each chapter's media lengths.
    private var pending: [URL: [Int: WatchProgress]] = [:]
    private var lengths: [URL: [Int: [WatchKind: Double]]] = [:]
    private var flushing: Task<Void, Never>?
    static let writeEvery: Duration = .seconds(15)

    /// An open book: what plays from now on goes straight to it, along with anything gathered while it was closed.
    func attach(_ session: BookSession) {
        sessions.removeAll { $0.session == nil || $0.session === session }
        sessions.append(Weak(session))
        let folder = session.entry.folder.standardizedFileURL
        if let gathered = pending.removeValue(forKey: folder) {
            for (n, played) in gathered { session.addWatching(n, played, lengths: lengths[folder]?[n] ?? [:]) }
        }
    }

    private func session(for folder: URL) -> BookSession? {
        sessions.removeAll { $0.session == nil }
        return sessions.first { $0.session?.entry.folder.standardizedFileURL == folder }?.session
    }

    func played(_ source: PlaySource, from: Double, to: Double, rate: Double, wallSeconds: Double, length: Double) {
        let folder = source.folder.standardizedFileURL
        if length > 0 { lengths[folder, default: [:]][source.n, default: [:]][source.kind] = length }
        if let session = session(for: folder) {
            session.recordPlay(source.n, source.kind, from: from, to: to, rate: rate, wallSeconds: wallSeconds, length: length)
            return
        }
        var watching = pending[folder]?[source.n] ?? WatchProgress()
        guard watching[source.kind].add(from: from, to: to, rate: rate, wallSeconds: wallSeconds) else { return }
        pending[folder, default: [:]][source.n] = watching
        let chapterLengths = lengths[folder]?[source.n] ?? [:]
        if Listening.isDone(watching, audioLength: chapterLengths[.audio], videoLength: chapterLengths[.video]) {
            flush()  // possibly enough already (with what's saved): write now rather than in 15 s
        } else if flushing == nil {
            flushing = Task { [weak self] in
                try? await Task.sleep(for: Self.writeEvery)
                self?.flushing = nil
                self?.flush()
            }
        }
    }

    /// Writes what was gathered into each closed book's progress.json (this device's own file), and ticks
    /// Listen & watch off where it's earned.
    func flush() {
        let gathered = pending
        pending = [:]
        for (folder, chapters) in gathered {
            if let session = session(for: folder) {  // it opened meanwhile
                for (n, played) in chapters { session.addWatching(n, played, lengths: lengths[folder]?[n] ?? [:]) }
                continue
            }
            let loaded = ProgressFile.loadMerged(from: folder)  // other devices' steps count toward what's open
            var progress = loaded.merged
            var chaptersOfBook: [Chapter]?  // read only when a step is earned (book.json can be large)
            for (n, played) in chapters {
                progress.addWatching(n, played)
                let known = lengths[folder]?[n] ?? [:]
                guard progress.loop[String(n)]?[Stage.prime.rawValue] == nil,
                      Listening.isDone(progress.watch[String(n)], audioLength: known[.audio], videoLength: known[.video]) else { continue }
                if chaptersOfBook == nil { chaptersOfBook = Library.loadBook(folder)?.chapters ?? [] }
                _ = Loop.completeIfOpen(&progress, chaptersOfBook ?? [], n, .prime, now: Date().timeIntervalSince1970 * 1000)
            }
            ProgressFile.save(progress, ownLog: loaded.own.log, to: folder)
        }
        if !gathered.isEmpty { DriveSync.shared.soon() }
    }
}

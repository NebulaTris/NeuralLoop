// One open book: its data, this device's progress (progress.json), and the study clock.

import Foundation
import NeuralLoopCore
import Observation

@MainActor @Observable
final class BookSession {
    let entry: BookEntry
    var book: Book
    var progress: StudyProgress
    private var clock: Timer?

    init(entry: BookEntry) {
        self.entry = entry
        self.book = entry.book ?? Library.loadBook(entry.folder) ?? BookSession.emptyBook
        let saved = try? Data(contentsOf: entry.folder.appendingPathComponent("progress.json"))
        self.progress = saved.flatMap { try? JSONDecoder().decode(StudyProgress.self, from: $0) } ?? StudyProgress()
    }

    static let emptyBook = try! JSONDecoder().decode(Book.self, from: Data(#"{"title":"Your book"}"#.utf8))

    func file(_ relative: String) -> URL { entry.folder.appendingPathComponent(relative) }

    func reloadBook() { if let fresh = Library.loadBook(entry.folder), fresh != book { book = fresh } }

    var now: Double { Date().timeIntervalSince1970 * 1000 }

    func complete(_ n: Int, _ stage: Stage) -> Bool {
        let closed = Loop.complete(&progress, n, stage, now: now)
        save()
        return closed
    }

    func review(_ id: String, _ rating: Rating) {
        progress.cards[id] = FSRS.grade(progress.cards[id], rating, now: now)
        progress.updatedAt = now
        save()
    }

    func remember(_ n: Int, _ stage: Stage) {
        progress.last = Resume(n: n, stage: stage.rawValue)
        progress.updatedAt = now
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: entry.folder.appendingPathComponent("progress.json"), options: .atomic)
    }

    /// Counts study time in 15-second ticks while the book is open and the app is in front.
    func startClock(isActive: @escaping @MainActor () -> Bool) {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, isActive() else { return }
                Activity.log(&self.progress, now: self.now, seconds: 15)
                self.save()
            }
        }
    }

    func stopClock() { clock?.invalidate() }
}

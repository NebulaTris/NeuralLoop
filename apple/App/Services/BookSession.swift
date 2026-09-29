// One open book: its data, this device's progress (progress.json), and the study clock.

import AppKit
import Foundation
import NeuralLoopCore
import Observation

@MainActor @Observable
final class BookSession {
    let entry: BookEntry
    var book: Book
    var progress: StudyProgress
    private var clock: Timer?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(entry: BookEntry) {
        self.entry = entry
        self.book = entry.book ?? Library.loadBook(entry.folder) ?? BookSession.emptyBook
        // An unreadable file is kept aside rather than overwritten by the first save.
        self.progress = ProgressFile.load(from: entry.folder)
    }

    /// True while this book's window is the one in front and the app is active (the study clock only counts then).
    var isActive = false

    static let emptyBook = try! JSONDecoder().decode(Book.self, from: Data(#"{"title":"Your book"}"#.utf8))

    /// A file the book points at, only if it's inside the book's folder.
    func file(_ relative: String) -> URL? { BookFiles.url(relative, in: entry.folder) }

    // Quiz, remake-from-memory, and book-map progress, in the same shapes the study site used.

    func quiz(_ n: Int) -> QuizProgress { QuizProgress(progress.quiz[String(n)]) }

    func setQuiz(_ n: Int, _ quiz: QuizProgress) {
        progress.quiz[String(n)] = quiz.json
        touch()
    }

    func remakeGuess(_ n: Int) -> String {
        if case .object(let saved)? = progress.remake[String(n)], case .string(let guess)? = saved["guess"] { return guess }
        return ""
    }

    func remakeBest(_ n: Int) -> Int {
        if case .object(let saved)? = progress.remake[String(n)], case .number(let best)? = saved["best"] { return Int(best) }
        return 0
    }

    func setRemake(_ n: Int, guess: String, best: Int? = nil) {
        progress.remake[String(n)] = .object(["guess": .string(guess), "best": .number(Double(best ?? remakeBest(n)))])
        touch()
    }

    /// Typing a remake draft saves a second after the last keystroke, not on every key.
    func setRemakeDraft(_ n: Int, guess: String) {
        guard guess != remakeGuess(n) else { return }
        progress.remake[String(n)] = .object(["guess": .string(guess), "best": .number(Double(remakeBest(n)))])
        progress.updatedAt = now
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.save() }
        }
    }

    func placeOnMap(_ placed: [String: Point], seen chapters: [Int]) {
        for (id, point) in placed { progress.mapPos[id] = [point.x, point.y] }
        progress.mapSeen = Array(Set(progress.mapSeen).union(chapters)).sorted()
        touch()
    }

    private func touch() {
        progress.updatedAt = now
        save()
    }

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

    func save() { ProgressFile.save(progress, to: entry.folder) }

    /// Counts study time in 15-second ticks while the book is open and in front (`isActive`, kept current by the view).
    func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive, NSApp.isActive else { return }
                Activity.log(&self.progress, now: self.now, seconds: 15)
                self.save()
            }
        }
    }

    func stopClock() { clock?.invalidate() }
}

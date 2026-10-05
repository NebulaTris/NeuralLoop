// One open book: its data, this device's progress (progress.json), and the study clock.

import Foundation
#if os(macOS)
import AppKit
#endif
import NeuralLoopCore
import Observation

@MainActor @Observable
final class BookSession {
    let entry: BookEntry
    var book: Book
    /// Progress from every device (this one plus others' files that sync brought in). Changes save to this device's
    /// file with only its own study time, so syncing never counts another device's minutes twice.
    var progress: StudyProgress
    @ObservationIgnored private var ownLog: [String: Double] = [:]
    private var clock: Timer?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// What other devices' files looked like when they were last merged in (see `catchUp`).
    @ObservationIgnored private var devicesSeen = ""
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    /// Posted after sync brings in another device's progress.
    static let progressArrived = Notification.Name("NeuralLoopProgressArrived")

    init(entry: BookEntry) {
        self.entry = entry
        self.book = entry.book ?? Library.loadBook(entry.folder) ?? BookSession.emptyBook
        // An unreadable file is kept aside rather than overwritten by the first save.
        devicesSeen = ProgressFile.devicesSignature(in: entry.folder)
        let loaded = ProgressFile.loadMerged(from: entry.folder)
        self.progress = loaded.merged
        self.ownLog = loaded.own.log
        PlayRecorder.shared.attach(self)  // what plays from the menu bar or shelf now comes here
        observer = NotificationCenter.default.addObserver(forName: Self.progressArrived, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUp() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Another device's progress arrived (sync wrote devices/<id>.json): merge it in, so what's on screen (and what
    /// this device saves next) includes it. Our own study time stays our own. Cheap when nothing changed.
    func catchUp() {
        let signature = ProgressFile.devicesSignature(in: entry.folder)
        guard signature != devicesSeen else { return }
        devicesSeen = signature
        var mine = progress  // includes anything not saved yet (a draft being typed)
        mine.log = ownLog
        let fresh = StudyProgress.merged([mine] + ProgressFile.others(in: entry.folder))
        if fresh != progress { progress = fresh }
    }

    /// True while this book's window is the one in front and the app is active (the study clock only counts then).
    var isActive = false

    static let emptyBook = try! JSONDecoder().decode(Book.self, from: Data(#"{"title":"Your book"}"#.utf8))

    /// A file the book points at, only if it's inside the book's folder.
    func file(_ relative: String) -> URL? { BookFiles.url(relative, in: entry.folder) }

    // Quiz, remake-from-memory, and book-map progress, in the same shapes the study site used.

    func quiz(_ n: Int) -> QuizProgress { QuizProgress(progress.quiz[String(n)]) }

    func setQuiz(_ n: Int, _ quiz: QuizProgress) {
        progress.setQuiz(String(n), quiz.json, now: now)
        save()
        if let chapter = chapter(n), AutoSteps.quizFinished(progress, chapter) { earn(n, .recall) }  // every question answered
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
        progress.setRemake(String(n), .object(["guess": .string(guess), "best": .number(Double(best ?? remakeBest(n)))]), now: now)
        save()
    }

    /// Typing a remake draft saves a second after the last keystroke, not on every key.
    func setRemakeDraft(_ n: Int, guess: String) {
        guard guess != remakeGuess(n) else { return }
        progress.setRemake(String(n), .object(["guess": .string(guess), "best": .number(Double(remakeBest(n)))]), now: now)
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.pendingSave = nil; self?.save() }
        }
    }

    func placeOnMap(_ placed: [String: Point], seen chapters: [Int]) {
        let time = now
        for (id, point) in placed { progress.setMapPos(id, [point.x, point.y], now: time) }
        let seen = Array(Set(progress.mapSeen).union(chapters)).sorted()
        guard !placed.isEmpty || seen != progress.mapSeen else { return }
        progress.mapSeen = seen
        progress.updatedAt = max(progress.updatedAt, time)
        save()
    }

    var now: Double { Date().timeIntervalSince1970 * 1000 }

    func complete(_ n: Int, _ stage: Stage) -> Bool {
        let closed = Loop.complete(&progress, n, stage, now: now)
        save()
        Library.studyMoved(in: entry.id)  // the chapters Pip prepares just ahead may move (spec 08)
        return closed
    }

    func review(_ id: String, _ rating: Rating) {
        progress.cards[id] = FSRS.grade(progress.cards[id], rating, now: now)
        progress.updatedAt = now
        save()
        if let n = id.split(separator: ":").first.flatMap({ Int($0) }), let chapter = chapter(n),
           AutoSteps.cardsAllSeen(progress, chapter) { earn(n, .space) }  // every card seen once
    }

    func remember(_ n: Int, _ stage: Stage) {
        let resume = Resume(n: n, stage: stage.rawValue)
        guard progress.last != resume else { return }
        progress.setLast(resume, now: now)
        save()
    }

    /// Saves this device's file. Changes you made (a review, a step, a quiz answer) reach your other devices a few
    /// seconds later (`syncSoon`); the study clock's ticks just ride along with the next sync.
    func save(syncSoon: Bool = true) {
        ProgressFile.save(progress, ownLog: ownLog, to: entry.folder)
        if syncSoon { DriveSync.shared.soon() }
    }

    /// Counts study time in 15-second ticks while the book is open and in front (`isActive`, kept current by the view).
    func startClock() {
        catchUp()  // the book is on screen (again): show the latest from every device
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.catchUp()  // another device's progress may have arrived
                guard self.isActive, Self.appIsActive else { return }
                // Study time isn't a change to merge by: the tick leaves updatedAt alone.
                let updatedAt = self.progress.updatedAt
                Activity.log(&self.progress, now: self.now, seconds: 15)
                self.progress.updatedAt = updatedAt
                self.ownLog[Activity.dayKey(self.now), default: 0] += 15
                self.save(syncSoon: false)
                #if os(macOS)
                Nudger.studying()  // studying counts as a visit: no silly nudges about time "away"
                #endif
            }
        }
    }

    func stopClock() {
        clock?.invalidate()
        flushTracking()
    }

    // MARK: steps that complete themselves (spec 09)

    /// A step the person just earned by doing it: the chapter view shows Pip's gentle "done" (or the loop-closed hug).
    struct Earned: Equatable {
        let n: Int
        let stage: Stage
        let closed: Bool
        let at: Double
    }
    var earned: Earned?

    /// Each chapter's podcast and video lengths, as the players report them.
    @ObservationIgnored private var lengths: [Int: [WatchKind: Double]] = [:]
    @ObservationIgnored private var lastTrackingSave = Date.distantPast
    @ObservationIgnored private var trackingSave: Task<Void, Never>?
    @ObservationIgnored private var trackingUnsaved = false
    /// Listening and reading are written at most this often while they're being tracked.
    static let trackingSaveEvery = 15.0

    func chapter(_ n: Int) -> Chapter? { book.chapters.first { $0.n == n } }

    /// Ticks a step off because the person really did it: only in an open chapter, only if it isn't done yet (never
    /// undoing anything), through `complete` like the button.
    func earn(_ n: Int, _ stage: Stage) {
        guard chapter(n) != nil, Loop.isUnlocked(progress, book.chapters, n), progress.loop[String(n)]?[stage.rawValue] == nil else { return }
        let closed = complete(n, stage)
        earned = Earned(n: n, stage: stage, closed: closed, at: now)
    }

    /// A believable stretch of the chapter's podcast or video played (see `PlayRecorder`).
    func recordPlay(_ n: Int, _ kind: WatchKind, from: Double, to: Double, rate: Double, wallSeconds: Double, length: Double) {
        if length > 0 { lengths[n, default: [:]][kind] = length }
        guard progress.recordPlay(n, kind, from: from, to: to, rate: rate, wallSeconds: wallSeconds) else { return }
        checkListening(n)
        saveTracking()
    }

    /// Stretches gathered while the book was closed.
    func addWatching(_ n: Int, _ played: WatchProgress, lengths known: [WatchKind: Double]) {
        lengths[n, default: [:]].merge(known.filter { $0.value > 0 }) { $1 }
        progress.addWatching(n, played)
        checkListening(n)
        saveTracking()
    }

    private func checkListening(_ n: Int) {
        let known = lengths[n] ?? [:]
        if Listening.isDone(progress.watch[String(n)], audioLength: known[.audio], videoLength: known[.video]) { earn(n, .prime) }
    }

    /// One reading tick for the pages on screen (`needs`: the seconds each page of the chapter needs).
    func creditReading(_ n: Int, visible: [Int], seconds: Double, needs: [Double], earning: Bool) {
        guard progress.creditReading(n, visible: visible, seconds: seconds, pageCount: needs.count, earning: earning) else { return }
        if ReadingCredit.progress(progress.reading[String(n)], needs: needs).done { earn(n, .read) }
        saveTracking()
    }

    /// A recall answer was checked (by the recall model or word matching): a real try counts as the Recall step.
    func recallChecked(_ n: Int, answer: String) {
        if AutoSteps.isRealAnswer(answer) { earn(n, .recall) }
    }

    /// Writes tracked listening and reading at most every 15 seconds (they change every second); like study time,
    /// they ride along with the next sync.
    private func saveTracking() {
        trackingUnsaved = true
        let wait = Self.trackingSaveEvery - Date().timeIntervalSince(lastTrackingSave)
        if wait <= 0 {
            flushTracking()
        } else if trackingSave == nil {
            trackingSave = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                if !Task.isCancelled { self?.flushTracking() }
            }
        }
    }

    /// Saves now if tracked listening or reading is waiting to be written (the book closing, say).
    func flushTracking() {
        trackingSave?.cancel()
        trackingSave = nil
        guard trackingUnsaved else { return }
        trackingUnsaved = false
        lastTrackingSave = Date()
        save(syncSoon: false)
    }

    /// The Mac also checks the app is in front; on the iPad the view's scene phase already says so (`isActive`).
    private static var appIsActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        true
        #endif
    }
}

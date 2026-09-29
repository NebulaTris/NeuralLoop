import Foundation
import Testing
@testable import NeuralLoopCore

func book(_ statuses: [[String: String]]) throws -> Book {
    let chapters = statuses.enumerated().map { i, s in ["n": i + 1, "title": "Chapter \(i + 1)", "status": s] as [String: Any] }
    return try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: ["title": "T", "chapters": chapters]))
}

@Test func aChapterBecomesStudyableWhenItsGuideIsDone() throws {
    let before = try book([["study": "working", "quiz": "todo"], ["study": "todo"]])
    let after = try book([["study": "done", "quiz": "working"], ["study": "todo"]])
    let news = BookNews.between(before, after)
    #expect(news.readyChapters.map(\.n) == [1] && !news.finished)
}

@Test func aBookFinishesWhenNothingIsLeftToMake() throws {
    let before = try book([["study": "done", "audio": "working"], ["study": "done", "video": "skipped"]])
    let after = try book([["study": "done", "audio": "done"], ["study": "done", "video": "skipped"]])
    #expect(BookNews.between(before, after).finished)
    #expect(!BookNews.between(after, after).finished && BookNews.between(after, after).readyChapters.isEmpty)
}

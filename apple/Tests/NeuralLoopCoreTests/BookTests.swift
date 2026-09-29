import Foundation
import Testing
@testable import NeuralLoopCore

/// The same fixture pipeline/tests/test_pipeline.py checks against what the pipeline writes.
let fixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("pipeline/tests/fixtures/book.json")

@Test func decodesWhatThePipelineWrites() throws {
    let book = try JSONDecoder().decode(Book.self, from: Data(contentsOf: fixture))
    #expect(book.title == "sample book" && book.chapters.count == 4 && book.engine == "local")
    let first = book.chapters[0]
    #expect(first.status["quiz"] == .done && first.quiz.count >= 2 && first.cards.count >= 3)
    #expect(first.read == .text(first.read.text ?? "") && first.read.text?.isEmpty == false)
    #expect(first.guide.first?.level == "deep" || first.guide.first?.level == "normal" || first.guide.first?.level == "skim")
    #expect(first.recall.first?.keyPoints.isEmpty == false)
    #expect(first.mindmap?.name.isEmpty == false && first.graph?.concepts.isEmpty == false)
    #expect(first.audio?.hasPrefix("media/") == true && first.transcript?.hasSuffix(".json") == true)
    #expect(first.explainer?.slides.first?.audio?.hasPrefix("media/") == true)
    #expect(book.chapters[2].status["quiz"] == .skipped && book.graph.nodes.isEmpty == false)
}

@Test func decodesAQuizQuestion() throws {
    let q = try JSONDecoder().decode(QuizQuestion.self, from: Data(#"{"q":"Why?","options":["a","b"],"a":1,"hint":"h","why":["x","y"]}"#.utf8))
    #expect(q.options[q.a] == "b" && q.why == ["x", "y"])
}

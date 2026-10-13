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

/// Books made before the app have book-data.js, as the old pipeline wrote it: `window.BOOK = <json>;` and a newline.
@Test func readsBookDataFromBooksMadeBeforeTheApp() throws {
    let json = try String(contentsOf: fixture, encoding: .utf8)
    let expected = try JSONDecoder().decode(Book.self, from: Data(json.utf8))
    #expect(Book.fromBookData("window.BOOK = " + json + ";\n") == expected)
    #expect(Book.fromBookData("  window.BOOK = {\"title\":\"Old\"}  ")?.title == "Old")  // no semicolon
    #expect(Book.fromBookData("{\"title\":\"Bare\"};")?.title == "Bare")
    #expect(Book.fromBookData("window.BOOK = ;") == nil)
    #expect(Book.fromBookData("alert(1)") == nil)
}

@Test func loadsBookJSONFirstThenBookData() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(Book.load(from: folder) == nil)
    try Data("window.BOOK = {\"title\":\"Old\"};\n".utf8).write(to: folder.appendingPathComponent("book-data.js"))
    #expect(Book.load(from: folder)?.title == "Old")
    try Data(#"{"title":"New"}"#.utf8).write(to: folder.appendingPathComponent("book.json"))
    #expect(Book.load(from: folder)?.title == "New")
    try Data("not json".utf8).write(to: folder.appendingPathComponent("book.json"))
    #expect(Book.load(from: folder) == nil)  // a broken book.json isn't covered up by an older book-data.js
}

@Test func decodesAQuizQuestion() throws {
    let q = try JSONDecoder().decode(QuizQuestion.self, from: Data(#"{"q":"Why?","options":["a","b"],"a":1,"hint":"h","why":["x","y"]}"#.utf8))
    #expect(q.options[q.a] == "b" && q.why == ["x", "y"])
}

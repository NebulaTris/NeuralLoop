import Testing
@testable import NeuralLoopCore

@Test func readsEveryProgressLine() {
    #expect(PipelineLine.parse("  ✓ chapter 1 quiz (12s)") == .made(chapter: 1, item: "quiz"))
    #expect(PipelineLine.parse("  ↪ chapter 2 audio: NotebookLM couldn't (limit); making it with Ollama") == .fellBack(chapter: 2, item: "audio", to: "Ollama"))
    #expect(PipelineLine.parse("  … chapter 3 video: Claude limit reached; will continue next run") == .waiting(chapter: 3, item: "video"))
    #expect(PipelineLine.parse("  ✗ chapter 4 cards: UnusableAnswer: nope") == .failed(chapter: 4, item: "cards", reason: "UnusableAnswer: nope"))
    #expect(PipelineLine.parse("  added chapter 5: Queues") == .added(chapter: 5))
    #expect(PipelineLine.parse("  setup: downloading qwen3:8b 50%") == .setup("downloading qwen3:8b 50%"))
    #expect(PipelineLine.parse("Study site: /tmp/book/index.html") == .finished)
    #expect(PipelineLine.parse("Making 7 items with Ollama, chapter by chapter.") == .note("Making 7 items with Ollama, chapter by chapter."))
}

@Test func bookIdsAreSafeFolderNames() {
    #expect(BookID.slug("Designing Data-Intensive Applications (2nd ed.)") == "designing-data-intensive-applications-2nd-ed")
    #expect(BookID.slug("!!!") == "book")
    #expect(BookID.isValid("my-book-2") && !BookID.isValid("../etc") && !BookID.isValid(""))
    #expect(BookID.unique(base: "caching", taken: ["caching", "caching-2"]) == "caching-3")
}

@Test func thePipelineCommandCarriesTheChoicesButNeverKeys() {
    let args = PipelineCommand.arguments(book: "/b/Caching.epub", out: "/lib/caching", options: .init(media: "1-2", dryRun: true, retry: false))
    #expect(args == ["/b/Caching.epub", "--out", "/lib/caching", "--no-open", "--media", "1-2", "--dry-run"])
    #expect(!args.joined(separator: " ").contains("KEY"))
}

@Test func aRunCanBeToldToUseMyAIForItemsThatAreWaiting() {
    let args = PipelineCommand.arguments(book: "/b.pdf", out: "/lib/b", options: .init(media: "1", retry: true, engine: "local"))
    #expect(args == ["/b.pdf", "--out", "/lib/b", "--no-open", "--media", "1", "--retry", "--engine", "local"])
}

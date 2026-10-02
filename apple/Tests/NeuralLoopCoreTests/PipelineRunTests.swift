import Foundation
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
    #expect(PipelineLine.parse("Book: /tmp/book") == .finished)
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

@Test func aNewBookIsNamedAfterItsFileNotTheAppsCopy() {
    // The pipeline reads the app's own copy (source.pdf), so the first run says what the book is called.
    let args = PipelineCommand.arguments(book: "/lib/agents-guide/source.pdf", out: "/lib/agents-guide", options: .init(),
                                         title: PipelineCommand.title(forFile: URL(fileURLWithPath: "/Users/me/Desktop/Agents_guide.pdf")))
    #expect(args.last == "--title=Agents guide")
    #expect(PipelineCommand.title(forFile: URL(fileURLWithPath: "/x/deep-learning--2nd_ed.epub")) == "deep learning 2nd ed")
    #expect(PipelineCommand.title(forFile: URL(fileURLWithPath: "/x/___.pdf")) == nil)
    #expect(!PipelineCommand.arguments(book: "/b.pdf", out: "/lib/b", options: .init()).contains { $0.hasPrefix("--title") })
}

@Test func aTitleStartingWithADashStaysOneArgument() {
    // "--title -Draft" would read "-Draft" as a flag; "--title=-Draft" can't be misread.
    let args = PipelineCommand.arguments(book: "/b.pdf", out: "/lib/b", options: .init(), title: "-Draft")
    #expect(args.last == "--title=-Draft")
    #expect(!args.contains("--title") && !args.contains("-Draft"))
}

@Test func aBookIsNamedAfterWhatThePersonCalledItNeverTheInboxFile() {
    let inbox = URL(fileURLWithPath: "/lib/inbox/3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f.pdf")
    #expect(PipelineCommand.bookTitle(given: "Designing Data-Intensive Applications", file: inbox) == "Designing Data-Intensive Applications")
    #expect(PipelineCommand.bookTitle(given: "  Caching\nnotes ", file: inbox) == "Caching notes")
    #expect(PipelineCommand.bookTitle(given: nil, file: inbox) == "Your book")
    #expect(PipelineCommand.bookTitle(given: "   ", file: inbox) == "Your book")
    #expect(PipelineCommand.bookTitle(given: nil, file: URL(fileURLWithPath: "/lib/inbox/3F2A9C1E-7B4D-4E8A-9C0F-1A2B3C4D5E6F.epub")) == "Your book")
    #expect(PipelineCommand.bookTitle(given: nil, file: URL(fileURLWithPath: "/Users/me/Desktop/Agents_guide.pdf")) == "Agents guide")
    #expect(PipelineCommand.bookTitle(given: nil, file: URL(fileURLWithPath: "/x/___.pdf")) == "Your book")
}

@Test func aRunCanBeToldToUseMyAIForItemsThatAreWaiting() {
    let args = PipelineCommand.arguments(book: "/b.pdf", out: "/lib/b", options: .init(media: "1", retry: true, engine: "local"))
    #expect(args == ["/b.pdf", "--out", "/lib/b", "--no-open", "--media", "1", "--retry", "--engine", "local"])
}

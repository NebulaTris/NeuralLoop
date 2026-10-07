import Testing
@testable import NeuralLoopCore

@Test func anAutomaticRunsProblemSaysWhatHelps() {
    #expect(RunProblemText.card(code: 2) == "Pip couldn't read this book. Try a different PDF or EPUB copy.")
    #expect(RunProblemText.card(code: 3) == "Pip needs a little setup first. Open Settings to sign in to Google or choose your AI.")
    #expect(RunProblemText.card(code: 1) == "Pip hit a snag. Open the book and choose Prepare more.")
    #expect(RunProblemText.card(code: -9) == RunProblemText.card(code: 1))
}

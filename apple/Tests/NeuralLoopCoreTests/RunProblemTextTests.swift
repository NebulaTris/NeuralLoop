import Testing
@testable import NeuralLoopCore

@Test func anAutomaticRunsProblemSaysWhatHelps() {
    #expect(RunProblemText.card(code: 2) == "Pip couldn't read this book. Try a different PDF or EPUB copy.")
    #expect(RunProblemText.card(code: 2, tail: ["This book couldn't be read: it isn't a valid EPUB (zip) file"])
        == RunProblemText.card(code: 2))
    #expect(RunProblemText.card(code: 3) == "Pip needs a little setup first. Open Settings to sign in to Google or choose your AI.")
    // Other failures back off and try again by themselves: nothing to press.
    #expect(RunProblemText.card(code: 1) == "Pip hit a snag and will try again on its own in a little while.")
    #expect(RunProblemText.card(code: -9) == RunProblemText.card(code: 1))
}

@Test func exitTwoThatIsntAboutTheBookItselfSaysSo() {
    // Another run already has the book: nothing is wrong with the file.
    let busy = RunProblemText.card(code: 2, tail: ["This book is already being prepared. Pip will keep going with that run."])
    #expect(busy == "Pip is already preparing this book in another run and will carry on there.")
    // The chapters asked for didn't make sense: preparing them all always does.
    for line in [#"Invalid chapter selection "1-x". Use forms like 1-3, 1,4,7, all, or none."#,
                 #"Invalid range "5-2": the first number must not be larger than the second."#] {
        #expect(RunProblemText.card(code: 2, tail: ["Splitting book.pdf into chapters…", line])
            == "Pip got mixed up about which chapters to prepare. Open the book and choose Prepare more to prepare them all.")
    }
}

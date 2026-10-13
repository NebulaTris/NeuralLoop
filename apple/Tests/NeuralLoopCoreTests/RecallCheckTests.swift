// Same rules as pipeline/neuralloop_books/recall.py.
import Testing
@testable import NeuralLoopCore

let points = ["the world keeps changing", "software is a snapshot", "you need monitoring"]

@Test func wordMatchingFindsMostOfAPointsWords() {
    #expect(RecallCheck.wordMatch(points, answer: "Software is a snapshot and you need monitoring.") == [false, true, true])
}

@Test func feedbackIsWarmAndNamesTheNextThing() {
    #expect(RecallCheck.feedback(points, covered: [true, false, false]).hasPrefix("Nice: you remembered that the world keeps changing."))
    #expect(RecallCheck.feedback(points, covered: [true, true, true]) == "You covered every key point. Lovely recall!")
    #expect(RecallCheck.feedback(points, covered: [false, false, false]) == "Good start. Next time, try to include that the world keeps changing.")
}

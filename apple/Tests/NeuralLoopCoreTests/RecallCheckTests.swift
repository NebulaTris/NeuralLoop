// Same rules as pipeline/neuralloop_books/recall.py.
import Testing
@testable import NeuralLoopCore

let points = ["the world keeps changing", "software is a snapshot", "you need monitoring"]

@Test func wordMatchingFindsMostOfAPointsWords() {
    #expect(RecallCheck.wordMatch(points, answer: "Software is a snapshot and you need monitoring.") == [false, true, true])
}

@Test func evidenceMustBeInTheAnswerAndAboutTheIdea() {
    let answer = "The world keeps changing but software is a frozen snapshot."
    #expect(RecallCheck.grounded("the world keeps changing", answer: answer, idea: points[0]))
    #expect(!RecallCheck.grounded("we monitor drift", answer: answer, idea: points[2]))            // not in the answer
    #expect(!RecallCheck.grounded("The world keeps changing", answer: answer, idea: points[2]))    // not about the idea
    #expect(RecallCheck.grounded("the answer clearly expresses that software is a snapshot", answer: answer, idea: points[1]))
}

@Test func feedbackIsWarmAndNamesTheNextThing() {
    #expect(RecallCheck.feedback(points, covered: [true, false, false]).hasPrefix("Nice: you remembered that the world keeps changing."))
    #expect(RecallCheck.feedback(points, covered: [true, true, true]) == "You covered every key point. Lovely recall!")
    #expect(RecallCheck.feedback(points, covered: [false, false, false]) == "Good start. Next time, try to include that the world keeps changing.")
}

@Test func readsAVerdictAndIgnoresJunk() {
    #expect(RecallCheck.verdict(from: #"{"covered": true, "evidence": "a snapshot"}"#)?.covered == true)
    #expect(RecallCheck.verdict(from: "not json") == nil)
    #expect(RecallCheck.verdict(from: #"{"covered": "yes"}"#) == nil)
}

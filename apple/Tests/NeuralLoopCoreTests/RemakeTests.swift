import Foundation
import Testing
@testable import NeuralLoopCore

private func tree(_ json: String) throws -> MindNode { try JSONDecoder().decode(MindNode.self, from: Data(json.utf8)) }

@Test func namesMatchAcrossWordFormsButNotUnrelatedWords() {
    #expect(Remake.namesMatch("caching strategy", "Caching strategies"))
    #expect(Remake.namesMatch("invalidation", "Cache invalidation"))
    #expect(!Remake.namesMatch("networking", "Cache invalidation"))
}

@Test func aSingleLetterDoesNotMatchEveryBranch() {
    #expect(!Remake.namesMatch("e", "Failure modes"))
    #expect(!Remake.namesMatch("mod", "Failure modes"))
    #expect(Remake.namesMatch("MCP", "mcp"))
}

@Test func remakingTheMapScoresBranchesAndSubIdeas() throws {
    let map = try tree(#"{"name":"Caching","children":[{"name":"Foundations","children":[{"name":"Key terms"}]},{"name":"Failure modes"}]}"#)
    let result = Remake.compare("Foundations\n- key terms\n", with: map)
    #expect(result.percent == 67 && result.rows[0].remembered && result.rows[0].children[0].remembered && !result.rows[1].remembered)
    #expect(Remake.compare("e", with: map).percent == 0)
}

@Test func recallScoreIsZeroToThree() {
    let scores: [Int] = [Remake.recallScore(covered: 0, total: 3), Remake.recallScore(covered: 2, total: 3), Remake.recallScore(covered: 1, total: 0)]
    #expect(scores == [0, 2, 0])
}

@Test func quizProgressReadsAndWritesTheSitesShape() throws {
    let saved = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"i":2,"results":[true,false]}"#.utf8))
    let quiz = QuizProgress(saved)
    #expect(quiz.i == 2 && quiz.results == [true, false] && quiz.right == 1)
    #expect(QuizProgress(quiz.json) == quiz && QuizProgress(nil) == QuizProgress())
    var great = QuizProgress()
    great.results = [true, true, true, true, false]
    #expect(great.isGreat(outOf: 5) && !quiz.isGreat(outOf: 5))
}

@Test func latexMathReadsAsPlainText() {
    #expect(PlainMath.clean("The $M \\times N$ problem") == "The M × N problem")
    #expect(PlainMath.clean("costs $5 and $6") == "costs $5 and $6")
    #expect(PlainMath.clean("$O(n \\cdot m)$ and \\text{fast}") == "O(n · m) and fast")
    #expect(PlainMath.clean("no math here") == "no math here")
}

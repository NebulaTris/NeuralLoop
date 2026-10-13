import Testing
@testable import NeuralLoopCore

@Test func onlyThePersonsSavedKeysReachThePipeline() {
    let inherited = ["PATH": "/usr/bin", "HOME": "/Users/sam",
                     "ANTHROPIC_API_KEY": "from-the-shell", "OPENAI_API_KEY": "from-the-shell",
                     "OPENROUTER_API_KEY": "from-the-shell", "NEURALLOOP_API_KEY": "from-the-shell",
                     "NEURALLOOP_BASE_URL": "http://shell.example", "NEURALLOOP_AI_CONFIG": "/tmp/other-ai.json"]
    let env = PipelineEnvironment.make(inherited: inherited, keys: ["OPENAI_API_KEY": "saved", "ANTHROPIC_API_KEY": ""],
                                       aiConfig: nil)
    #expect(env["OPENAI_API_KEY"] == "saved")
    // A key the person didn't save (or cleared) never comes from wherever the app was started.
    #expect(env["ANTHROPIC_API_KEY"] == nil)
    #expect(env["OPENROUTER_API_KEY"] == nil)
    #expect(env["NEURALLOOP_API_KEY"] == nil)
    #expect(env["NEURALLOOP_BASE_URL"] == nil)
    #expect(env["NEURALLOOP_AI_CONFIG"] == nil)
    #expect(env["PATH"] == "/usr/bin" && env["HOME"] == "/Users/sam")
    #expect(env["PYTHONUNBUFFERED"] == "1")
}

@Test func thePersonsAIConfigIsHandedOverWhenItExists() {
    let env = PipelineEnvironment.make(inherited: ["NEURALLOOP_AI_CONFIG": "/tmp/other.json"], keys: [:], aiConfig: "/Users/sam/ai.json")
    #expect(env["NEURALLOOP_AI_CONFIG"] == "/Users/sam/ai.json")
}

@Test func onlyKnownKeyNamesAreHandedOver() {
    let env = PipelineEnvironment.make(inherited: [:], keys: ["SOMETHING_ELSE": "x", "OPENROUTER_API_KEY": "or"], aiConfig: nil)
    #expect(env["SOMETHING_ELSE"] == nil)
    #expect(env["OPENROUTER_API_KEY"] == "or")
}

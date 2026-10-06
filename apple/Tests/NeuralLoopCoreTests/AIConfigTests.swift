import Foundation
import Testing
@testable import NeuralLoopCore

@Test func readsAndWritesTheSameAIJSONAsThePipeline() throws {
    let json = #"{"engine":"local","make":{"provider":"anthropic","model":"claude-opus-5"},"tasks":{"quiz":{"provider":"ollama","model":"qwen3:8b"}},"recall":{"provider":"ollama","model":"gemma2:2b"},"voices":["Aisha","Siya"],"voiceQuality":"best","audioLength":"short","hermesTools":true}"#
    let config = try JSONDecoder().decode(AIConfig.self, from: Data(json.utf8))
    #expect(config.engine == .local && config.make.provider == "anthropic" && config.tasks["quiz"]?.model == "qwen3:8b")
    #expect(config.voices == ["Aisha", "Siya"] && config.voiceQuality == .best && config.audioLength == .short && config.hermesTools)
    let again = try JSONDecoder().decode(AIConfig.self, from: JSONEncoder().encode(config))
    #expect(again == config)
}

@Test func anEmptyFileMeansTheOutOfTheBoxDefaults() throws {
    let config = try JSONDecoder().decode(AIConfig.self, from: Data("{}".utf8))
    #expect(config.engine == .auto && config.make.provider == "auto")
    #expect(config.recall == ModelChoice(provider: "ollama", model: "gemma2:2b"))
    #expect(config.voices == ["Ira", "Zoya"] && config.voiceQuality == .fast && config.audioLength == .auto && !config.hermesTools)
}

@Test func lmStudioIsAnOpenAICompatibleAddressOnThisMac() {
    let lm = ProviderPreset.named("lmstudio")!
    #expect(lm.choice(model: "qwen2.5-7b-instruct") == ModelChoice(provider: "custom", model: "qwen2.5-7b-instruct", baseUrl: "http://localhost:1234/v1"))
    #expect(ProviderPreset.matching(ModelChoice(provider: "custom", baseUrl: "http://localhost:1234/v1"))?.id == "lmstudio")
    #expect(ProviderPreset.matching(ModelChoice(provider: "custom", baseUrl: "https://api.together.xyz/v1"))?.id == "custom")
    // The pipeline adds /v1 and a scheme when they're missing, so these are all LM Studio too.
    for address in ["http://127.0.0.1:1234/v1", "http://localhost:1234", "http://localhost:1234/v1/", "localhost:1234"] {
        #expect(ProviderPreset.matching(ModelChoice(provider: "custom", baseUrl: address))?.id == "lmstudio", "\(address)")
    }
    #expect(ProviderPreset.matching(ModelChoice(provider: "custom", baseUrl: "http://localhost:8000/v1"))?.id == "custom")
    // Left empty, the pipeline uses the model loaded in LM Studio.
    #expect(lm.choice(model: nil).model == nil)
}

@Test func defaultModelsMatchThePipeline() {
    // pipeline/neuralloop_books/config.py DEFAULT_MODELS
    #expect(ProviderPreset.named("anthropic")?.defaultModel == "claude-opus-5-5")
    #expect(ProviderPreset.named("openai")?.defaultModel == "gpt-6-sol")
    #expect(ProviderPreset.named("openrouter")?.defaultModel == "deepseek/deepseek-v4.1-flash")
    #expect(ProviderPreset.named("anthropic")?.suggestions.first == "claude-opus-5-5")
}

@Test func eachProviderSaysWhichKeyItNeeds() {
    #expect(ProviderPreset.named("anthropic")?.keyVariable == "ANTHROPIC_API_KEY")
    #expect(ProviderPreset.named("openai")?.keyVariable == "OPENAI_API_KEY")
    #expect(ProviderPreset.named("openrouter")?.keyVariable == "OPENROUTER_API_KEY")
    #expect(ProviderPreset.named("custom")?.keyVariable == "NEURALLOOP_API_KEY" && ProviderPreset.named("custom")?.keyOptional == true)
    #expect(ProviderPreset.named("ollama")?.keyVariable == nil && ProviderPreset.named("opencode")?.keyVariable == nil)
    #expect(ProviderPreset.all.map(\.id) == ["ollama", "lmstudio", "anthropic", "openai", "openrouter", "opencode", "hermes", "custom"])
}

@Test func readsTheAICheckReport() throws {
    let line = #"AI check: {"make": {"ok": true, "provider": "ollama", "name": "Ollama", "model": "qwen3:8b", "seconds": 17.9}, "recall": {"ok": false, "provider": "anthropic", "message": "No key for anthropic."}}"#
    let report = try #require(AICheck.parse(line))
    #expect(report["make"]?.ok == true && report["make"]?.model == "qwen3:8b" && report["recall"]?.message == "No key for anthropic.")
    #expect(AICheck.parse("something else") == nil)
}

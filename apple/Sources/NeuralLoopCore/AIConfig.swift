// The person's AI choices (ai.json, the same file the pipeline reads through --ai-config), the providers Settings
// offers, and the report from `--check-ai` (Save and test). Keys never live here: they're in the Keychain.

import Foundation

public enum Engine: String, Codable, CaseIterable, Sendable {
    case auto, notebooklm, local

    public var title: String {
        switch self {
        case .auto: "NotebookLM first, my AI whenever it can't"
        case .notebooklm: "Only NotebookLM"
        case .local: "Only my AI"
        }
    }
}

public enum VoiceQuality: String, Codable, Sendable { case fast, best }

/// How long podcasts are. "auto" makes short ones for short chapters (they're quicker to make, too).
public enum AudioLength: String, Codable, Sendable, CaseIterable { case auto, short, `default`, long }

public struct ModelChoice: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String?
    public var baseUrl: String?
    public init(provider: String, model: String? = nil, baseUrl: String? = nil) {
        (self.provider, self.model, self.baseUrl) = (provider, model, baseUrl)
    }
}

public struct AIConfig: Codable, Equatable, Sendable {
    public var engine: Engine = .auto
    public var make = ModelChoice(provider: "auto")
    public var tasks: [String: ModelChoice] = [:]
    public var recall = ModelChoice(provider: "ollama", model: "gemma2:2b")
    public var voices = ["Ira", "Zoya"]
    public var voiceQuality: VoiceQuality = .fast
    public var audioLength: AudioLength = .auto
    /// Hermes Agent can act on this Mac with its own tools; book text could steer it. Off unless the person turns it on.
    public var hermesTools = false

    public init() {}

    enum CodingKeys: String, CodingKey { case engine, make, tasks, recall, voices, voiceQuality, audioLength, hermesTools }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AIConfig()
        engine = (try? c.decodeIfPresent(Engine.self, forKey: .engine)) ?? d.engine
        make = (try? c.decodeIfPresent(ModelChoice.self, forKey: .make)) ?? d.make
        tasks = (try? c.decodeIfPresent([String: ModelChoice].self, forKey: .tasks)) ?? d.tasks
        recall = (try? c.decodeIfPresent(ModelChoice.self, forKey: .recall)) ?? d.recall
        let v = (try? c.decodeIfPresent([String].self, forKey: .voices)) ?? d.voices
        voices = v.count == 2 ? v : d.voices
        voiceQuality = (try? c.decodeIfPresent(VoiceQuality.self, forKey: .voiceQuality)) ?? d.voiceQuality
        audioLength = (try? c.decodeIfPresent(AudioLength.self, forKey: .audioLength)) ?? d.audioLength
        hermesTools = (try? c.decodeIfPresent(Bool.self, forKey: .hermesTools)) ?? false
    }
}

/// A provider as Settings shows it. Several presets can map to one pipeline provider (LM Studio is "custom").
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let provider: String
    public let keyVariable: String?
    public let keyOptional: Bool
    public let defaultModel: String
    public let baseUrl: String?
    public let suggestions: [String]

    public func choice(model: String?, baseUrl override: String? = nil) -> ModelChoice {
        ModelChoice(provider: provider, model: (model?.isEmpty ?? true) ? (defaultModel.isEmpty ? nil : defaultModel) : model,
                    baseUrl: override ?? baseUrl)
    }

    public static let all: [ProviderPreset] = [
        .init(id: "ollama", title: "Ollama", detail: "Free and private, on this Mac. Leave the model empty to use the one NeuralLoop set up.",
              provider: "ollama", keyVariable: nil, keyOptional: false, defaultModel: "", baseUrl: nil,
              suggestions: ["qwen3:8b", "qwen3:4b", "gemma2:2b", "gpt-oss:20b"]),
        .init(id: "lmstudio", title: "LM Studio", detail: "Any model you load in LM Studio. Start its local server (Developer → Start Server).",
              provider: "custom", keyVariable: "NEURALLOOP_API_KEY", keyOptional: true, defaultModel: "", baseUrl: "http://localhost:1234/v1",
              suggestions: []),
        .init(id: "anthropic", title: "Claude (Anthropic)", detail: "Your Anthropic API key.",
              provider: "anthropic", keyVariable: "ANTHROPIC_API_KEY", keyOptional: false, defaultModel: "claude-opus-5", baseUrl: nil,
              suggestions: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]),
        .init(id: "openai", title: "OpenAI", detail: "Your OpenAI API key.",
              provider: "openai", keyVariable: "OPENAI_API_KEY", keyOptional: false, defaultModel: "gpt-6-sol", baseUrl: nil,
              suggestions: ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]),
        .init(id: "openrouter", title: "OpenRouter", detail: "One key for hundreds of models, including DeepSeek, Qwen, Llama, and Hermes.",
              provider: "openrouter", keyVariable: "OPENROUTER_API_KEY", keyOptional: false, defaultModel: "deepseek/deepseek-v4.1-flash", baseUrl: nil,
              suggestions: ["deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4-pro-0813"]),
        .init(id: "opencode", title: "opencode", detail: "Uses the model you've chosen in opencode. Type one to override it, for example deepseek/deepseek-v4-pro.",
              provider: "opencode", keyVariable: nil, keyOptional: false, defaultModel: "", baseUrl: nil,
              suggestions: ["deepseek/deepseek-v4-pro", "anthropic/claude-sonnet-5"]),
        .init(id: "hermes", title: "Hermes Agent", detail: "Nous Research's Hermes Agent, as you've set it up (hermes setup). It's an agent: if its tools are on, text in a book could steer it, so turn its tools off in Hermes first.",
              provider: "hermes", keyVariable: nil, keyOptional: false, defaultModel: "", baseUrl: nil, suggestions: []),
        .init(id: "custom", title: "Any OpenAI-compatible service", detail: "Together, Groq, vLLM, a server of your own: its address, model, and key if it needs one.",
              provider: "custom", keyVariable: "NEURALLOOP_API_KEY", keyOptional: true, defaultModel: "", baseUrl: nil, suggestions: []),
    ]

    public static func named(_ id: String) -> ProviderPreset? { all.first { $0.id == id } }

    /// Which preset a saved choice came from.
    public static func matching(_ choice: ModelChoice) -> ProviderPreset? {
        if choice.provider == "custom" {
            return choice.baseUrl == named("lmstudio")?.baseUrl ? named("lmstudio") : named("custom")
        }
        return all.first { $0.provider == choice.provider }
    }
}

/// `--check-ai`'s report: one entry per role ("make", "task:quiz", "recall").
public struct AICheck: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let provider: String?
    public let name: String?
    public let model: String?
    public let seconds: Double?
    public let message: String?

    public static func parse(_ line: String) -> [String: AICheck]? {
        guard line.hasPrefix("AI check: ") else { return nil }
        return try? JSONDecoder().decode([String: AICheck].self, from: Data(line.dropFirst("AI check: ".count).utf8))
    }
}

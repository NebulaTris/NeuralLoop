// The pipeline's environment: what the app was started with, minus any provider keys, AI address, or ai.json path
// that came along from a shell or launcher, plus the person's own saved keys and ai.json. So a run only ever uses
// what the person chose in Settings.

public enum PipelineEnvironment {
    /// The provider keys the person can save in Settings (kept in the Keychain).
    public static let keyNames = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "NEURALLOOP_API_KEY"]

    /// Never inherited: the keys, the custom server's address (ai.json carries the person's), another ai.json, and what
    /// the Anthropic and OpenAI SDKs read from the environment on their own (an address, a token, an organization or
    /// project, extra headers), which would send chapters, or the person's key, somewhere they didn't choose.
    public static let neverInherited = keyNames + [
        "NEURALLOOP_BASE_URL", "NEURALLOOP_AI_CONFIG",
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_URL", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_PROFILE",
        "OPENAI_BASE_URL", "OPENAI_API_BASE", "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "OPENAI_PROJECT_ID",
        "OPENAI_CUSTOM_HEADERS", "OPENAI_ADMIN_KEY", "OPENROUTER_BASE_URL",
    ]

    /// Every other setting under these names is left behind too: newer SDKs keep adding their own (profiles, workload
    /// identity, Azure), and the pipeline needs none of them.
    public static let neverInheritedPrefixes = ["ANTHROPIC_", "OPENAI_", "OPENROUTER_", "AZURE_OPENAI_"]

    public static func make(inherited: [String: String], keys: [String: String], aiConfig: String?) -> [String: String] {
        var env = inherited
        for name in neverInherited { env[name] = nil }
        env = env.filter { name, _ in !neverInheritedPrefixes.contains { name.hasPrefix($0) } }
        env["PYTHONUNBUFFERED"] = "1"
        if let aiConfig { env["NEURALLOOP_AI_CONFIG"] = aiConfig }
        for name in keyNames {
            if let key = keys[name], !key.isEmpty { env[name] = key }
        }
        return env
    }
}

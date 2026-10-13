// The pipeline's environment: what the app was started with, minus any provider keys, AI address, or ai.json path
// that came along from a shell or launcher, plus the person's own saved keys and ai.json. So a run only ever uses
// what the person chose in Settings.

public enum PipelineEnvironment {
    /// The provider keys the person can save in Settings (kept in the Keychain).
    public static let keyNames = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "NEURALLOOP_API_KEY"]

    /// Never inherited: the keys, the custom server's address (ai.json carries the person's), and another ai.json.
    public static let neverInherited = keyNames + ["NEURALLOOP_BASE_URL", "NEURALLOOP_AI_CONFIG"]

    public static func make(inherited: [String: String], keys: [String: String], aiConfig: String?) -> [String: String] {
        var env = inherited
        for name in neverInherited { env[name] = nil }
        env["PYTHONUNBUFFERED"] = "1"
        if let aiConfig { env["NEURALLOOP_AI_CONFIG"] = aiConfig }
        for name in keyNames {
            if let key = keys[name], !key.isEmpty { env[name] = key }
        }
        return env
    }
}

// Settings: the person's AI choices (ai.json), their keys (Keychain), their Google account, and Save and test.

import Foundation
import NeuralLoopCore
import Observation

@MainActor @Observable
final class AISettings {
    var config = AIConfig()
    var keys: [String: String] = [:]
    /// What the Keychain holds, so Settings can tell a saved key from one that's only typed.
    private(set) var savedKeys: [String: String] = [:]
    var keyNote = ""
    var account: (signedIn: Bool, email: String) = (false, "")
    var checking = false
    var check: [String: AICheck] = [:]
    var checkNote = ""
    var signingIn = false
    var accountNote = ""

    /// Items the pipeline makes, in the order Settings lists them for per-item models.
    static let items: [(id: String, name: String)] = [
        ("study", "Reading guide and recall questions"), ("graph", "Concept map"), ("quiz", "Quiz"),
        ("cards", "Flashcards"), ("mindmap", "Mind map"), ("audio", "Podcast script"), ("video", "Explainer"),
    ]

    init() {
        if let data = try? Data(contentsOf: PipelineRunner.aiConfigURL), let saved = try? JSONDecoder().decode(AIConfig.self, from: data) {
            config = saved
        }
        for name in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "NEURALLOOP_API_KEY"] {
            keys[name] = Keychain.read(name) ?? ""
        }
        savedKeys = keys
    }

    /// When the person last changed their AI settings or keys; automatic runs that needed setup wait for this.
    static var changedAt: Double {
        get { UserDefaults.standard.double(forKey: "settingsChangedAt") }
        set { UserDefaults.standard.set(newValue, forKey: "settingsChangedAt") }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: PipelineRunner.aiConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(config).write(to: PipelineRunner.aiConfigURL, options: .atomic)
        var problems: [String] = []
        for (name, value) in keys where value != savedKeys[name] {
            if let problem = Keychain.save(name, value) { problems.append(problem) } else { savedKeys[name] = value }
        }
        keyNote = problems.joined(separator: " ")
        Self.changedAt = Date().timeIntervalSince1970 * 1000
    }

    func isSaved(_ variable: String) -> Bool { !(keys[variable] ?? "").isEmpty && keys[variable] == savedKeys[variable] }

    /// Save, then try every configured model once (`--check-ai`).
    func saveAndTest() async {
        save()
        checking = true
        checkNote = ""
        let (_, lines) = await PipelineRunner.once(["--check-ai"], timeout: .seconds(900))
        check = lines.compactMap(AICheck.parse).first ?? [:]
        if check.isEmpty { checkNote = lines.last ?? "Pip couldn't run the check." }
        checking = false
    }

    func refreshAccount() async {
        let (_, lines) = await PipelineRunner.once(["--account"], timeout: .seconds(60))
        if let line = lines.first(where: { $0.hasPrefix("Account: ") }),
           let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst("Account: ".count).utf8)) as? [String: Any] {
            account = (object["signedIn"] as? Bool ?? false, object["email"] as? String ?? "")
        }
    }

    /// Opens a real browser window for Google sign-in; the same session is what NotebookLM uses.
    func signIn() async {
        signingIn = true
        accountNote = "A browser window is opening. Sign in to Google there, then come back."
        let (code, lines) = await PipelineRunner.once(["--signin"], timeout: .seconds(900))
        accountNote = code == 0 ? "" : (lines.last ?? "Sign-in didn't finish. You can try again any time.")
        signingIn = false
        await refreshAccount()
    }

    func signOut() async {
        _ = await PipelineRunner.once(["--signout"])
        await refreshAccount()
    }
}

// Settings (⌘,): Account (Google), Your AI (engine, models, keys, Save and test), and Voices.

import NeuralLoopCore
import SwiftUI

struct SettingsView: View {
    @Environment(AISettings.self) private var settings

    var body: some View {
        TabView {
            AccountTab().tabItem { Label("Account", systemImage: "person.crop.circle") }
            AITab().tabItem { Label("Your AI", systemImage: "cpu") }
            VoicesTab().tabItem { Label("Voices", systemImage: "waveform") }
        }
        .frame(width: 720, height: 640)
        .tint(Theme.accent)
        .task { await settings.refreshAccount() }
    }
}

// MARK: Account

struct AccountTab: View {
    @Environment(AISettings.self) private var settings

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    PipView(pose: settings.account.signedIn ? .proud : .read, size: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.account.signedIn ? "Signed in with Google" : "Not signed in").font(Theme.display(18))
                        Text(settings.account.signedIn ? settings.account.email : "Sign in so NotebookLM can prepare your books. Without it, Pip uses your own AI.")
                            .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                    if settings.account.signedIn {
                        Button("Sign out") { Task { await settings.signOut() } }
                    } else {
                        Button("Sign in with Google") { Task { await settings.signIn() } }
                            .buttonStyle(.borderedProminent).disabled(settings.signingIn)
                    }
                }
                if !settings.accountNote.isEmpty { Text(settings.accountNote).font(Theme.body(12)).foregroundStyle(Theme.ink2) }
            } header: { Text("Google") } footer: {
                Text("Sign-in happens in a real browser window (Chrome when you have it). That same session is what NotebookLM uses; Pip never sees your password.")
            }
            Section("Your library on every device") {
                Label("Syncing your library through your Google Drive comes next. It needs NeuralLoop's Google sign-in ID, a one-time setup (docs/specs/07-every-device.md).",
                      systemImage: "icloud.and.arrow.up").font(Theme.body(13)).foregroundStyle(Theme.ink2)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Your AI

struct AITab: View {
    @Environment(AISettings.self) private var settings
    @State private var showItems = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Who prepares your books", selection: $settings.config.engine) {
                    ForEach(Engine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: { Text("Engine") } footer: {
                Text("NotebookLM makes wonderful podcasts. When it's not signed in, busy, or out of daily uses, your AI makes that item instead, so a book always gets finished.")
            }

            ModelSection(title: "Your AI", footer: "Writes reading guides, quizzes, flashcards, maps, podcast scripts, and explainers.",
                         choice: $settings.config.make, keys: $settings.keys)

            Section {
                DisclosureGroup("Use a different model for some items", isExpanded: $showItems) {
                    ForEach(AISettings.items, id: \.id) { item in
                        ItemOverride(name: item.name, id: item.id)
                    }
                }
            }

            ModelSection(title: "Recall checker", footer: "Checks your own-words answers, one key point at a time. A small open model on your Mac is quick and private.",
                         choice: $settings.config.recall, keys: $settings.keys)

            Section {
                HStack {
                    Button(settings.checking ? "Testing…" : "Save and test") { Task { await settings.saveAndTest() } }
                        .buttonStyle(.borderedProminent).disabled(settings.checking)
                    if settings.checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Save") { settings.save() }
                }
                ForEach(settings.check.keys.sorted(), id: \.self) { role in
                    if let result = settings.check[role] { CheckRow(role: role, result: result) }
                }
                if !settings.checkNote.isEmpty { Text(settings.checkNote).font(Theme.body(12)).foregroundStyle(Theme.ink2) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Provider, model, address, and key for one role.
struct ModelSection: View {
    let title: String
    let footer: String
    @Binding var choice: ModelChoice
    @Binding var keys: [String: String]

    var body: some View {
        let preset = ProviderPreset.matching(choice) ?? ProviderPreset.named("ollama")!
        Section {
            Picker("Provider", selection: Binding(
                get: { choice.provider == "auto" ? "auto" : preset.id },
                set: { id in
                    if id == "auto" { choice = ModelChoice(provider: "auto") }
                    else if let p = ProviderPreset.named(id) { choice = p.choice(model: nil) }
                })) {
                Text("Automatic (your key if you add one, otherwise Ollama)").tag("auto")
                ForEach(ProviderPreset.all) { Text($0.title).tag($0.id) }
            }
            if choice.provider != "auto" {
                Text(preset.detail).font(Theme.body(12)).foregroundStyle(Theme.ink2)
                HStack {
                    TextField("Model", text: Binding(get: { choice.model ?? "" }, set: { choice.model = $0.isEmpty ? nil : $0 }),
                              prompt: Text(preset.defaultModel.isEmpty ? "the one NeuralLoop set up" : preset.defaultModel))
                    if !preset.suggestions.isEmpty {
                        Menu("Suggestions") {
                            ForEach(preset.suggestions, id: \.self) { m in Button(m) { choice.model = m } }
                        }
                        .fixedSize()
                    }
                }
                if preset.provider == "custom" {
                    TextField("Address", text: Binding(get: { choice.baseUrl ?? "" }, set: { choice.baseUrl = $0.isEmpty ? nil : $0 }),
                              prompt: Text("https://…/v1"))
                }
                if let variable = preset.keyVariable {
                    SecureField(preset.keyOptional ? "API key (if it needs one)" : "API key", text: Binding(
                        get: { keys[variable] ?? "" }, set: { keys[variable] = $0 }))
                    Text("Stored in your Mac's Keychain. It's only ever passed to Pip's engine, never saved in a file.")
                        .font(Theme.body(11)).foregroundStyle(Theme.ink3)
                }
            }
        } header: { Text(title) } footer: { Text(footer) }
    }
}

struct ItemOverride: View {
    @Environment(AISettings.self) private var settings
    let name: String
    let id: String

    var body: some View {
        @Bindable var settings = settings
        HStack {
            Text(name).frame(width: 220, alignment: .leading)
            Picker("", selection: Binding(
                get: { settings.config.tasks[id].flatMap(ProviderPreset.matching)?.id ?? "same" },
                set: { value in settings.config.tasks[id] = value == "same" ? nil : ProviderPreset.named(value)?.choice(model: nil) })) {
                Text("Same as your AI").tag("same")
                ForEach(ProviderPreset.all) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            if settings.config.tasks[id] != nil {
                TextField("Model", text: Binding(get: { settings.config.tasks[id]?.model ?? "" },
                                                 set: { settings.config.tasks[id]?.model = $0.isEmpty ? nil : $0 }))
                    .frame(width: 180)
            }
        }
    }
}

struct CheckRow: View {
    let role: String
    let result: AICheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(result.ok ? Theme.mint : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.body(13)).bold()
                Text(result.ok ? "\(result.name ?? "") \(result.model ?? "") answered in \(String(format: "%.1f", result.seconds ?? 0)) s"
                                : (result.message ?? "Didn't answer."))
                    .font(Theme.body(12)).foregroundStyle(Theme.ink2)
            }
        }
    }

    private var label: String {
        if role == "make" { return "Your AI" }
        if role == "recall" { return "Recall checker" }
        let id = role.replacingOccurrences(of: "task:", with: "")
        return AISettings.items.first { $0.id == id }?.name ?? id
    }
}

// MARK: Voices

struct VoicesTab: View {
    @Environment(AISettings.self) private var settings
    private let voices = ["Ira", "Aisha", "Siya", "Zoya"]

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Voice quality", selection: $settings.config.voiceQuality) {
                    Text("Fast (about twice as quick)").tag(VoiceQuality.fast)
                    Text("Best").tag(VoiceQuality.best)
                }
                .pickerStyle(.segmented)
            } header: { Text("Rumik voices") } footer: {
                Text("Rumik OSS-1 runs on your Mac. Its license allows personal, non-commercial use.")
            }
            Section("Podcast hosts") {
                Picker("Host who asks", selection: Binding(get: { settings.config.voices[0] }, set: { settings.config.voices[0] = $0 })) {
                    ForEach(voices, id: \.self) { Text($0).tag($0) }
                }
                Picker("Host who explains (and narrates explainers)", selection: Binding(get: { settings.config.voices[1] }, set: { settings.config.voices[1] = $0 })) {
                    ForEach(voices, id: \.self) { Text($0).tag($0) }
                }
            }
            Section { Button("Save") { settings.save() }.buttonStyle(.borderedProminent) }
        }
        .formStyle(.grouped)
    }
}

// MARK: Welcome

/// First launch: sign in with Google for NotebookLM, or carry on with Pip's own AI.
struct WelcomeView: View {
    @Environment(AISettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            PipView(pose: .hop, size: 170)
            Text("Hi, I'm Pip!").font(Theme.display(30))
            Text("Drop in a book and I'll turn every chapter into a small learning loop: listen, read, recall, map, remember.")
                .font(Theme.body(15)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
            Text("Sign in with Google and NotebookLM makes the podcasts and quizzes. Not now? I'll use a free AI right here on your Mac.")
                .font(Theme.body(13)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center).frame(maxWidth: 420)
            if settings.account.signedIn {
                Label("You're signed in as \(settings.account.email)", systemImage: "checkmark.circle.fill")
                    .font(Theme.body(14)).foregroundStyle(Theme.mint)
                Button("Let's go") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                HStack {
                    Button("Not now") { dismiss() }
                    Button("Sign in with Google") { Task { await settings.signIn(); if settings.account.signedIn { dismiss() } } }
                        .buttonStyle(.borderedProminent).disabled(settings.signingIn)
                }
            }
            if !settings.accountNote.isEmpty { Text(settings.accountNote).font(Theme.body(12)).foregroundStyle(Theme.ink2) }
        }
        .padding(40)
        .frame(width: 520)
        .tint(Theme.accent)
        .task { await settings.refreshAccount() }
    }
}

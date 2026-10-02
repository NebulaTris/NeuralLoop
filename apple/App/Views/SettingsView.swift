// Settings (⌘,): a warm, NeuralLoop-styled window with a sidebar — Account, Your AI, Voices, Nudges.

import NeuralLoopCore
import SwiftUI

/// A titled card, the building block of every settings page.
struct SettingsCard<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.display(17)).foregroundStyle(Theme.ink)
            content
            if let note { Text(note).font(Theme.body(12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }
}

// Everything below is the Mac's Settings window; the iPad has its own sheet (iPad/PadSettingsView.swift).
#if os(macOS)
enum SettingsPage: String, CaseIterable, Identifiable {
    case account = "Account", ai = "Your AI", voices = "Voices", nudges = "Nudges"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .account: "person.crop.circle.fill"
        case .ai: "sparkles"
        case .voices: "waveform"
        case .nudges: "bell.badge"
        }
    }
    var blurb: String {
        switch self {
        case .account: "Google sign-in for NotebookLM"
        case .ai: "Engine, models, and keys"
        case .voices: "Rumik's podcast voices"
        case .nudges: "Gentle reminders from Pip"
        }
    }
}

struct SettingsView: View {
    @Environment(AISettings.self) private var settings
    #if DEBUG
    // Development: `-NLSettingsPage Account` opens on that page.
    @State private var page: SettingsPage = SettingsPage(rawValue: UserDefaults.standard.string(forKey: "NLSettingsPage") ?? "") ?? .ai
    #else
    @State private var page: SettingsPage = .ai
    #endif

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.rawValue).font(Theme.display(28)).foregroundStyle(Theme.ink)
                        Text(page.blurb).font(Theme.body(14)).foregroundStyle(Theme.ink2)
                    }
                    switch page {
                    case .account: AccountPage()
                    case .ai: AIPage()
                    case .voices: VoicesPage()
                    case .nudges: NudgesPage()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.paper)
        }
        .frame(width: 860, height: 680)
        .tint(Theme.accent)
        .task { await settings.refreshAccount() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PipView(pose: .study, size: 54)
                VStack(alignment: .leading, spacing: 0) {
                    Text("NeuralLoop").font(Theme.display(16))
                    Text("Settings").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                }
            }
            .padding(.bottom, 14)
            ForEach(SettingsPage.allCases) { item in
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).frame(width: 22)
                        Text(item.rawValue).font(Theme.display(15, .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .foregroundStyle(page == item ? Theme.accent : Theme.ink2)
                    .background(page == item ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Keys stay in your Mac's Keychain. Only the chapter being prepared is ever sent to an AI.")
                .font(Theme.body(11)).foregroundStyle(Theme.ink3)
        }
        .padding(18)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sunk)
    }
}

// MARK: Account

struct AccountPage: View {
    @Environment(AISettings.self) private var settings

    var body: some View {
        SettingsCard(title: "Google", note: "Sign-in happens in a real browser window (Chrome when you have it). That session is what NotebookLM uses; Pip never sees your password.") {
            HStack(spacing: 14) {
                Image(systemName: settings.account.signedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 34)).foregroundStyle(settings.account.signedIn ? Theme.mint : Theme.ink3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.account.signedIn ? "Signed in" : "Not signed in").font(Theme.display(16, .medium))
                    Text(settings.account.signedIn ? settings.account.email : "NotebookLM needs this. Without it, Pip uses your own AI.")
                        .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                if settings.account.signedIn {
                    Button("Sign out") { Task { await settings.signOut() } }
                } else {
                    Button("Sign in with Google") { Task { await settings.signIn() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(settings.signingIn)
                }
            }
            if !settings.accountNote.isEmpty { Text(settings.accountNote).font(Theme.body(12)).foregroundStyle(Theme.ink2) }
        }
        CardBox { DriveSyncCard() }  // the card has its own title
        CardBox { LibraryDataCard() }
        UsageCard()
    }
}

// MARK: Your AI

struct AIPage: View {
    @Environment(AISettings.self) private var settings
    @State private var showItems = false

    var body: some View {
        @Bindable var settings = settings
        SettingsCard(title: "Who prepares your books",
                     note: "NotebookLM makes wonderful podcasts. When it isn't signed in, is busy, or runs out of daily uses, your AI makes that item instead, so a book always gets finished.") {
            HStack(spacing: 10) {
                ForEach(Engine.allCases, id: \.self) { engine in
                    ChoiceCard(icon: icon(engine), title: short(engine), detail: detail(engine), selected: settings.config.engine == engine) {
                        settings.config.engine = engine
                    }
                }
            }
        }

        ModelPicker(title: "Your AI", note: "Writes reading guides, quizzes, flashcards, maps, podcast scripts, and explainers.",
                    choice: $settings.config.make, keys: $settings.keys, allowAutomatic: true)

        SettingsCard(title: "Different models for some items", note: "For example, quizzes from Claude and everything else from Ollama.") {
            DisclosureGroup(isExpanded: $showItems) {
                VStack(spacing: 8) {
                    ForEach(AISettings.items, id: \.id) { item in ItemOverride(name: item.name, id: item.id) }
                }
                .padding(.top, 8)
            } label: {
                Text(settings.config.tasks.isEmpty ? "Every item uses Your AI" : "\(settings.config.tasks.count) item\(settings.config.tasks.count == 1 ? "" : "s") use a different model")
                    .font(Theme.body(14))
            }
        }

        ModelPicker(title: "Recall checker", note: "Checks your own-words answers, one key point at a time. A small open model on your Mac is quick and private.",
                    choice: $settings.config.recall, keys: $settings.keys, allowAutomatic: false)

        SettingsCard(title: "Save and test", note: "Pip tries each model once with a tiny request, so you know it works before your next book.") {
            HStack {
                Button { Task { await settings.saveAndTest() } } label: {
                    Label(settings.checking ? "Testing…" : "Save and test", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(settings.checking)
                if settings.checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Save without testing") { settings.save() }
            }
            ForEach(settings.check.keys.sorted(), id: \.self) { role in
                if let result = settings.check[role] { CheckRow(role: role, result: result) }
            }
            if !settings.checkNote.isEmpty { Text(settings.checkNote).font(Theme.body(12)).foregroundStyle(Theme.ink2) }
            if !settings.keyNote.isEmpty { Text(settings.keyNote).font(Theme.body(12)).foregroundStyle(Theme.rose) }
        }
    }

    private func icon(_ e: Engine) -> String {
        switch e {
        case .auto: "sparkles"
        case .notebooklm: "book.pages"
        case .local: "desktopcomputer"
        }
    }

    private func detail(_ e: Engine) -> String {
        switch e {
        case .auto: "Your AI steps in whenever NotebookLM can't, so books always finish."
        case .notebooklm: "Wait for NotebookLM, even when it's busy or out of daily uses."
        case .local: "Free and private with Ollama, or the models and keys you choose."
        }
    }

    private func short(_ e: Engine) -> String {
        switch e {
        case .auto: "NotebookLM first"
        case .notebooklm: "Only NotebookLM"
        case .local: "Only my AI"
        }
    }
}

struct ChoiceCard: View {
    let icon: String
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon).font(.system(size: 18))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.accent : Theme.ink3)
                }
                Text(title).font(Theme.display(14, .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.body(11)).foregroundStyle(Theme.ink2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .foregroundStyle(selected ? Theme.accent : Theme.ink2)
            .background(selected ? Theme.accentSoft : Theme.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Provider cards, then the model, address, and key for the chosen one.
struct ModelPicker: View {
    @Environment(AISettings.self) private var settings
    let title: String
    let note: String
    @Binding var choice: ModelChoice
    @Binding var keys: [String: String]
    let allowAutomatic: Bool

    private let columns = [GridItem(.adaptive(minimum: 136), spacing: 10)]

    var body: some View {
        let preset = choice.provider == "auto" ? nil : ProviderPreset.matching(choice)
        SettingsCard(title: title, note: note) {
            LazyVGrid(columns: columns, spacing: 10) {
                if allowAutomatic {
                    ProviderTile(icon: "wand.and.stars", title: "Automatic", status: "Your key, else Ollama", selected: choice.provider == "auto") {
                        choice = ModelChoice(provider: "auto")
                    }
                }
                ForEach(ProviderPreset.all) { p in
                    ProviderTile(icon: Self.icon(p.id), title: p.title, status: status(p), selected: preset?.id == p.id) {
                        choice = p.choice(model: nil)
                    }
                }
            }
            if let preset {
                VStack(alignment: .leading, spacing: 10) {
                    Text(preset.detail).font(Theme.body(12)).foregroundStyle(Theme.ink2)
                    Field(label: "Model") {
                        HStack {
                            TextField("", text: Binding(get: { choice.model ?? "" }, set: { choice.model = $0.isEmpty ? nil : $0 }),
                                      prompt: Text(preset.defaultModel.isEmpty ? "the one you've set up" : preset.defaultModel))
                                .textFieldStyle(.roundedBorder)
                            if !preset.suggestions.isEmpty {
                                Menu("Suggestions") { ForEach(preset.suggestions, id: \.self) { m in Button(m) { choice.model = m } } }
                                    .fixedSize()
                            }
                        }
                    }
                    if preset.provider == "hermes" {
                        @Bindable var settings = settings
                        Toggle(isOn: $settings.config.hermesTools) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Let Hermes use its tools").font(Theme.body(13))
                                Text("Hermes can act on your Mac with its tools, and text in a book could steer it. Only turn this on if you've limited its tools in Hermes.")
                                    .font(Theme.body(11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    if preset.provider == "custom" {
                        Field(label: "Address") {
                            TextField("", text: Binding(get: { choice.baseUrl ?? "" }, set: { choice.baseUrl = $0.isEmpty ? nil : $0 }),
                                      prompt: Text("https://…/v1")).textFieldStyle(.roundedBorder)
                        }
                    }
                    if let variable = preset.keyVariable {
                        Field(label: preset.keyOptional ? "Key (optional)" : "Key") {
                            SecureField("", text: Binding(get: { keys[variable] ?? "" }, set: { keys[variable] = $0 }),
                                        prompt: Text("Paste your key")).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(14)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func status(_ p: ProviderPreset) -> String {
        guard let variable = p.keyVariable else { return p.id == "ollama" ? "Free, on this Mac" : "Uses its own setup" }
        if settings.isSaved(variable) { return "Key saved" }
        if !(keys[variable] ?? "").isEmpty { return "Not saved yet" }
        if p.id == "lmstudio" { return "Free, on this Mac" }
        return p.keyOptional ? "Your own address" : "Needs a key"
    }

    static func icon(_ id: String) -> String {
        switch id {
        case "ollama": "laptopcomputer"
        case "lmstudio": "cube.transparent"
        case "anthropic": "asterisk"
        case "openai": "circle.hexagongrid"
        case "openrouter": "arrow.triangle.branch"
        case "opencode": "chevron.left.forwardslash.chevron.right"
        case "hermes": "bolt.horizontal"
        default: "network"
        }
    }
}

struct ProviderTile: View {
    let icon: String
    let title: String
    let status: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(selected ? Theme.accent : Theme.ink2)
                Text(title).font(Theme.display(13, .medium)).foregroundStyle(Theme.ink).lineLimit(2)
                Text(status).font(Theme.body(10)).foregroundStyle(status == "Key saved" ? Theme.mint : Theme.ink3).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .background(selected ? Theme.accentSoft : Theme.paper, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Theme.body(13)).foregroundStyle(Theme.ink2).frame(width: 96, alignment: .leading)
            content
        }
    }
}

struct ItemOverride: View {
    @Environment(AISettings.self) private var settings
    let name: String
    let id: String

    var body: some View {
        @Bindable var settings = settings
        HStack {
            Text(name).font(Theme.body(13)).frame(width: 230, alignment: .leading)
            Picker("", selection: Binding(
                get: { settings.config.tasks[id].flatMap(ProviderPreset.matching)?.id ?? "same" },
                set: { value in settings.config.tasks[id] = value == "same" ? nil : ProviderPreset.named(value)?.choice(model: nil) })) {
                Text("Same as Your AI").tag("same")
                ForEach(ProviderPreset.all) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            if settings.config.tasks[id] != nil {
                TextField("Model", text: Binding(get: { settings.config.tasks[id]?.model ?? "" },
                                                 set: { settings.config.tasks[id]?.model = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 170)
            }
        }
    }
}

struct CheckRow: View {
    let role: String
    let result: AICheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? Theme.mint : Theme.accent).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.display(14, .medium))
                Text(result.ok ? "\(result.name ?? "") \(result.model ?? "") answered in \(String(format: "%.1f", result.seconds ?? 0)) s"
                                : (result.message ?? "Didn't answer."))
                    .font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(result.ok ? Theme.mintSoft : Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12))
    }

    private var label: String {
        if role == "make" { return "Your AI" }
        if role == "recall" { return "Recall checker" }
        let id = role.replacingOccurrences(of: "task:", with: "")
        return AISettings.items.first { $0.id == id }?.name ?? id
    }
}

// MARK: Nudges

struct NudgesPage: View {
    @State private var settings = Nudger.settings
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NotificationsAllowed()
            gentle
            silly
            if !note.isEmpty { Text(note).font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
        }
        .onChange(of: settings) { Nudger.settings = settings }
    }

    private var silly: some View {
        SettingsCard(title: "Silly mode",
                     note: "When you’ve been away a while, Pip gets dramatic, just for laughs: a tiny sad violin after 8 hours, a sad little song after 12, and a shocked “fahhh” after a whole day. Each plays once, never in quiet hours, and opening NeuralLoop cheers Pip right up.") {
            Toggle("Silly sounds and a sad Pip when I've been away", isOn: $settings.sillySounds).toggleStyle(.switch)
            Toggle("Include the “fahhh” after a day", isOn: $settings.fahhh).toggleStyle(.switch)
                .disabled(!settings.sillySounds)
            Toggle("Pop up a big Pip on screen while the sound plays", isOn: $settings.bigPip).toggleStyle(.switch)
                .disabled(!settings.sillySounds)
            HStack {
                ForEach([NudgeMood.sadViolin, .sadMeow, .shocked], id: \.self) { mood in
                    Button(Self.label(mood)) {
                        Nudger.send(Nudge.sample(mood), test: true)
                        note = "Sent. If nothing appeared, allow notifications for NeuralLoop in System Settings → Notifications."
                    }
                    .help("Send a test nudge with this sound")
                }
            }
            .disabled(!settings.enabled)
        }
    }

    static func label(_ mood: NudgeMood) -> String {
        switch mood {
        case .gentle: "Try the chime"
        case .sadViolin: "Try 🎻 sad violin"
        case .sadMeow: "Try 😿 sad meow"
        case .shocked: "Try 😱 fahhh"
        }
    }

    private var gentle: some View {
        SettingsCard(title: "Let Pip nudge me",
                     note: "At most one a day, only when there's something small worth doing: cards that are due, or a chapter loop you left halfway. Never during quiet hours. If you skip two in a row, Pip backs off.") {
            Toggle("Gentle nudges", isOn: $settings.enabled).toggleStyle(.switch)
            Field(label: "Quiet from") {
                Picker("", selection: $settings.quietStart) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) } }
                    .labelsHidden().frame(width: 120)
                Text("until").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                Picker("", selection: $settings.quietEnd) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) } }
                    .labelsHidden().frame(width: 120)
            }
            .disabled(!settings.enabled)
            HStack {
                Button("Send a test nudge") {
                    Nudger.send(Nudge.sample(.gentle), test: true)
                    note = "Sent. If nothing appeared, allow notifications for NeuralLoop in System Settings → Notifications."
                }
                Button("Pause until tomorrow") {
                    Nudger.settings = settings
                    Nudger.pauseUntilTomorrow()
                    settings = Nudger.settings
                    note = "Nudges paused until tomorrow. Pip will be quiet."
                }
            }
            if settings.pausedUntil > Date().timeIntervalSince1970 * 1000 {
                Text("Paused until \(Date(timeIntervalSince1970: settings.pausedUntil / 1000).formatted(date: .abbreviated, time: .shortened)).")
                    .font(Theme.body(12)).foregroundStyle(Theme.ink3)
            }
        }
    }

    static func hour(_ h: Int) -> String {
        Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())?.formatted(date: .omitted, time: .shortened) ?? "\(h):00"
    }
}

// MARK: Voices

struct VoicesPage: View {
    @Environment(AISettings.self) private var settings
    private let voices = ["Ira", "Aisha", "Siya", "Zoya"]

    var body: some View {
        @Bindable var settings = settings
        SettingsCard(title: "Voice quality", note: "Rumik OSS-1 runs on your Mac. Its license allows personal, non-commercial use.") {
            HStack(spacing: 10) {
                ChoiceCard(icon: "hare", title: "Fast", detail: "About twice as quick. A podcast is ready in half the time.",
                           selected: settings.config.voiceQuality == .fast) { settings.config.voiceQuality = .fast }
                ChoiceCard(icon: "sparkles", title: "Best", detail: "The richest voice, for when you're not in a hurry.",
                           selected: settings.config.voiceQuality == .best) { settings.config.voiceQuality = .best }
            }
        }
        SettingsCard(title: "Podcast length",
                     note: "Shorter podcasts are also quicker to make, with NotebookLM and with your own AI.") {
            HStack(spacing: 10) {
                ChoiceCard(icon: "wand.and.stars", title: "Fits the chapter", detail: "Short for short chapters, standard for long ones.",
                           selected: settings.config.audioLength == .auto) { settings.config.audioLength = .auto }
                ChoiceCard(icon: "hare", title: "Short", detail: "About 5 to 7 minutes.",
                           selected: settings.config.audioLength == .short) { settings.config.audioLength = .short }
                ChoiceCard(icon: "headphones", title: "Standard", detail: "About 10 to 15 minutes.",
                           selected: settings.config.audioLength == .default) { settings.config.audioLength = .default }
                ChoiceCard(icon: "tortoise", title: "Long", detail: "About 20 minutes, for a deep dive.",
                           selected: settings.config.audioLength == .long) { settings.config.audioLength = .long }
            }
        }
        SettingsCard(title: "Podcast hosts") {
            Field(label: "Asks") {
                Picker("", selection: Binding(get: { settings.config.voices[0] }, set: { settings.config.voices[0] = $0 })) {
                    ForEach(voices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Field(label: "Explains") {
                Picker("", selection: Binding(get: { settings.config.voices[1] }, set: { settings.config.voices[1] = $0 })) {
                    ForEach(voices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Text("The host who explains also narrates the explainer videos.").font(Theme.body(12)).foregroundStyle(Theme.ink3)
        }
        HStack { Spacer(); Button("Save") { settings.save() }.buttonStyle(.borderedProminent).controlSize(.large) }
    }
}

// MARK: Welcome

/// First launch: sign in with Google for NotebookLM, or carry on with Pip's own AI.
/// Whether macOS lets Pip's notifications through, with the one button that fixes it.
struct NotificationsAllowed: View {
    var compact = false
    @State private var permission: Notifier.Permission?

    var body: some View {
        Group {
            switch permission {
            case .allowed?:
                Label("Notifications are on", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint)
            case .off?:
                HStack {
                    Label("Notifications are off for NeuralLoop", systemImage: "bell.slash").foregroundStyle(Theme.ink2)
                    Button("Turn on in System Settings") { Notifier.openSystemSettings() }
                }
            case .notAsked?:
                Button { Task { permission = await Notifier.shared.ask() } } label: {
                    Label("Allow notifications", systemImage: "bell.badge")
                }
                .buttonStyle(.borderedProminent).controlSize(compact ? .regular : .large)
            case nil:
                EmptyView()
            }
        }
        .font(Theme.body(13))
        .task { permission = await Notifier.shared.permission() }
        // Back from System Settings: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { permission = await Notifier.shared.permission() }
        }
    }
}

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
            Divider().frame(width: 300).padding(.top, 4)
            Text("Pip tells you when a chapter is ready, and nudges you (at most once a day, unless Pip really misses you).")
                .font(Theme.body(13)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center).frame(maxWidth: 420)
            NotificationsAllowed(compact: true)
        }
        .padding(40)
        .frame(width: 520)
        .tint(Theme.accent)
        .task { await settings.refreshAccount() }
    }
}


/// NotebookLM's live allowance: five-hour and weekly windows, when they reset, and what it can make right now.
struct UsageCard: View {
    @Environment(Library.self) private var library

    var body: some View {
        SettingsCard(title: "NotebookLM usage", note: "A podcast or video uses about 44% of the five-hour allowance, so NotebookLM makes about two every five hours. With “NotebookLM first”, your AI makes whatever doesn't fit.") {
            if let usage = library.usage, usage.known {
                HStack(spacing: 12) {
                    if let w = usage.fiveHour { Meter(label: "Next five hours", window: w) }
                    if let w = usage.weekly { Meter(label: "This week", window: w, weekday: true) }
                }
                HStack(spacing: 14) {
                    Label(usage.podcast ? "Can make a podcast now" : "Podcasts after the reset", systemImage: usage.podcast ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(usage.podcast ? Theme.mint : Theme.ink2)
                    Label(usage.video ? "Can make a video now" : "Videos after the reset", systemImage: usage.video ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(usage.video ? Theme.mint : Theme.ink2)
                }
                .font(Theme.body(12))
            } else {
                Text("Sign in with Google to see how much NotebookLM can still make.").font(Theme.body(13)).foregroundStyle(Theme.ink2)
            }
            Button("Refresh") { Task { await library.refreshUsage(force: true) } }.controlSize(.small)
        }
    }
}

struct Meter: View {
    let label: String
    let window: NotebookLMUsage.Window
    var weekday = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(window.remaining))%").font(Theme.display(22))
                Text("left").font(Theme.body(12)).foregroundStyle(Theme.ink3)
            }
            ProgressView(value: window.remaining, total: 100).tint(window.remaining > 44 ? Theme.mint : Theme.accent)
            Text("\(label) · resets \(reset)").font(Theme.body(11)).foregroundStyle(Theme.ink3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12))
    }

    private var reset: String {
        guard let date = window.resetDate else { return "soon" }
        return weekday ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : date.formatted(date: .omitted, time: .shortened)
    }
}
#endif

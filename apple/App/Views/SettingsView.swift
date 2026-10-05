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
        case .account: "Your Google account, library, and devices"
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
    @State private var drive = DriveAccount.shared

    var body: some View {
        GoogleAccountCard()
        if drive.isSignedIn { DevicesCard() }
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
                     note: "When you’ve been away a while, Pip gets dramatic, just for laughs. Each step plays once (hours count from the last time you used NeuralLoop), only when something is waiting for you, never in quiet hours, and opening NeuralLoop cheers Pip right up.") {
            if !settings.enabled {
                Text("Silly mode needs “Notifications from Pip”: turn it on above to use it. The Try buttons work either way.")
                    .font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            sillyControls
        }
    }

    /// The steps can be edited only while Silly mode can actually go out; the Try buttons always work (you asked).
    private var stepsEditable: Bool { settings.enabled && settings.sillySounds }

    @ViewBuilder private var sillyControls: some View {
        Toggle("Silly sounds and a sad Pip when I've been away", isOn: $settings.sillySounds).toggleStyle(.switch)
            .disabled(!settings.enabled)
        steps
        Field(label: "Arrives as") {
            Picker("", selection: $settings.bigPip) {
                Text("A big Pip on screen, plus a notification").tag(true)
                Text("Just a notification, like the others").tag(false)
            }
            .labelsHidden().pickerStyle(.radioGroup)
        }
        .disabled(!stepsEditable)
        Field(label: "Volume") {
            Slider(value: $settings.volume, in: 0.1...1) { editing in
                if !editing { NudgeSounds.preview(settings.ladder.first?.sound ?? .sadViolin, volume: settings.volume) }
            }
            .frame(width: 220)
            Text("\(Int((settings.volume * 100).rounded()))%").font(Theme.body(12)).foregroundStyle(Theme.ink2).monospacedDigit()
        }
        .disabled(!stepsEditable || !settings.bigPip)
        Text(settings.bigPip ? "Let go of the slider to hear it. During a call, a full-screen app, or with the screen locked, Pip comes as a notification instead, at your Mac's alert volume (System Settings → Sound)."
                             : "Notifications play at your Mac's alert volume: System Settings → Sound.")
                .font(Theme.body(11)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
    }

    /// Silly mode's steps: a sound and its hours each, any number of them (sounds can repeat), plus an optional repeat.
    /// Each control is disabled on its own (not the whole list) so the Try buttons keep working.
    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($settings.steps) { $step in
                let number = (settings.ladder.firstIndex { $0.id == step.id } ?? 0) + 1
                HStack(spacing: 8) {
                    Picker("Step \(number) sound", selection: $step.sound) {
                        ForEach(SillyStep.sounds, id: \.self) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().frame(width: 170).disabled(!stepsEditable)
                    Text("after").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    TextField("Step \(number) hours", value: $step.hours, format: .number).labelsHidden()
                        .frame(width: 46).multilineTextAlignment(.trailing).disabled(!stepsEditable)
                    Stepper("Step \(number) hours", value: $step.hours, in: SillyStep.hourRange).labelsHidden()
                        .disabled(!stepsEditable)
                    Text(step.hours == 1 ? "hour" : "hours").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    Button("Try") {
                        Nudger.send(Nudge.sample(step.sound), test: true)
                        note = "Sent. If nothing appeared, allow notifications for NeuralLoop in System Settings → Notifications."
                    }
                    .help("Send a test nudge with this sound")
                    Button { settings.steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this step").accessibilityLabel("Remove step \(number)")
                        .disabled(!stepsEditable)
                }
            }
            if settings.steps.isEmpty {
                Text("No steps: Pip only sends the usual nudges.").font(Theme.body(12)).foregroundStyle(Theme.ink3)
            }
            Group {
                HStack {
                    Button {
                        // Never two steps at the same hour: four after the last, or the nearest free hour.
                        let hours = SillyStep.freeHours(after: settings.steps)
                        settings.steps.append(SillyStep(settings.ladder.last?.sound ?? .sadViolin, after: hours))
                    } label: { Label("Add a step", systemImage: "plus.circle") }
                    .disabled(settings.steps.count >= SillyStep.most)
                    Button("Reset to 8, 12, and 24 hours") { (settings.steps, settings.repeatHours) = (SillyStep.defaults, 0) }
                }
                .controlSize(.small)
                HStack(spacing: 8) {
                    Toggle("Then repeat the last one every", isOn: Binding(get: { settings.repeatHours > 0 },
                                                                          set: { settings.repeatHours = $0 ? 6 : 0 }))
                        .toggleStyle(.checkbox)
                    TextField("Repeat every how many hours", value: Binding(get: { settings.repeatHours > 0 ? settings.repeatHours : 6 },
                                                                            set: { settings.repeatHours = SillyStep.repeatChoice($0) }), format: .number)
                        .labelsHidden().frame(width: 46).multilineTextAlignment(.trailing).disabled(settings.repeatHours == 0)
                    Text("hours while I'm away").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                }
            }
            .disabled(!stepsEditable)
        }
    }

    private var gentle: some View {
        SettingsCard(title: "Notifications from Pip",
                     note: "Off means nothing at all from Pip. “Chapter ready” comes once per chapter, when everything Pip is making for the chapter you can study next is ready; if that happens during quiet hours or a pause, it comes after. Gentle nudges come at most once a day, only about chapters that are fully prepared, never during quiet hours, and back off if you skip two in a row.") {
            Toggle("Notifications from Pip", isOn: $settings.enabled).toggleStyle(.switch)
            Toggle("When my next chapter is ready", isOn: $settings.chapterReady).toggleStyle(.switch)
                .disabled(!settings.enabled).padding(.leading, 18)
            Toggle("Gentle nudges", isOn: $settings.nudges).toggleStyle(.switch)
                .disabled(!settings.enabled).padding(.leading, 18)
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

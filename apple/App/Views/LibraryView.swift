// The shelf: Pip's greeting with this week at a glance, where you left off, one cover per book with a dot per
// chapter, and your year with Pip. Drop a book anywhere on the window.

import NeuralLoopCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var dropping = false
    @State private var removing: BookEntry?
    /// This window, for the file picker (only one window shows it).
    @State private var windowID = UUID().uuidString
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    /// The picker was asked for and no window has it yet: the window in front takes it.
    private func claimPicker() {
        guard library.isPicking, library.pickerWindow == nil else { return }
        #if os(macOS)
        guard controlActiveState == .key else { return }
        #endif
        library.pickerWindow = windowID
    }

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 20)]

    var body: some View {
        @Bindable var library = library
        let summary = ShelfSummary.from(library.entries)
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                hero(summary)
                if library.entries.isEmpty {
                    emptyShelf
                } else {
                    if let resume = summary.resume { ResumeCard(entry: resume.entry, chapter: resume.chapter, stage: resume.stage) }
                    section("Your shelf", detail: shelfDetail) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(library.entries) { entry in
                                Button { library.path.append(entry.id) } label: { BookCard(entry: entry) }
                                    .buttonStyle(LiftStyle())
                                    .contextMenu {
                                        Button("Open") { library.path.append(entry.id) }
                                        #if os(macOS)
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
                                        #endif
                                        Divider()
                                        Button("Remove book…", role: .destructive) { removing = entry }
                                    }
                            }
                            addCard
                        }
                    }
                    section("Your year with Pip", detail: "Every minute you study, across all your books") {
                        YearLog(log: Shelf.combinedLog(library.entries.map { $0.progress.log }))
                    }
                }
            }
            .padding(.horizontal, 36).padding(.vertical, 30)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .overlay { if dropping { dropOverlay } }
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in library.add(url) } }
                }
            }
            return true
        }
        #else
        .onDrop(of: Self.bookTypes, isTargeted: $dropping) { providers in dropped(providers) }
        #endif
        // Every library window has this view; only one of them (the one in front) shows the picker.
        .fileImporter(isPresented: Binding(get: { library.isPicking && library.pickerWindow == windowID },
                                           set: { if !$0 { library.isPicking = false } }),
                      allowedContentTypes: Self.bookTypes) { result in
            if case .success(let url) = result { addBook(url) }
        }
        .onChange(of: library.isPicking, initial: true) { claimPicker() }
        .onDisappear { if library.pickerWindow == windowID { library.pickerWindow = nil } }  // closed: another may take it
        #if os(macOS)
        .onChange(of: controlActiveState) { claimPicker() }
        #endif
        .alert(library.message ?? "", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog("Remove “\(removing?.title ?? "this book")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove book", role: .destructive) { if let id = removing?.id { library.removeBook(id) }; removing = nil }
            Button("Keep it", role: .cancel) { removing = nil }
        } message: {
            Text("Its chapters, podcasts, videos, and your progress go to the Trash, and it leaves your other devices too.")
        }
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .primaryAction) { ProfileButton() } }
    }

    // MARK: Hero

    private func hero(_ summary: ShelfSummary) -> some View {
        HStack(alignment: .center, spacing: 26) {
            PipView(pose: summary.preparing.isEmpty ? (summary.dueCards > 0 ? .play : .read) : .study, size: 150)
            VStack(alignment: .leading, spacing: 10) {
                Text(greeting).font(Theme.display(34)).foregroundStyle(Theme.ink)
                Text(subline(summary)).font(Theme.body(15)).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { library.isPicking = true } label: {
                        Label("Add a book", systemImage: "plus").font(Theme.display(15, .medium)).padding(.horizontal, 6)
                            .fixedSize()  // one line, even when the hero is narrow (an upright iPad)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Text("or drop a PDF or EPUB anywhere here").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 12)
            if !library.entries.isEmpty {
                VStack(spacing: 10) {
                    StatPill(icon: "clock.fill", value: Activity.formatDuration(summary.weekSeconds), label: "this week", tint: Theme.sky)
                    StatPill(icon: "rectangle.stack.fill", value: "\(summary.dueCards)", label: summary.dueCards == 1 ? "card ready" : "cards ready",
                             tint: Theme.mint)
                    StatPill(icon: "checkmark.seal.fill", value: "\(summary.loopsClosedThisWeek)",
                             label: summary.loopsClosedThisWeek == 1 ? "loop closed" : "loops closed", tint: Theme.accent)
                }
                .frame(width: 190)
            }
        }
        .padding(26)
        .background(
            LinearGradient(colors: [Theme.accentSoft, Theme.butterSoft], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            // A few soft leaves in the corner, for warmth.
            ZStack {
                Circle().fill(Theme.surface.opacity(0.35)).frame(width: 180).offset(x: 60, y: -70)
                Circle().fill(Theme.surface.opacity(0.25)).frame(width: 90).offset(x: -90, y: -40)
            }
            .clipped()
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning!" : hour < 18 ? "Good afternoon!" : "Good evening!"
    }

    private func subline(_ s: ShelfSummary) -> String {
        if library.entries.isEmpty { return "Give Pip a book and it becomes small learning loops: listen, read, recall, map, remember." }
        if !s.preparing.isEmpty { return "Pip is preparing \(s.preparing.count == 1 ? s.preparing[0].title : "\(s.preparing.count) books"). Ready chapters are open already." }
        if s.dueCards > 0 { return "A few cards are ready for a quick review. Two minutes is plenty." }
        return "Everything's up to date. Rest counts too."
    }

    private var shelfDetail: String {
        let n = library.entries.count
        return "\(n) book\(n == 1 ? "" : "s")"
    }

    private func section<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(Theme.display(22)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.body(13)).foregroundStyle(Theme.ink3)
            }
            content()
        }
    }

    // MARK: Empty, add, drop

    private var emptyShelf: some View {
        CardBox(fill: Theme.sunk) {
            VStack(spacing: 16) {
                Text("Your shelf is empty, and that's a fine place to start.").font(Theme.display(22)).multilineTextAlignment(.center)
                EmptyShelfGuide()
                #if os(macOS)
                EmptyShelfSteps(steps: ["Drag a PDF or EPUB onto this window (or click Add a book).",
                                        "Pip splits it into chapters and starts preparing the first one.",
                                        "Study each chapter's loop: listen, read, recall, map, remember."])
                HStack {
                    Button("Add a book") { library.isPicking = true }.buttonStyle(.borderedProminent)
                    Button("Try the sample book") { addSample() }
                }
                .controlSize(.large)
                #else
                EmptyShelfSteps(steps: ["Drag a PDF or EPUB here from Files (or tap Add a book).",
                                        "Your Mac prepares it the next time it syncs.",
                                        "Study each chapter's loop: listen, read, recall, map, remember."])
                Button("Add a book") { library.isPicking = true }.buttonStyle(.borderedProminent).controlSize(.large)
                #endif
            }
            .frame(maxWidth: .infinity).padding(.vertical, 26).padding(.horizontal, 20)
        }
    }

    private var addCard: some View {
        Button { library.isPicking = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 58, height: 58).background(Theme.accentSoft, in: Circle())
                Text("Add a book").font(Theme.display(16, .medium)).foregroundStyle(Theme.ink2)
                Text("PDF or EPUB").font(Theme.body(12)).foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: .infinity, minHeight: 222)
            .background(Theme.sunk.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [7])))
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftStyle())
    }

    private var dropOverlay: some View {
        VStack(spacing: 14) {
            PipView(pose: .hug, size: 170)
            Text("Drop your book here").font(Theme.display(26)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.opacity(0.94))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(18))
    }

    static let bookTypes: [UTType] = [.pdf, UTType(filenameExtension: "epub") ?? .data]

    /// The Mac prepares a book right away; the iPad hands it to the Mac through the inbox.
    private func addBook(_ url: URL) {
        #if os(macOS)
        library.add(url)
        #else
        library.addToInbox(url)
        #endif
    }

    #if os(iOS)
    /// A book dragged in from Files or another app: its file only exists during the callback, so keep a copy first.
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            guard let type = Self.bookTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return }
                let kept = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: kept)
                guard (try? FileManager.default.copyItem(at: url, to: kept)) != nil else { return }
                Task { @MainActor in
                    library.addToInbox(kept)
                    try? FileManager.default.removeItem(at: kept)
                }
            }
        }
        return true
    }
    #endif

    #if os(macOS)
    private func addSample() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime/pipeline/sample/sample-book.epub")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { library.add(bundled, practice: true); return }
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "NeuralLoopRepo") as? String, !repo.isEmpty else { return }
        library.add(URL(fileURLWithPath: repo).appendingPathComponent("pipeline/sample/sample-book.epub").standardizedFileURL, practice: true)
    }
    #endif
}

// MARK: Pieces

/// Cards rise a little under the pointer and settle when pressed.
struct LiftStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .offset(y: hovering && !reduceMotion ? -3 : 0)
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.04), radius: hovering ? 16 : 6, y: hovering ? 8 : 3)
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: hovering)
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 28, height: 28).background(tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(Theme.display(16)).foregroundStyle(Theme.ink)
                Text(label).font(Theme.body(11)).foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

enum Cover {
    static let palettes: [(soft: Color, strong: Color)] = [
        (Theme.accentSoft, Theme.accent), (Theme.mintSoft, Theme.mint), (Theme.skySoft, Theme.sky),
        (Theme.roseSoft, Theme.rose), (Theme.butterSoft, Theme.accent),
    ]
    static func palette(_ title: String) -> (soft: Color, strong: Color) { palettes[Shelf.coverIndex(title, count: palettes.count)] }
}

/// The book's cover: its colour, its title, and Pip when Pip is working on it.
struct CoverArt: View {
    let entry: BookEntry
    var height: CGFloat = 128
    var compact = false

    var body: some View {
        let pip = entry.preparing && !compact
        let palette = Cover.palette(entry.title)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [palette.soft, palette.strong.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "book.closed.fill")
                .font(.system(size: 92)).foregroundStyle(palette.strong.opacity(0.14))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: 14, y: -10)
            // The spine.
            Rectangle().fill(palette.strong.opacity(0.35)).frame(width: 7).frame(maxHeight: .infinity, alignment: .leading)
            Text(entry.title).font(Theme.display(compact ? 14 : 19)).foregroundStyle(Theme.ink).lineLimit(compact ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, compact ? 16 : 20).padding(.trailing, pip ? 70 : 12).padding(.bottom, compact ? 12 : 14)
            if pip {
                PipView(pose: .study, size: 70, interactive: false).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(6)
            }
        }
        .frame(height: height)
        .clipped()
    }
}

struct BookCard: View {
    let entry: BookEntry

    var body: some View {
        let progress = entry.progress
        let chapters = entry.book?.chapters ?? []
        let dots = Shelf.dots(chapters, progress)
        let closed = dots.filter { $0 == .closed }.count
        VStack(alignment: .leading, spacing: 0) {
            CoverArt(entry: entry)
            VStack(alignment: .leading, spacing: 10) {
                if !dots.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                            Capsule().fill(color(dot)).frame(height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                    Text(counts(closed: closed, ready: entry.readyChapters, total: chapters.count))
                        .font(Theme.body(12)).foregroundStyle(Theme.ink2)
                }
                HStack(spacing: 6) {
                    if entry.preparing { ProgressView().controlSize(.mini) }
                    Text(entry.preparing ? (entry.lastLine.isEmpty ? "Pip is getting started…" : entry.lastLine) : madeWith)
                        .font(Theme.body(11)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
            .padding(16)
        }
        .frame(minHeight: 222, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func color(_ dot: ChapterDot) -> Color {
        switch dot {
        case .closed: Theme.mint
        case .open: Theme.accent
        case .ready: Theme.accentSoft
        case .preparing: Theme.line
        }
    }

    private func counts(closed: Int, ready: Int, total: Int) -> String {
        if ready == 0 { return "\(total) chapters · the first one is on its way" }
        if closed == 0 { return "\(ready) of \(total) chapters ready" }
        return "\(closed) of \(total) loops closed · \(ready) ready"
    }

    private var madeWith: String {
        guard let book = entry.book else { return "" }
        if book.dryRun { return "A practice run" }
        switch book.engine {
        case "local": return "Made with \(book.model.isEmpty ? "your AI" : book.model)"
        case "auto": return book.model.isEmpty ? "Made with NotebookLM" : "Made with NotebookLM and \(book.model)"
        default: return "Made with NotebookLM"
        }
    }
}

/// Pick up where you left off: the book, the next step, and the chapter's podcast right here.
struct ResumeCard: View {
    @Environment(Library.self) private var library
    let entry: BookEntry
    let chapter: Chapter
    let stage: Stage

    var body: some View {
        HStack(spacing: 20) {
            CoverArt(entry: entry, height: 150, compact: true).frame(width: 118)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text("Pick up where you left off").font(Theme.body(12)).foregroundStyle(Theme.ink3).textCase(.uppercase).tracking(0.6)
                Text(chapter.title).font(Theme.display(22)).foregroundStyle(Theme.ink).lineLimit(2)
                Text("\(entry.title) · next: \(stage.label)").font(Theme.body(13)).foregroundStyle(Theme.ink2).lineLimit(1)
                HStack(spacing: 14) {
                    Button { library.path.append(entry.id) } label: {
                        Label("Continue", systemImage: "arrow.right").font(Theme.display(15, .medium)).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if let audio = chapter.audio, let url = BookFiles.url(audio, in: entry.folder), FileManager.default.fileExists(atPath: url.path) {
                        PodcastControls(url: url, compact: true, title: chapter.title, artist: entry.title,
                                        source: PlaySource(folder: entry.folder, n: chapter.n, kind: .audio)).frame(maxWidth: 300)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.line))
    }
}

/// "Your year with Pip": a square per day, greener the longer you studied, with only encouraging totals.
struct YearLog: View {
    let log: [String: Double]
    private let cell: CGFloat = 12
    private let gap: CGFloat = 3

    var body: some View {
        let now = Date().timeIntervalSince1970 * 1000
        let grid = Activity.yearGrid(log, today: now)
        let stats = Activity.yearStats(log, today: now)
        CardBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatPill(icon: "clock.fill", value: Activity.formatDuration(stats.total), label: "this year", tint: Theme.sky)
                    StatPill(icon: "calendar", value: "\(stats.days)", label: stats.days == 1 ? "day with Pip" : "days with Pip", tint: Theme.mint)
                    StatPill(icon: "flame.fill", value: "\(stats.longestRun)", label: "longest run of days", tint: Theme.accent)
                    if let best = stats.best {
                        StatPill(icon: "star.fill", value: Activity.formatDuration(best.seconds), label: "best day, \(Self.pretty(best.date))", tint: Theme.rose)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ZStack(alignment: .topLeading) {
                            ForEach(Self.spaced(grid.months), id: \.week) { month in
                                Text(month.label).font(Theme.body(10)).foregroundStyle(Theme.ink3)
                                    .offset(x: CGFloat(month.week) * (cell + gap))
                            }
                        }
                        .frame(height: 14, alignment: .topLeading)
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                                VStack(spacing: gap) {
                                    ForEach(week, id: \.date) { day in
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(day.future ? Color.clear : shade(day.level))
                                            .frame(width: cell, height: cell)
                                            .help(day.future ? "" : "\(Self.pretty(day.date)): \(day.seconds > 0 ? Activity.formatDuration(day.seconds) : "a rest day")")
                                    }
                                }
                            }
                        }
                        HStack(spacing: 4) {
                            Spacer()
                            Text("Less").font(Theme.body(10)).foregroundStyle(Theme.ink3)
                            ForEach(0..<5) { level in
                                RoundedRectangle(cornerRadius: 3).fill(shade(level)).frame(width: 10, height: 10)
                            }
                            Text("More").font(Theme.body(10)).foregroundStyle(Theme.ink3)
                        }
                        .padding(.top, 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Study calendar: \(Activity.formatDuration(stats.total)) over \(stats.days) days this year")
            }
        }
    }

    private func shade(_ level: Int) -> Color {
        switch level {
        case 0: Theme.sunk
        case 1: Theme.mintSoft
        case 2: Theme.mint.opacity(0.5)
        case 3: Theme.mint.opacity(0.75)
        default: Theme.mint
        }
    }

    /// Month labels at least three weeks apart, so a month that starts right after the grid does ("SepOct") doesn't collide.
    static func spaced(_ months: [(week: Int, label: String)]) -> [(week: Int, label: String)] {
        var kept: [(week: Int, label: String)] = []
        for month in months where (kept.last.map { month.week - $0.week >= 3 } ?? true) { kept.append(month) }
        return kept
    }

    /// One parser for every square (a DateFormatter is costly to make, and the grid has 371 of them).
    private static let parser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()
    private static let dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()

    static func pretty(_ key: String) -> String {
        guard let date = parser.date(from: key) else { return key }
        return date.formatted(dayStyle)
    }
}

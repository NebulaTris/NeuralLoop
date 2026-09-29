// Pip in the menu bar: a small panel that floats under the icon, for the two-minute things (Mac only; the shelf
// summary is shared with the library on every device).

import NeuralLoopCore
import SwiftUI

/// Everything the panel shows, gathered from every book on the shelf.
struct ShelfSummary {
    var resume: (entry: BookEntry, chapter: Chapter, stage: Stage)?
    var dueCards = 0
    var weekSeconds = 0.0
    var loopsClosedThisWeek = 0
    var preparing: [BookEntry] = []

    @MainActor static func from(_ entries: [BookEntry], now: Date = Date()) -> ShelfSummary {
        var summary = ShelfSummary()
        let nowMs = now.timeIntervalSince1970 * 1000
        let weekAgo = nowMs - 7 * FSRS.dayMs
        var latest = 0.0
        for entry in entries {
            if entry.preparing { summary.preparing.append(entry) }
            guard let book = entry.book else { continue }
            let progress = entry.progress
            summary.dueCards += Cards.due(book.chapters, progress, now: nowMs).filter { progress.cards[$0.id] != nil }.count
            for back in 0..<7 {
                summary.weekSeconds += progress.log[Activity.dayKey(nowMs - Double(back) * FSRS.dayMs)] ?? 0
            }
            summary.loopsClosedThisWeek += progress.loop.values.filter { ($0["space"] ?? 0) > weekAgo && ($0["closedShown"] != nil) }.count
            if let last = progress.last, progress.updatedAt > latest, let chapter = book.chapters.first(where: { $0.n == last.n }),
               let stage = Loop.nextStage(progress, last.n) ?? Stage(rawValue: last.stage) {
                latest = progress.updatedAt
                summary.resume = (entry, chapter, stage)
            }
        }
        return summary
    }
}

#if os(macOS)
struct QuickPanel: View {
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let summary = ShelfSummary.from(library.entries)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PipView(pose: summary.preparing.isEmpty ? (summary.dueCards > 0 ? .play : .read) : .study, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting(summary)).font(Theme.display(17)).foregroundStyle(Theme.ink)
                    Text(subline(summary)).font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let resume = summary.resume {
                PanelButton(icon: "play.circle.fill", title: "Pick up where you left off",
                            detail: "\(resume.chapter.title) · next: \(resume.stage.label)", tint: Theme.accent) {
                    open(resume.entry.id)
                }
            }
            if let resume = summary.resume, resume.chapter.audio != nil || resume.chapter.video != nil
                || [.working, .waiting].contains(resume.chapter.status["video"]) {
                PanelMedia(folder: resume.entry.folder, chapter: resume.chapter)
            }
            if summary.dueCards > 0 {
                PanelButton(icon: "rectangle.stack.fill", title: "Review \(summary.dueCards) card\(summary.dueCards == 1 ? "" : "s")",
                            detail: "About \(max(1, summary.dueCards * 15 / 60)) min", tint: Theme.mint) {
                    open(summary.resume?.entry.id ?? library.entries.first?.id)
                }
            }
            ForEach(summary.preparing) { entry in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(Theme.body(12)).bold().lineLimit(1)
                        Text(entry.lastLine.isEmpty ? "Pip is getting started…" : entry.lastLine).font(Theme.body(11)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 12))
            }

            if let usage = library.usage, usage.known, let window = usage.fiveHour {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.50percent").foregroundStyle(window.remaining > 44 ? Theme.mint : Theme.accent)
                    Text("NotebookLM: \(Int(window.remaining))% left · resets \(window.resetDate?.formatted(date: .omitted, time: .shortened) ?? "soon")")
                        .font(Theme.body(11)).foregroundStyle(Theme.ink2)
                }
            }
            HStack(spacing: 10) {
                WeekStat(value: Activity.formatDuration(summary.weekSeconds), label: "studied this week")
                WeekStat(value: "\(summary.loopsClosedThisWeek)", label: summary.loopsClosedThisWeek == 1 ? "loop closed" : "loops closed")
            }

            Divider()
            HStack {
                Button("Open NeuralLoop") { open(nil) }.buttonStyle(.borderedProminent)
                Button("Add a book") { open(nil); library.isPicking = true }
                Spacer()
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Quit NeuralLoop")
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(Theme.paper)
        .tint(Theme.accent)
    }

    private func open(_ bookId: String?) {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        if let bookId { library.path = [bookId] }
    }

    private func greeting(_ s: ShelfSummary) -> String {
        if !s.preparing.isEmpty { return "Pip is preparing" }
        if s.dueCards > 0 { return "\(s.dueCards) card\(s.dueCards == 1 ? " is" : "s are") ready" }
        return s.resume == nil ? "Hi! Drop in a book" : "All caught up"
    }

    private func subline(_ s: ShelfSummary) -> String {
        if !s.preparing.isEmpty { return "You can start on ready chapters while Pip works." }
        if s.dueCards > 0 { return "A two-minute review, then you're done for today." }
        return s.resume == nil ? "I'll turn it into small learning loops." : "You're doing great. Rest counts too."
    }
}

/// The chapter's video and podcast, playable right from the menu bar. Playback carries on when the panel closes.
struct PanelMedia: View {
    let folder: URL
    let chapter: Chapter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Listen & watch · \(chapter.title)", systemImage: "headphones")
                .font(Theme.display(13, .medium)).foregroundStyle(Theme.ink2).lineLimit(1)
            if let video = chapter.video, let url = BookFiles.url(video, in: folder) {
                ChapterVideo(url: url, corner: 10)
            } else if let status = chapter.status["video"], status == .working || status == .waiting {
                HStack(spacing: 8) {
                    if status == .working { ProgressView().controlSize(.mini) } else { Image(systemName: "clock").foregroundStyle(Theme.ink3) }
                    Text(status == .working ? "Pip is making the video" : "The video is waiting for NotebookLM")
                        .font(Theme.body(11)).foregroundStyle(Theme.ink3)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 10))
            }
            if let audio = chapter.audio, let url = BookFiles.url(audio, in: folder) {
                PodcastControls(url: url, compact: true)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}

struct PanelButton: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.display(14, .medium)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.body(11)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.ink3)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WeekStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.display(16))
            Text(label).font(Theme.body(11)).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Pip's head for the menu bar.
struct MenuBarPip: View {
    var body: some View {
        if let icon = PipArt.icon {
            Image(nsImage: icon)
        } else {
            Image(systemName: "book.circle")
        }
    }
}
#endif

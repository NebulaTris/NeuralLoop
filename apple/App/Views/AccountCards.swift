// Settings → Account: one card for your Google account (name, email, NotebookLM and the library, one sign-in), and
// the devices on your library with when each last synced.

import NeuralLoopCore
import SwiftUI

/// Every device signed in to the library, this one first, with "Sync now".
struct DevicesCard: View {
    @State private var sync = DriveSync.shared
    @State private var account = DriveAccount.shared

    var body: some View {
        SettingsCard(title: "Your devices",
                     note: "Each device adds its name here when it syncs. Books are prepared on your Mac; every device keeps your progress, cards, and where you left off.") {
            if sync.devices.isEmpty {
                Text(sync.syncing ? "Looking for your devices…" : "Your devices appear here after the first sync.")
                    .font(Theme.body(13)).foregroundStyle(Theme.ink2)
            }
            ForEach(DeviceInfo.unique(sync.devices)) { device in  // never one device twice (ForEach needs unique ids)
                HStack(spacing: 12) {
                    Image(systemName: device.kind == .mac ? "laptopcomputer" : "ipad.landscape")
                        .font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(device.name).font(Theme.display(15, .medium)).foregroundStyle(Theme.ink)
                            if device.isThisDevice {
                                Text(Self.thisOne).font(Theme.body(11)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 1).background(Theme.accentSoft, in: Capsule())
                            }
                        }
                        Text(Self.synced(device.lastSync)).font(Theme.body(12)).foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                }
            }
            HStack {
                Button { Task { await sync.syncNow() } } label: {
                    Label(sync.syncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.syncing || !account.isSignedIn)
                if let last = sync.lastSync {
                    Text("Last synced \(last.formatted(date: .omitted, time: .shortened))").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                }
            }
            if let problem = sync.problem { Text(problem).font(Theme.body(11)).foregroundStyle(Theme.rose).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private static var thisOne: String {
        #if os(macOS)
        "this Mac"
        #else
        "this iPad"
        #endif
    }

    static func synced(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        if Date().timeIntervalSince(date) < 60 { return "Synced just now" }
        return "Synced " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

/// A round badge with your initials.
struct Initials: View {
    let text: String
    var body: some View {
        ZStack {
            Circle().fill(Theme.accentSoft)
            if text.isEmpty {
                Image(systemName: "person.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
            } else {
                Text(text).font(Theme.display(18, .bold)).foregroundStyle(Theme.accent)
            }
        }
        .frame(width: 48, height: 48)
    }
}

#if os(macOS)
/// NotebookLM's sign-in (a browser session only NotebookLM can use) and the library's (Google's sign-in for Drive),
/// one after the other, the second suggesting the first's account.
@MainActor
enum GoogleSignIn {
    static func everything(_ settings: AISettings) async {
        // A NotebookLM session that's already there (from before, or the command line) is kept, never signed in again.
        if !settings.account.signedIn { await settings.refreshAccount() }
        if !settings.account.signedIn { await settings.signIn() }
        let drive = DriveAccount.shared
        guard settings.account.signedIn, drive.isConfigured, !drive.isSignedIn else { return }
        await drive.signIn(loginHint: settings.account.email)
    }

    static func signOutEverywhere(_ settings: AISettings) async {
        await settings.signOut()
        await DriveAccount.shared.signOut()
    }
}

struct GoogleAccountCard: View {
    @Environment(AISettings.self) private var settings
    @State private var drive = DriveAccount.shared
    @State private var sync = DriveSync.shared

    private var summary: AccountSummary {
        AccountSummary(notebookLM: settings.account.signedIn ? settings.account.email : nil,
                       library: drive.isSignedIn ? .init(email: drive.email, name: drive.name) : nil,
                       librarySetUp: drive.isConfigured)
    }

    var body: some View {
        let summary = summary
        SettingsCard(title: "Your Google account",
                     note: "Sign-in happens in your browser; Pip never sees your password. NotebookLM gets its own session, and your library gets a private folder in your Google Drive that only NeuralLoop can see.") {
            HStack(spacing: 14) {
                Initials(text: summary.initials)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title).font(Theme.display(17)).foregroundStyle(Theme.ink)
                    if let email = summary.email, email != summary.title {
                        Text(email).font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    } else if summary.email == nil {
                        Text("One sign-in for NotebookLM and your library.").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    switch summary.next {
                    case .signIn?:
                        Button { Task { await GoogleSignIn.everything(settings) } } label: {
                            Label(settings.signingIn || drive.signingIn ? "Waiting for Google…" : "Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(settings.signingIn || drive.signingIn)
                    case .connectLibrary?:
                        Button { Task { await GoogleSignIn.everything(settings) } } label: {
                            Label(drive.signingIn ? "Waiting for Google…" : "Connect your library", systemImage: "icloud.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent).disabled(drive.signingIn)
                    case nil:
                        EmptyView()
                    }
                    if summary.canSignOut {
                        Button("Sign out") { Task { await GoogleSignIn.signOutEverywhere(settings) } }
                            .disabled(settings.signingIn || drive.signingIn)
                    }
                }
            }
            Divider()
            row("sparkles", "NotebookLM", ok: summary.notebookLM != nil,
                summary.notebookLM.map { "Signed in as \($0). Makes your podcasts, videos, and quizzes." }
                    ?? "Not signed in. Pip uses your own AI instead.")
            row("icloud", "Your library", ok: summary.library != nil, libraryLine(summary))
            if summary.differentAccounts {
                Label("NotebookLM and your library use different Google accounts. That works, but signing out and in again with one account keeps things simple.",
                      systemImage: "exclamationmark.triangle").font(Theme.body(12)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !settings.accountNote.isEmpty { Text(settings.accountNote).font(Theme.body(12)).foregroundStyle(Theme.ink2) }
            if !drive.note.isEmpty { Text(drive.note).font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func libraryLine(_ summary: AccountSummary) -> String {
        guard summary.librarySetUp else {
            return "Syncing to your iPad needs a one-time Google setup in this copy of NeuralLoop (docs/DEVELOPMENT.md → Google Drive sync)."
        }
        guard let library = summary.library else { return "Not connected. Connect it and your books, progress, and cards follow you to your iPad." }
        let who = library.email.map { "Syncing with \($0)" } ?? "Syncing"
        guard let last = sync.lastSync else { return "\(who). First sync on its way." }
        return "\(who), last synced \(last.formatted(date: .omitted, time: .shortened))."
    }

    private func row(_ icon: String, _ title: String, ok: Bool, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : icon).foregroundStyle(ok ? Theme.mint : Theme.ink3).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.display(14, .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif

// Google Drive sync: sign in, what's synced, and when. Shown in Settings → Account on the Mac and in the iPad's settings.

import NeuralLoopCore
import SwiftUI

struct DriveSyncCard: View {
    @State private var account = DriveAccount.shared
    @State private var sync = DriveSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up.fill").font(.system(size: 20)).foregroundStyle(Theme.sky)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your library on every device").font(Theme.display(16))
                    Text(subtitle).font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if account.isSignedIn {
                HStack {
                    Button { Task { await sync.syncNow() } } label: {
                        Label(sync.syncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(sync.syncing)
                    Button("Stop syncing") { Task { await account.signOut() } }
                }
            } else {
                Button { Task { await account.signIn() } } label: {  // a successful sign-in starts syncing
                    Label(account.signingIn ? "Waiting for Google…" : "Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(account.signingIn || !account.isConfigured)
            }
            if let problem = sync.problem { Text(problem).font(Theme.body(11)).foregroundStyle(Theme.rose).fixedSize(horizontal: false, vertical: true) }
            if !account.note.isEmpty { Text(account.note).font(Theme.body(11)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true) }
            Text("NeuralLoop keeps your library in a private folder in your own Google Drive that only NeuralLoop can see. It never reads your other files.")
                .font(Theme.body(10)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        guard account.isConfigured else { return "Needs a one-time Google setup before it can be turned on (docs/DEVELOPMENT.md)." }
        guard account.isSignedIn else { return "Sign in with Google and your books, progress, and cards follow you to your iPad." }
        let who = account.email.map { "Syncing with \($0)" } ?? "Syncing"
        guard let last = sync.lastSync else { return "\(who). First sync on its way." }
        return "\(who) · last synced \(last.formatted(date: .omitted, time: .shortened))"
    }
}

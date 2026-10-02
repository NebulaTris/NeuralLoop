// The iPad's profile button and Settings sheet: your Google account and sync. Preparing books, your AI, and voices
// live on the Mac.

import SwiftUI

struct ProfileButton: View {
    #if DEBUG
    @State private var open = UserDefaults.standard.bool(forKey: "NLOpenSettings")  // development: `-NLOpenSettings YES`
    #else
    @State private var open = false
    #endif

    var body: some View {
        Button { open = true } label: { Avatar(email: DriveAccount.shared.email, size: 30) }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile and settings")
            .sheet(isPresented: $open) { PadSettingsView() }
    }
}

struct PadSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        PipView(pose: .study, size: 70)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Account").font(Theme.display(26)).foregroundStyle(Theme.ink)
                            Text("Your library follows your Google account").font(Theme.body(14)).foregroundStyle(Theme.ink2)
                        }
                    }
                    CardBox { DriveSyncCard() }  // the card has its own title
                    if DriveAccount.shared.isSignedIn { DevicesCard() }
                    Button {
                        dismiss()
                        Task { try? await Task.sleep(for: .milliseconds(450)); library.showingTour = true }  // after this sheet closes
                    } label: { Label("Take the tour", systemImage: "sparkles") }
                    CardBox { LibraryDataCard() }
                    SettingsCard(title: "Preparing books",
                                 note: "Only the chapter being prepared is ever sent to an AI; your library stays in your own Google Drive.") {
                        Label("Your Mac prepares every book, with NotebookLM or the AI you chose there. Books you add here wait for it.",
                              systemImage: "laptopcomputer")
                            .font(Theme.body(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.paper)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Theme.accent)
    }
}

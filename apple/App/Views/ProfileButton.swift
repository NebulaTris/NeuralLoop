// The profile button on the library: who's signed in, Settings, and switching or signing out of the Google account
// NotebookLM uses.

import SwiftUI

#if os(macOS)
struct ProfileButton: View {
    @Environment(AISettings.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Avatar(email: settings.account.signedIn ? settings.account.email : nil, size: 26) }
            .buttonStyle(.plain)
            .help(settings.account.signedIn ? "Signed in as \(settings.account.email)" : "Your profile and settings")
            .accessibilityLabel("Profile and settings")
            .popover(isPresented: $open, arrowEdge: .bottom) { card }
            .task {
                await settings.refreshAccount()
                if UserDefaults.standard.bool(forKey: "NLProfile") { open = true }  // development: `-NLProfile YES`
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Avatar(email: settings.account.signedIn ? settings.account.email : nil, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.account.signedIn ? "Signed in" : "Not signed in").font(Theme.display(16))
                    Text(settings.account.signedIn ? settings.account.email : "Sign in with Google so NotebookLM can make your podcasts and videos.")
                        .font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if settings.signingIn || !settings.accountNote.isEmpty {
                HStack(spacing: 8) {
                    if settings.signingIn { ProgressView().controlSize(.small) }
                    Text(settings.accountNote.isEmpty ? "Waiting for the browser…" : settings.accountNote)
                        .font(Theme.body(11)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if settings.account.signedIn {
                    row("Switch Google account", icon: "arrow.left.arrow.right.circle") { Task { await settings.switchAccount() } }
                    row("Sign out", icon: "rectangle.portrait.and.arrow.right") { Task { await settings.signOut() } }
                } else {
                    row("Sign in with Google", icon: "person.crop.circle.badge.plus") { Task { await settings.signIn() } }
                }
                row("Settings…", icon: "gearshape") {
                    open = false
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .disabled(settings.signingIn)
            Text("Your books stay on this Mac. Only the chapter being prepared is sent to the AI you chose.")
                .font(Theme.body(10)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 300)
        .background(Theme.paper)
    }

    private func row(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Theme.body(13)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
        }
        .buttonStyle(ProfileRowStyle())
    }
}

private struct ProfileRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .background(hovering || configuration.isPressed ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

#endif

/// A round avatar: the account's first letter on a warm colour, or Pip's head when nobody is signed in.
struct Avatar: View {
    let email: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let email, let first = email.first {
                Text(String(first).uppercased()).font(Theme.display(size * 0.48)).foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [Theme.accent, Theme.rose], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            } else if let icon = Self.pip {
                icon.resizable().scaledToFit().padding(size * 0.14)
                    .frame(width: size, height: size).background(Theme.accentSoft, in: Circle())
            } else {
                Image(systemName: "person.crop.circle.fill").font(.system(size: size)).foregroundStyle(Theme.accent)
            }
        }
        .overlay(Circle().stroke(Theme.line))
    }

    /// Pip's head: the vector icon on the Mac, the 3x picture elsewhere.
    @MainActor private static var pip: Image? {
        #if os(macOS)
        PipArt.icon.map { Image(nsImage: $0) }
        #else
        PipArt.iconImage.map { Image(decorative: $0, scale: 3) }
        #endif
    }
}

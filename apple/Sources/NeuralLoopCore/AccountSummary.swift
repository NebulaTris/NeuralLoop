// Settings → Account in one card: who's signed in (name and email), whether NotebookLM and the library use the same
// Google account, and the one thing to press next. NotebookLM's sign-in is a browser session only NotebookLM can use
// and the library's is an OAuth grant for Drive, so they're two sign-ins under one button.

import Foundation

public struct AccountSummary: Equatable, Sendable {
    public struct Library: Equatable, Sendable {
        public var email: String?
        public var name: String?
        public init(email: String?, name: String?) { (self.email, self.name) = (email, name) }
    }

    public enum Next: Equatable, Sendable { case signIn, connectLibrary }

    public let notebookLM: String?
    public let library: Library?
    public let librarySetUp: Bool

    /// `notebookLM`: its email when signed in. `library`: the Drive sign-in, if any. `librarySetUp`: the app has an
    /// OAuth client ID (without one, the library can't be connected from this build).
    public init(notebookLM: String?, library: Library?, librarySetUp: Bool) {
        self.notebookLM = notebookLM.flatMap { $0.isEmpty ? nil : $0 }
        self.library = library
        self.librarySetUp = librarySetUp
    }

    public var email: String? { library?.email ?? notebookLM }

    public var title: String { library?.name ?? email ?? "Not signed in" }

    /// "SR" for Sam Rivera, "S" for sam@example.com.
    public var initials: String {
        if let name = library?.name {
            return String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        }
        return email?.first.map { String($0).uppercased() } ?? ""
    }

    public var differentAccounts: Bool {
        guard let a = notebookLM, let b = library?.email else { return false }
        return a.lowercased() != b.lowercased()
    }

    /// Either service is signed in, so "Sign out" belongs on the card (next to `next`, when there is one).
    public var canSignOut: Bool { notebookLM != nil || library != nil }

    /// The main thing to press, if any.
    public var next: Next? {
        if notebookLM == nil { return .signIn }
        if library == nil, librarySetUp { return .connectLibrary }
        return nil
    }
}

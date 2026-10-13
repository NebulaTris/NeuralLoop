// The first launch's "Sign in with Google": after Pip checks whether someone's already signed in (that takes a few
// seconds), it decides whether to open Google's sign-in. Never twice (the person may have clicked during the check),
// and never after they said "Not now". Already signed in to NotebookLM but the library isn't connected: it connects
// the library, suggesting the same account.

public enum FirstSignIn {
    public enum Next: Equatable, Sendable {
        /// Open Google's sign-in.
        case signIn
        /// Signed in already, but the library (Google Drive) isn't connected: connect it with that account.
        case connectLibrary
        /// Nothing to sign in to, or already signed in: on to the tour.
        case moveOn
        /// Do nothing: the person declined, the screen went away, or a sign-in is already going.
        case stay
    }

    /// `libraryMissing`: the library can be connected here (Drive is set up) and isn't yet.
    public static func next(signedIn: Bool, canSignIn: Bool, declined: Bool, cancelled: Bool, signingIn: Bool,
                            libraryMissing: Bool = false) -> Next {
        if declined || cancelled { return .stay }
        if signedIn { return !libraryMissing ? .moveOn : signingIn ? .stay : .connectLibrary }
        if !canSignIn { return .moveOn }
        return signingIn ? .stay : .signIn
    }
}

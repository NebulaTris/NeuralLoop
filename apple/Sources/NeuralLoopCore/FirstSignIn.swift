// The first launch's "Sign in with Google": after Pip checks whether someone's already signed in (that takes a few
// seconds), it decides whether to open Google's sign-in. Never twice (the person may have clicked during the check),
// and never after they said "Not now".

public enum FirstSignIn {
    public enum Next: Equatable, Sendable {
        /// Open Google's sign-in.
        case signIn
        /// Nothing to sign in to, or already signed in: on to the tour.
        case moveOn
        /// Do nothing: the person declined, the screen went away, or a sign-in is already going.
        case stay
    }

    public static func next(signedIn: Bool, canSignIn: Bool, declined: Bool, cancelled: Bool, signingIn: Bool) -> Next {
        if declined || cancelled { return .stay }
        if signedIn || !canSignIn { return .moveOn }
        return signingIn ? .stay : .signIn
    }
}

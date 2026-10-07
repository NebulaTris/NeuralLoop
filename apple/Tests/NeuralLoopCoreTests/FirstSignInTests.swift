import Testing
@testable import NeuralLoopCore

@Test func theFirstSignInStartsOnlyWhenNobodyIsSignedInAndThePersonStillWantsIt() {
    #expect(FirstSignIn.next(signedIn: false, canSignIn: true, declined: false, cancelled: false, signingIn: false) == .signIn)
    // Already signed in (from before, or the command line): no browser window for nothing.
    #expect(FirstSignIn.next(signedIn: true, canSignIn: true, declined: false, cancelled: false, signingIn: false) == .moveOn)
    // Nothing to sign in to here (an iPad without the library set up): straight on to the tour.
    #expect(FirstSignIn.next(signedIn: false, canSignIn: false, declined: false, cancelled: false, signingIn: false) == .moveOn)
}

@Test func notNowOrAClickDuringTheCheckMeansNoSecondSignIn() {
    // "Not now" while Pip was checking: the person said no, so no browser opens afterwards.
    #expect(FirstSignIn.next(signedIn: false, canSignIn: true, declined: true, cancelled: false, signingIn: false) == .stay)
    #expect(FirstSignIn.next(signedIn: false, canSignIn: true, declined: false, cancelled: true, signingIn: false) == .stay)
    // A sign-in is already going (the person clicked): never a second one writing the same session.
    #expect(FirstSignIn.next(signedIn: false, canSignIn: true, declined: false, cancelled: false, signingIn: true) == .stay)
    // Declined wins even when someone turned out to be signed in: the screen has already moved on.
    #expect(FirstSignIn.next(signedIn: true, canSignIn: true, declined: true, cancelled: false, signingIn: false) == .stay)
}

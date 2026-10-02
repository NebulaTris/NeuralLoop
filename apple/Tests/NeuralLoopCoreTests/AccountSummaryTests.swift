import Testing
@testable import NeuralLoopCore

@Test func signedOutEverywhereOffersOneSignIn() {
    let s = AccountSummary(notebookLM: nil, library: nil, librarySetUp: true)
    #expect(s.title == "Not signed in" && s.email == nil && s.next == .signIn && s.initials == "")
}

@Test func theNameComesFromTheLibrarySignInAndTheEmailFromEither() {
    let both = AccountSummary(notebookLM: "sam@example.com", library: .init(email: "sam@example.com", name: "Sam Rivera"), librarySetUp: true)
    #expect(both.title == "Sam Rivera" && both.email == "sam@example.com" && both.initials == "SR" && both.next == nil && !both.differentAccounts)
    let notebookOnly = AccountSummary(notebookLM: "sam@example.com", library: nil, librarySetUp: true)
    #expect(notebookOnly.title == "sam@example.com" && notebookOnly.initials == "S" && notebookOnly.next == .connectLibrary)
    let notSetUp = AccountSummary(notebookLM: "sam@example.com", library: nil, librarySetUp: false)
    #expect(notSetUp.next == nil)  // nothing to press: the library needs the developer's one-time setup
}

@Test func twoDifferentGoogleAccountsAreCalledOut() {
    let s = AccountSummary(notebookLM: "work@example.com", library: .init(email: "Me@Example.com", name: nil), librarySetUp: true)
    #expect(s.differentAccounts && s.title == "Me@Example.com")
    #expect(!AccountSummary(notebookLM: "ME@example.com", library: .init(email: "me@example.com", name: nil), librarySetUp: true).differentAccounts)
    #expect(AccountSummary(notebookLM: nil, library: .init(email: "me@example.com", name: nil), librarySetUp: true).next == .signIn)
}

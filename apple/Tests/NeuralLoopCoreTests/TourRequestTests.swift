import Testing
@testable import NeuralLoopCore

@Test func askingForTheTourShowsItAndAskingAgainRestartsItInPlace() {
    var tour = TourRequest()
    #expect(!tour.showing && tour.number == 0)
    tour.request()
    #expect(tour.showing && tour.number == 1)
    // Asked again while it's up: it stays up (never lowered and raised, which a sheet can miss) and starts over.
    tour.request()
    #expect(tour.showing && tour.number == 2)
    tour.ended()
    #expect(!tour.showing)
    tour.request()
    #expect(tour.showing && tour.number == 3)
}

@Test func onlyOneWindowShowsTheTour() {
    var tour = TourRequest()
    let early = tour.claim("a")
    #expect(!early)  // nothing asked for yet
    tour.request()
    let first = tour.claim("a"), second = tour.claim("b")
    #expect(first && !second)  // another window doesn't show it too
    #expect(tour.shows(in: "a") && !tour.shows(in: "b"))
    // The window showing it closes: another one may take it over.
    tour.released("a")
    let takeover = tour.claim("b")
    #expect(takeover && tour.shows(in: "b") && !tour.shows(in: "a"))
    tour.ended()
    #expect(!tour.shows(in: "b"))
    tour.request()
    let fresh = tour.claim("a")
    #expect(fresh)  // a fresh request is anyone's
}

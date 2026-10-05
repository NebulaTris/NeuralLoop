// The guided tour, asked for from Help → Take the Tour (Mac) or Settings (iPad). A request never lowers and raises the
// flag (a sheet still closing can miss that and leave the flag up with nothing shown): it stays up, and its number
// changes, so a tour already on screen starts over in place. On the Mac only one window shows it.

public struct TourRequest: Equatable, Sendable {
    /// Goes up with every request (the tour's view is keyed on it, so asking again starts it over).
    public private(set) var number = 0
    public private(set) var showing = false
    /// The window showing it (Mac); nil until a window takes it.
    public private(set) var window: String?

    public init() {}

    public mutating func request() {
        number += 1
        showing = true
    }

    /// A window offers to show the tour: the first one asking gets it, and the others don't show it too.
    public mutating func claim(_ window: String) -> Bool {
        guard showing else { return false }
        if self.window == nil { self.window = window }
        return self.window == window
    }

    /// The window showing it closed: another may take it over.
    public mutating func released(_ window: String) {
        if self.window == window { self.window = nil }
    }

    /// Finished or closed.
    public mutating func ended() {
        showing = false
        window = nil
    }

    public func shows(in window: String) -> Bool { showing && self.window == window }
}

// Moving into Applications safely: the new copy is made next to where it goes and checked before an older copy goes
// to the Trash, a step that fails puts things back as they were, and the copy that's running only quits once the new
// one has really opened (macOS can refuse to open it).

public enum MoveInPlan {
    /// What's at the destination already.
    public enum Destination: Sendable { case empty, olderCopy, otherApp, thisCopy }

    public enum Step: Equatable, Sendable {
        /// Copy the app to a temporary name in the destination folder.
        case copyToStaging
        /// Check the copy is complete and really this app.
        case checkStaging
        /// The older copy goes to the Trash (never deleted outright).
        case trashOld
        /// The checked copy takes its place.
        case putInPlace
    }

    public enum Undo: Equatable, Sendable { case removeStaging, restoreOld }

    public enum Decision: Equatable, Sendable {
        /// The running copy is already there: nothing to do.
        case alreadyThere
        /// Something else has that name here: try the next folder.
        case tryNextFolder
        case steps([Step])
    }

    public static func decide(_ destination: Destination) -> Decision {
        switch destination {
        case .thisCopy: .alreadyThere
        case .otherApp: .tryNextFolder
        case .empty: .steps([.copyToStaging, .checkStaging, .putInPlace])
        case .olderCopy: .steps([.copyToStaging, .checkStaging, .trashOld, .putInPlace])
        }
    }

    /// What to undo, in order, when `failedAt` didn't work.
    public static func undo(failedAt: Step, trashedOld: Bool) -> [Undo] {
        failedAt == .putInPlace && trashedOld ? [.removeStaging, .restoreOld] : [.removeStaging]
    }

    public static func isGoodCopy(bundleID: String?, version: String?, hasExecutable: Bool,
                                  expectedID: String?, expectedVersion: String?) -> Bool {
        guard let bundleID, bundleID == expectedID else { return false }
        return hasExecutable && version == expectedVersion
    }

    public enum AfterReopen: Equatable, Sendable { case quit, keepRunning }

    /// This copy quits only when the new one opened; otherwise it keeps running and says what to do.
    public static func afterReopen(opened: Bool) -> AfterReopen { opened ? .quit : .keepRunning }
}

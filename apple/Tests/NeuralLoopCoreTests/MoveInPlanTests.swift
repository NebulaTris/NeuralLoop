import Testing
@testable import NeuralLoopCore

@Test func theNewCopyIsMadeAndCheckedBeforeTheOldOneGoesToTheTrash() {
    #expect(MoveInPlan.decide(.empty) == .steps([.copyToStaging, .checkStaging, .putInPlace]))
    #expect(MoveInPlan.decide(.olderCopy) == .steps([.copyToStaging, .checkStaging, .trashOld, .putInPlace]))
    // Never trash the copy that's running, and never another app that happens to share the name.
    #expect(MoveInPlan.decide(.thisCopy) == .alreadyThere)
    #expect(MoveInPlan.decide(.otherApp) == .tryNextFolder)
}

@Test func aFailedStepLeavesThingsAsTheyWere() {
    #expect(MoveInPlan.undo(failedAt: .copyToStaging, trashedOld: false) == [.removeStaging])
    #expect(MoveInPlan.undo(failedAt: .checkStaging, trashedOld: false) == [.removeStaging])
    #expect(MoveInPlan.undo(failedAt: .trashOld, trashedOld: false) == [.removeStaging])
    // The old copy is already in the Trash when the new one can't go in its place: it comes back.
    #expect(MoveInPlan.undo(failedAt: .putInPlace, trashedOld: true) == [.removeStaging, .restoreOld])
    #expect(MoveInPlan.undo(failedAt: .putInPlace, trashedOld: false) == [.removeStaging])
}

@Test func onlyACompleteCopyOfThisAppCounts() {
    #expect(MoveInPlan.isGoodCopy(bundleID: "app.neuralloop", version: "1.2", hasExecutable: true,
                                  expectedID: "app.neuralloop", expectedVersion: "1.2"))
    #expect(!MoveInPlan.isGoodCopy(bundleID: nil, version: "1.2", hasExecutable: true, expectedID: "app.neuralloop", expectedVersion: "1.2"))
    #expect(!MoveInPlan.isGoodCopy(bundleID: "app.neuralloop", version: "1.1", hasExecutable: true,
                                   expectedID: "app.neuralloop", expectedVersion: "1.2"))
    #expect(!MoveInPlan.isGoodCopy(bundleID: "app.neuralloop", version: "1.2", hasExecutable: false,
                                   expectedID: "app.neuralloop", expectedVersion: "1.2"))
}

@Test func thisCopyQuitsOnlyOnceTheNewOneIsOpen() {
    #expect(MoveInPlan.afterReopen(opened: true) == .quit)
    #expect(MoveInPlan.afterReopen(opened: false) == .keepRunning)
}

@Test func onlyOurOwnHalfMadeCopiesAreLeftovers() {
    let uuid = "0F8D2C51-6A3B-4E1F-9C7D-2B5A8E4F1A90"
    #expect(MoveInPlan.isLeftover(".moving-\(uuid)-NeuralLoop.app", appName: "NeuralLoop.app"))
    // UUID() writes uppercase, but the rule is the shape, not the case.
    #expect(MoveInPlan.isLeftover(".moving-\(uuid.lowercased())-NeuralLoop.app", appName: "NeuralLoop.app"))
    // Anything else in Applications stays: the app itself, other apps' temporary copies, near misses.
    #expect(!MoveInPlan.isLeftover("NeuralLoop.app", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover(".moving-\(uuid)-Other.app", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover(".moving-\(uuid)-NeuralLoop.app.zip", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover(".moving-\(uuid)-MyNeuralLoop.app", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover(".moving-not-a-uuid-NeuralLoop.app", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover(".moving--NeuralLoop.app", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover("moving-\(uuid)-NeuralLoop.app", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover(".moving-\(uuid)-NeuralLoop.app/Contents", appName: "NeuralLoop.app"))
    #expect(!MoveInPlan.isLeftover(".moving-\(uuid)-", appName: ""))
    #expect(!MoveInPlan.isLeftover(".moving-\(uuid)-../NeuralLoop.app", appName: "../NeuralLoop.app"))
}

@Test func theStagingNameIsALeftoverUntilItsMovedIn() {
    let name = MoveInPlan.stagingName(for: "NeuralLoop.app")
    #expect(name.hasPrefix(".moving-"))
    #expect(MoveInPlan.isLeftover(name, appName: "NeuralLoop.app"))
    #expect(MoveInPlan.stagingName(for: "NeuralLoop.app") != name)  // each move its own
}

@Test func leftoversAreSweptOnlyWhenNoOtherMoveIsRunning() {
    let names = [".moving-0F8D2C51-6A3B-4E1F-9C7D-2B5A8E4F1A90-NeuralLoop.app", "NeuralLoop.app", "Safari.app"]
    #expect(MoveInPlan.leftovers(in: names, appName: "NeuralLoop.app", anotherMoveRunning: false) == [names[0]])
    #expect(MoveInPlan.leftovers(in: names, appName: "NeuralLoop.app", anotherMoveRunning: true).isEmpty)
}

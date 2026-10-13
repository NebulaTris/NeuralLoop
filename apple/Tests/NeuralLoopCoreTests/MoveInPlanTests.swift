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

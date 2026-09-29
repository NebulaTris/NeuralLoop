import Testing
@testable import NeuralLoopCore

@Test func pipKnowsWhenItStillNeedsToMoveIn() {
    let home = "/Users/sam"
    #expect(InstallPlace.of("/Applications/NeuralLoop.app", home: home) == .applications)
    #expect(InstallPlace.of("/Users/sam/Applications/NeuralLoop.app", home: home) == .applications)
    #expect(InstallPlace.of("/Volumes/NeuralLoop/NeuralLoop.app", home: home) == .diskImage)
    #expect(InstallPlace.of("/private/var/folders/x/T/AppTranslocation/ABC/d/NeuralLoop.app", home: home) == .temporary)
    #expect(InstallPlace.of("/Users/sam/Downloads/NeuralLoop.app", home: home) == .downloads)
    #expect(InstallPlace.of("/Users/sam/Desktop/NeuralLoop.app", home: home) == .elsewhere)
    #expect(!InstallPlace.applications.needsMove && InstallPlace.downloads.needsMove)
}

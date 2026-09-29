import Foundation
import Testing
@testable import NeuralLoopCore

private func anim(_ json: String) throws -> PipRig.Anim { try JSONDecoder().decode(PipRig.Anim.self, from: Data(json.utf8)) }

@Test func keyframesInterpolateWithTheirEasing() throws {
    let sway = try anim(#"{"dur":2,"ease":[0,0,1,1],"alternate":false,"reverse":false,"rest":{},"keys":[{"t":0},{"t":50,"r":10},{"t":100}]}"#)
    #expect(abs(sway.values(at: 0.5).r - 5) < 0.01)      // a quarter of the way: halfway to 10°, linear
    #expect(abs(sway.values(at: 1).r - 10) < 0.01)
    #expect(abs(sway.values(at: 2.5).r - 5) < 0.01)      // loops
    #expect(sway.values(at: 0).sx == 1 && sway.values(at: 0).o == 1)  // missing values are identity
}

@Test func alternateRunsBackAndDelaysShiftThePhase() throws {
    let wave = try anim(#"{"dur":1,"ease":[0,0,1,1],"alternate":true,"reverse":false,"rest":{},"keys":[{"t":0,"r":-10},{"t":100,"r":10}]}"#)
    #expect(abs(wave.values(at: 0.25).r - -5) < 0.01)
    #expect(abs(wave.values(at: 1.25).r - 5) < 0.01)     // second run goes backwards
    let reversed = try anim(#"{"dur":1,"ease":[0,0,1,1],"alternate":true,"reverse":true,"rest":{},"keys":[{"t":0,"r":-10},{"t":100,"r":10}]}"#)
    #expect(abs(reversed.values(at: 0.25).r - 5) < 0.01)
    #expect(abs(wave.values(at: 0.25, delay: -0.5).r - 5) < 0.01)
}

@Test func easingFollowsTheCubicBezier() {
    let easeInOut = [0.42, 0, 0.58, 1.0]
    #expect(PipRig.ease(easeInOut, 0) == 0 && PipRig.ease(easeInOut, 1) == 1)
    #expect(abs(PipRig.ease(easeInOut, 0.5) - 0.5) < 0.001 && PipRig.ease(easeInOut, 0.2) < 0.2)
}

@Test func aGroupTurnsAroundItsPivotInsideItsOwnFrame() {
    let pivot = Point(100, 50)
    let turn = PipRig.groupTransform(PipRig.Values(r: 90), pivot: pivot, frame: [1, 0, 0, 1])
    let moved = turn.apply(pivot)
    #expect(abs(moved.x - 100) < 1e-9 && abs(moved.y - 50) < 1e-9)  // the pivot stays put
    let tip = turn.apply(Point(110, 50))
    #expect(abs(tip.x - 100) < 1e-9 && abs(tip.y - 60) < 1e-9)
    // In a frame scaled by 2, a 5 px translation moves 10 px in the picture.
    let scaled = PipRig.groupTransform(PipRig.Values(tx: 5), pivot: Point(0, 0), frame: [2, 0, 0, 2]).apply(Point(0, 0))
    #expect(abs(scaled.x - 10) < 1e-9)
}

@Test func theGeneratedRigIsComplete() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../App/Resources/pip-rig.json")
    let rig = try JSONDecoder().decode(PipRig.self, from: Data(contentsOf: url))
    #expect(Set(rig.poses.keys) == ["read", "hop", "nap", "stretch", "play", "hug", "study", "proud"])
    for pose in rig.poses.values {
        #expect(!pose.layers.isEmpty && pose.viewBox.count == 4)
        for layer in pose.layers { #expect(layer.chain.allSatisfy { pose.groups.indices.contains($0) }) }
        for group in pose.groups { #expect(rig.anims[group.anim] != nil) }
    }
    #expect(rig.anims["lids"]?.rest.sy == 0)  // still eyes stay open
}

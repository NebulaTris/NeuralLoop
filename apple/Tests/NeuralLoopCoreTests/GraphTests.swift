import Foundation
import Testing
@testable import NeuralLoopCore

private func edge(_ a: String, _ b: String) -> KnowledgeGraph.Edge {
    KnowledgeGraph.Edge(source: a, target: b, type: "related", description: nil)
}

@Test func chaptersSproutFurtherOutOnASpiral() {
    let center = Point(0, 0)
    #expect(GraphLayout.sproutPoint(0, center: center) == center)
    let first = GraphLayout.sproutPoint(1, center: center)
    let fourth = GraphLayout.sproutPoint(4, center: center)
    #expect(abs(hypot(first.x, first.y) - 420) < 0.001 && abs(hypot(fourth.x, fourth.y) - 840) < 0.001)
}

@Test func theShortestPathFollowsLinksEitherWay() {
    let edges = [edge("a", "b"), edge("c", "b"), edge("c", "d"), edge("a", "d"), edge("x", "y")]
    #expect(GraphLayout.shortestPath(from: "a", to: "c", edges: edges)?.count == 3)
    #expect(GraphLayout.shortestPath(from: "a", to: "a", edges: edges) == ["a"])
    #expect(GraphLayout.shortestPath(from: "a", to: "y", edges: edges) == nil)
}

@Test func linkedIdeasSitCloserAndPinnedIdeasNeverMove() {
    let ids = ["a", "b", "c", "d"]
    let anchors = Dictionary(uniqueKeysWithValues: ids.map { ($0, Point(0, 0)) })
    let pinned = Point(500, 500)
    let layout = GraphLayout.layout(ids: ids, edges: [edge("a", "b")], anchors: anchors, fixed: ["d": pinned])
    func distance(_ x: String, _ y: String) -> Double { hypot(layout[x]!.x - layout[y]!.x, layout[x]!.y - layout[y]!.y) }
    #expect(layout["d"] == pinned)
    #expect(distance("a", "b") < distance("a", "c"))
    #expect(ids.allSatisfy { a in ids.allSatisfy { b in a == b || distance(a, b) > 60 } })
    #expect(GraphLayout.layout(ids: ids, edges: [edge("a", "b")], anchors: anchors, fixed: ["d": pinned]) == layout)
}

@Test func aChapterGraphKeepsItsOwnIdeasLinksAndTour() throws {
    let json = #"""
    {"nodes":[{"id":"c1:a","name":"A","chapter":1,"layerName":"Basics"},{"id":"c1:b","name":"B","chapter":1},{"id":"c2:c","name":"C","chapter":2}],
     "edges":[{"source":"c1:a","target":"c1:b","type":"builds_on"},{"source":"c1:b","target":"c2:c","type":"similar_to"}],
     "tour":[{"title":"Both","nodeIds":["c1:a","c2:c"]}]}
    """#
    let graph = try JSONDecoder().decode(KnowledgeGraph.self, from: Data(json.utf8))
    let one = graph.chapter(1, tour: [TourStep(title: "Start", description: nil, nodeIds: ["a", "gone"])])
    #expect(one.nodes.map(\.id) == ["c1:a", "c1:b"] && one.edges.count == 1 && one.tour.map(\.nodeIds) == [["c1:a"]])
    #expect(graph.only(chapters: [2]).tour.map(\.nodeIds) == [["c2:c"]] && graph.nodes[0].group == "Basics")
}

@Test func repeatedIdeaIdsKeepTheFirstAndDropBrokenLinks() throws {
    let json = #"""
    {"nodes":[{"id":"a","name":"First A","chapter":1},{"id":"b","name":"B","chapter":1},{"id":"a","name":"Second A","chapter":2}],
     "edges":[{"source":"a","target":"b"},{"source":"a","target":"gone"},{"source":"ghost","target":"b"}],
     "tour":[{"title":"Real","nodeIds":["a","gone"]},{"title":"Empty","nodeIds":["gone"]}]}
    """#
    let graph = try JSONDecoder().decode(KnowledgeGraph.self, from: Data(json.utf8))
    #expect(graph.nodes.map(\.id) == ["a", "b"])
    #expect(graph.nodes.first?.name == "First A")
    #expect(graph.edges.count == 1)
    #expect(graph.tour.map(\.title) == ["Real"] && graph.tour.first?.nodeIds == ["a"])
    #expect(graph.only(chapters: [1]).nodes.count == 2)
}

@Test func layoutToleratesRepeatedIds() {
    let layout = GraphLayout.layout(ids: ["a", "b", "a"], edges: [edge("a", "b")], anchors: ["a": Point(0, 0)],
                                    fixed: [:], radius: ["a": 12])
    #expect(layout.count == 2)
}

@Test func aBigMapLaysOutQuicklyWithFinitePositions() {
    let ids = (0..<600).map { "n\($0)" }
    let edges = (1..<600).map { edge("n\($0)", "n\(($0 * 7) % $0)") }
    let anchors = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, GraphLayout.sproutPoint($0 / 50, center: Point(0, 0))) })
    let start = Date()
    let layout = GraphLayout.layout(ids: ids, edges: edges, anchors: anchors)
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(layout.count == 600)
    #expect(layout.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
}

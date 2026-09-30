// Laying out and exploring a knowledge graph: where ideas sit (a small force simulation), where each chapter
// sprouts on the growing book map, and how two ideas are connected.

import Foundation

public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { (self.x, self.y) = (x, y) }
}

public enum GraphLayout {
    static let goldenAngle = 2.39996
    static let ringSpacing = 420.0  // chapters sprout far enough apart to keep their own neighbourhood

    /// Chapter k (0-based, in the order chapters were mapped) sprouts on a golden-angle spiral around the centre.
    public static func sproutPoint(_ k: Int, center: Point) -> Point {
        guard k > 0 else { return center }
        let angle = Double(k) * goldenAngle
        let radius = ringSpacing * Double(k).squareRoot()
        return Point(center.x + radius * cos(angle), center.y + radius * sin(angle))
    }

    /// The shortest chain of links between two ideas (either direction), or nil when they aren't connected.
    public static func shortestPath(from: String, to: String, edges: [KnowledgeGraph.Edge]) -> [String]? {
        guard from != to else { return [from] }
        var neighbours: [String: [String]] = [:]
        for edge in edges {
            neighbours[edge.source, default: []].append(edge.target)
            neighbours[edge.target, default: []].append(edge.source)
        }
        var previous: [String: String] = [from: from]
        var queue = [from]
        var head = 0
        while head < queue.count {
            let at = queue[head]
            head += 1
            for next in neighbours[at] ?? [] where previous[next] == nil {
                previous[next] = at
                if next == to {
                    var path = [to]
                    var step = to
                    while step != from { step = previous[step]!; path.append(step) }
                    return path.reversed()
                }
                queue.append(next)
            }
        }
        return nil
    }

    /// Positions for every idea. `anchors` pull each idea toward a spot (its chapter's sprout point); `fixed` ideas
    /// never move (so the book map keeps its shape as it grows). Deterministic: the same graph lays out the same way.
    public static func layout(
        ids: [String], edges: [KnowledgeGraph.Edge], anchors: [String: Point], fixed: [String: Point] = [:],
        radius: [String: Double] = [:], iterations: Int? = nil
    ) -> [String: Point] {
        var seen = Set<String>()
        let ids = ids.filter { seen.insert($0).inserted }  // a repeated id is one idea
        guard !ids.isEmpty else { return [:] }
        let iterations = iterations ?? defaultIterations(ids.count)
        let index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var position = ids.map { id -> Point in
            if let pinned = fixed[id] { return pinned }
            let anchor = anchors[id] ?? Point(0, 0)
            let (dx, dy) = jitter(id)
            return Point(anchor.x + dx, anchor.y + dy)
        }
        var velocity = Array(repeating: Point(0, 0), count: ids.count)
        let links = edges.compactMap { edge -> (Int, Int)? in
            guard let a = index[edge.source], let b = index[edge.target], a != b else { return nil }
            return (a, b)
        }
        let size = ids.map { radius[$0] ?? 14 }
        let cutoff2 = repulsionCutoff * repulsionCutoff
        var alpha = 1.0
        let cooling = min(0.985, pow(0.02, 1 / Double(max(iterations, 1))))  // fewer rounds cool faster, still settling
        for _ in 0..<iterations {
            var force = Array(repeating: Point(0, 0), count: ids.count)
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    var dx = position[j].x - position[i].x
                    var dy = position[j].y - position[i].y
                    var distance2 = dx * dx + dy * dy
                    if distance2 > cutoff2 { continue }  // far-apart ideas barely push each other: skip them
                    if distance2 < 0.01 { dx = 0.1 * Double(j - i); dy = 0.1; distance2 = dx * dx + dy * dy }
                    let distance = distance2.squareRoot()
                    var push = 9000 / distance2  // everyone keeps some room (labels sit under the shapes)
                    let touching = size[i] + size[j] + 70
                    if distance < touching { push += (touching - distance) * 0.5 }  // and never overlaps
                    force[i].x -= push * dx / distance; force[i].y -= push * dy / distance
                    force[j].x += push * dx / distance; force[j].y += push * dy / distance
                }
            }
            for (a, b) in links {  // linked ideas like to sit about 140 points apart
                let dx = position[b].x - position[a].x
                let dy = position[b].y - position[a].y
                let distance = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let pull = (distance - 140) * 0.05
                force[a].x += pull * dx / distance; force[a].y += pull * dy / distance
                force[b].x -= pull * dx / distance; force[b].y -= pull * dy / distance
            }
            for i in 0..<ids.count where fixed[ids[i]] == nil {
                let anchor = anchors[ids[i]] ?? Point(0, 0)
                force[i].x += (anchor.x - position[i].x) * 0.03
                force[i].y += (anchor.y - position[i].y) * 0.03
                velocity[i].x = (velocity[i].x + force[i].x * alpha) * 0.6
                velocity[i].y = (velocity[i].y + force[i].y * alpha) * 0.6
                position[i].x += max(-30, min(30, velocity[i].x))
                position[i].y += max(-30, min(30, velocity[i].y))
            }
            alpha = max(0.02, alpha * cooling)
        }
        return Dictionary(zip(ids, position), uniquingKeysWith: { first, _ in first })
    }

    /// Beyond this distance two ideas no longer push each other (9000 / d² is already tiny there).
    static let repulsionCutoff = 900.0

    /// Big maps settle with fewer rounds: each round costs n², so the total work stays about the same beyond 100 ideas.
    static func defaultIterations(_ count: Int) -> Int {
        guard count > 100 else { return 300 }
        return max(60, Int(300 * 10_000 / Double(count * count)))
    }

    /// A small, stable offset per id, so ideas that share an anchor start apart (and the layout is repeatable).
    static func jitter(_ id: String) -> (Double, Double) {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let a = Double(hash & 0xFFFF) / 65535 - 0.5
        let b = Double((hash >> 16) & 0xFFFF) / 65535 - 0.5
        return (a * 40, b * 40)
    }
}

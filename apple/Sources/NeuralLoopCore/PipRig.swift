// Pip's rig (pip-rig.json, written by design/pip/generate_pip.py): every pose as ordered layers, each animated group's
// pivot and frame, and the keyframes. This file plays them: the same timing, easing, and nesting CSS gives the videos.

import Foundation

public struct PipRig: Decodable, Sendable {
    public struct Group: Decodable, Sendable {
        public let anim: String
        public let delay: Double
        public let pivot: [Double]
        public let frame: [Double]   // the group's own axes in the picture (a, b, c, d)
    }

    public struct Layer: Decodable, Sendable {
        public let svg: String
        public let chain: [Int]      // animated groups this layer sits in, outermost first
    }

    public struct Pose: Decodable, Sendable {
        public let label: String
        public let viewBox: [Double]
        public let groups: [Group]
        public let layers: [Layer]
    }

    /// One moment of an animation: translate (px), rotate (degrees), scale, opacity.
    public struct Values: Decodable, Equatable, Sendable {
        public var tx = 0.0, ty = 0.0, r = 0.0, sx = 1.0, sy = 1.0, o = 1.0
        public init(tx: Double = 0, ty: Double = 0, r: Double = 0, sx: Double = 1, sy: Double = 1, o: Double = 1) {
            (self.tx, self.ty, self.r, self.sx, self.sy, self.o) = (tx, ty, r, sx, sy, o)
        }
        enum CodingKeys: String, CodingKey { case tx, ty, r, sx, sy, o }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tx = try c.decodeIfPresent(Double.self, forKey: .tx) ?? 0
            ty = try c.decodeIfPresent(Double.self, forKey: .ty) ?? 0
            r = try c.decodeIfPresent(Double.self, forKey: .r) ?? 0
            sx = try c.decodeIfPresent(Double.self, forKey: .sx) ?? 1
            sy = try c.decodeIfPresent(Double.self, forKey: .sy) ?? 1
            o = try c.decodeIfPresent(Double.self, forKey: .o) ?? 1
        }

        static func mix(_ a: Values, _ b: Values, _ f: Double) -> Values {
            func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
            return Values(tx: m(a.tx, b.tx), ty: m(a.ty, b.ty), r: m(a.r, b.r), sx: m(a.sx, b.sx), sy: m(a.sy, b.sy), o: m(a.o, b.o))
        }
    }

    public struct Key: Decodable, Sendable {
        public let t: Double
        public let values: Values
        enum CodingKeys: String, CodingKey { case t }
        public init(from decoder: Decoder) throws {
            t = try decoder.container(keyedBy: CodingKeys.self).decode(Double.self, forKey: .t)
            values = try Values(from: decoder)
        }
    }

    public struct Anim: Decodable, Sendable {
        public let dur: Double
        public let ease: [Double]
        public let alternate: Bool
        public let reverse: Bool
        public let rest: Values
        public let keys: [Key]

        /// The values `seconds` into the animation (a negative delay starts it part-way through, like CSS).
        public func values(at seconds: Double, delay: Double = 0) -> Values {
            guard dur > 0, let first = keys.first, let last = keys.last else { return rest }
            let run = (seconds - delay) / dur
            let iteration = floor(run)
            var fraction = run - iteration
            let odd = Int(iteration) % 2 != 0
            if alternate && (reverse ? !odd : odd) { fraction = 1 - fraction }
            let at = fraction * 100
            if at <= first.t { return first.values }
            if at >= last.t { return last.values }
            let upper = keys.firstIndex { $0.t >= at } ?? keys.count - 1
            let a = keys[upper - 1], b = keys[upper]
            let local = b.t > a.t ? (at - a.t) / (b.t - a.t) : 1
            return Values.mix(a.values, b.values, PipRig.ease(ease, local))
        }
    }

    public let poses: [String: Pose]
    public let anims: [String: Anim]
    public let icon: String

    /// CSS cubic-bezier timing: solve x(u) = t for u, return y(u).
    public static func ease(_ curve: [Double], _ t: Double) -> Double {
        guard curve.count == 4, t > 0, t < 1 else { return min(max(t, 0), 1) }
        let (x1, y1, x2, y2) = (curve[0], curve[1], curve[2], curve[3])
        func bezier(_ u: Double, _ p1: Double, _ p2: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
        }
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<40 {
            let x = bezier(u, x1, x2)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = u } else { hi = u }
            u = (lo + hi) / 2
        }
        return bezier(u, y1, y2)
    }

    /// A group's animation as a transform of the whole picture: around its pivot, inside its own frame.
    public static func groupTransform(_ v: Values, pivot: Point, frame: [Double]) -> Affine {
        let axes = frame.count == 4 ? Affine(a: frame[0], b: frame[1], c: frame[2], d: frame[3], tx: 0, ty: 0) : .identity
        let angle = v.r * .pi / 180
        let motion = Affine(a: 1, b: 0, c: 0, d: 1, tx: v.tx, ty: v.ty)
            .then(before: Affine(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), tx: 0, ty: 0))
            .then(before: Affine(a: v.sx, b: 0, c: 0, d: v.sy, tx: 0, ty: 0))
        return Affine(a: 1, b: 0, c: 0, d: 1, tx: pivot.x, ty: pivot.y)
            .then(before: axes).then(before: motion).then(before: axes.inverted)
            .then(before: Affine(a: 1, b: 0, c: 0, d: 1, tx: -pivot.x, ty: -pivot.y))
    }

    /// Where a layer is drawn at `seconds`: its groups' transforms nested outermost first, and their combined opacity.
    /// `still` uses each animation's resting values (Reduce Motion, screenshots).
    public func layerState(_ layer: Layer, in pose: Pose, at seconds: Double, still: Bool = false) -> (Affine, Double) {
        var transform = Affine.identity
        var opacity = 1.0
        for index in layer.chain {
            let group = pose.groups[index]
            guard let anim = anims[group.anim], group.pivot.count == 2 else { continue }
            let v = still ? anim.rest : anim.values(at: seconds, delay: group.delay)
            transform = transform.then(before: Self.groupTransform(v, pivot: Point(group.pivot[0], group.pivot[1]), frame: group.frame))
            opacity *= v.o
        }
        return (transform, opacity)
    }
}

/// A 2D affine transform (the same layout as CGAffineTransform: x' = a·x + c·y + tx, y' = b·x + d·y + ty).
public struct Affine: Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) { (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty) }
    public static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// self · other: `other` is applied first, then self.
    public func then(before other: Affine) -> Affine {
        Affine(a: a * other.a + c * other.b, b: b * other.a + d * other.b,
               c: a * other.c + c * other.d, d: b * other.c + d * other.d,
               tx: a * other.tx + c * other.ty + tx, ty: b * other.tx + d * other.ty + ty)
    }

    public var inverted: Affine {
        let det = a * d - b * c
        guard det != 0 else { return .identity }
        return Affine(a: d / det, b: -b / det, c: -c / det, d: a / det, tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det)
    }

    public func apply(_ p: Point) -> Point { Point(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }
}

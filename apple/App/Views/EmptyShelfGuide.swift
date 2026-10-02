// The empty shelf, as a little picture of what to do (like the disk image's "drag me into Applications"): your book
// on the left, a dotted "whee!" arc with paw prints, and Pip waiting in a dashed drop zone on the right. A tiny copy
// of the book flies along the arc and Pip hops when it lands, on a loop. Reduce Motion shows it resting mid-flight.
// Narrower than the scene needs (iPad Slide Over, a thin Split View), the whole picture shrinks to fit.

import SwiftUI

struct EmptyShelfGuide: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let period = 3.6  // seconds per flight
    static let height: CGFloat = 250
    static let minWidth: CGFloat = 440  // two 150 pt tiles and the narrowest arc between them

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0.45 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
            FitWidth(minWidth: Self.minWidth, height: Self.height) {
                GeometryReader { geo in
                    let width = max(geo.size.width, Self.minWidth)
                    scene(width: width, t: t)
                        .frame(width: width, height: Self.height)
                        .scaleEffect(Self.scale(for: geo.size.width), anchor: .topLeading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drag a PDF or EPUB book onto this window, and Pip puts it on your shelf.")
    }

    // MARK: Layout

    private func scene(width: CGFloat, t: Double) -> some View {
        let tile = CGSize(width: 150, height: 150)
        let gap = min(max(width - tile.width * 2 - 40, 140), 420)
        let left = CGPoint(x: width / 2 - gap / 2 - tile.width / 2, y: 120)
        let right = CGPoint(x: width / 2 + gap / 2 + tile.width / 2, y: 120)
        let start = CGPoint(x: left.x + tile.width / 2 - 6, y: left.y - 18)
        let end = CGPoint(x: right.x - tile.width / 2 + 10, y: right.y - 6)
        let peak = CGPoint(x: (start.x + end.x) / 2, y: 4)
        let flight = Self.flight(t)
        let landed = t > 0.78

        return ZStack {
            Arc(start: start, control: peak, end: end)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.1, 12]))
            ArrowHead(at: end, from: Self.point(0.9, start, peak, end))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            ForEach([0.22, 0.42, 0.62], id: \.self) { s in
                Image(systemName: "pawprint.fill").font(.system(size: 15)).foregroundStyle(Theme.accent.opacity(0.35))
                    .rotationEffect(.degrees(-30 + s * 60))
                    .position(Self.point(s, start, peak, end).applying(.init(translationX: 0, y: -16)))
            }
            Text("whee!").font(Theme.display(20)).foregroundStyle(Theme.accent)
                .rotationEffect(.degrees(-4))
                .position(x: peak.x, y: Self.point(0.5, start, peak, end).y - 32)
                .opacity(reduceMotion ? 1 : (flight > 0.3 && flight < 0.75 ? 1 : 0.35))

            // Your book, waiting on the left.
            tileBackground.frame(width: tile.width, height: tile.height).position(left)
            BookFile().scaleEffect(t < 0.12 && !reduceMotion ? 1.06 : 1).position(left)
            Text("your book").font(Theme.display(15)).foregroundStyle(Theme.accent).position(x: left.x, y: left.y + tile.height / 2 + 20)

            // Pip's shelf, the drop zone on the right.
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.surface.opacity(0.7))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(landed ? 0.9 : 0.55), style: StrokeStyle(lineWidth: 3, dash: [9, 7])))
                .frame(width: tile.width, height: tile.height).position(right)
            PipView(pose: landed ? .hop : .read, size: 118, interactive: false).position(x: right.x, y: right.y + 6)
            Text("drop it here ✨").font(Theme.display(15)).foregroundStyle(Theme.accent).position(x: right.x, y: right.y + tile.height / 2 + 20)

            // The flying copy.
            if flight > 0 && flight < 1 {
                BookFile().scaleEffect(0.5 - 0.12 * max(0, flight - 0.85) / 0.15)
                    .rotationEffect(.degrees(-14 + 28 * flight))
                    .opacity(flight > 0.9 ? (1 - flight) * 10 : 1)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
                    .position(Self.point(flight, start, peak, end))
            }
        }
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.surface)
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
    }

    /// How much the scene shrinks to fit `width` (1 when it fits as drawn).
    static func scale(for width: CGFloat) -> CGFloat {
        width > 0 ? min(1, width / minWidth) : 1
    }

    /// Where the flying book is along the arc (0…1), or outside it while it waits or after it lands.
    static func flight(_ t: Double) -> Double {
        let from = 0.14, to = 0.8
        guard t > from else { return 0 }
        guard t < to else { return 1 }
        let x = (t - from) / (to - from)
        return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2  // ease in and out
    }

    static func point(_ s: Double, _ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
        let u = 1 - s
        return CGPoint(x: u * u * a.x + 2 * u * s * c.x + s * s * b.x, y: u * u * a.y + 2 * u * s * c.y + s * s * b.y)
    }
}

/// A book file: a page with a folded corner, a few lines, and a PDF tag.
private struct BookFile: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Page().fill(Color.white).overlay(Page().stroke(Theme.ink.opacity(0.75), lineWidth: 2.5))
            Corner().fill(Theme.accentSoft).overlay(Corner().stroke(Theme.ink.opacity(0.75), lineWidth: 2.5))
            VStack(alignment: .leading, spacing: 6) {
                ForEach([34.0, 40, 26], id: \.self) { w in Capsule().fill(Theme.sky.opacity(0.55)).frame(width: w, height: 4) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.top, 26).padding(.leading, 12)
            Text("PDF").font(Theme.display(12, .bold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2).background(Theme.accent, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10)
        }
        .frame(width: 64, height: 80)
    }

    struct Page: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + 8, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - 18, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 18))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 8))
            p.addQuadCurve(to: CGPoint(x: r.maxX - 8, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + 8, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 8), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + 8))
            p.addQuadCurve(to: CGPoint(x: r.minX + 8, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }

    struct Corner: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.maxX - 18, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - 18, y: r.minY + 18))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 18))
            p.closeSubpath()
            return p
        }
    }
}

/// Takes the width it's offered and is as tall as the scene at that width: `height`, or less once it has to shrink.
private struct FitWidth: Layout {
    let minWidth: CGFloat, height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width.map { $0.isFinite ? $0 : minWidth } ?? minWidth
        return CGSize(width: width, height: height * EmptyShelfGuide.scale(for: width))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

private struct Arc: Shape {
    let start: CGPoint, control: CGPoint, end: CGPoint
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: start)
        p.addQuadCurve(to: end, control: control)
        return p
    }
}

private struct ArrowHead: Shape {
    let at: CGPoint, from: CGPoint
    func path(in _: CGRect) -> Path {
        let angle = atan2(at.y - from.y, at.x - from.x)
        var p = Path()
        for side in [-1.0, 1.0] {
            let a = angle + .pi + side * 0.55
            p.move(to: at)
            p.addLine(to: CGPoint(x: at.x + 24 * cos(a), y: at.y + 24 * sin(a)))
        }
        return p
    }
}

/// The three steps under the picture: side by side, or one under another when there isn't room.
struct EmptyShelfSteps: View {
    let steps: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    // Ideally 170 pt each, so the row stays until a step would be squeezed narrower than that.
                    item(i, step).frame(idealWidth: 170, maxWidth: 230, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in item(i, step) }
            }
        }
    }

    private func item(_ i: Int, _ step: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(i + 1)").font(Theme.display(14, .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
            Text(step).font(Theme.body(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

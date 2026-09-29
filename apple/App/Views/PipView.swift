// Pip, drawn natively from the rig (Resources/pip-rig.json, written by design/pip/generate_pip.py): every pose is a
// stack of vector layers, and each animated part (tail, ears, eyelids, head, arms, stars, hearts…) moves around its
// own pivot, nested like the artwork (the eyelids ride on the tilting head). Reduce Motion shows Pip resting.
// On top: every Pip keeps its own rhythm, springs when its pose changes, wiggles when you hover, and pops hearts
// when you click.

import AppKit
import NeuralLoopCore
import SwiftUI

enum PipPose: String, CaseIterable { case read, hop, nap, stretch, play, hug, study, proud }

@MainActor
enum PipArt {
    static let rig: PipRig? = {
        guard let url = Bundle.main.url(forResource: "pip-rig", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PipRig.self, from: data)
    }()

    /// Each pose's layers as vector images, made once.
    static let layers: [String: [NSImage]] = {
        guard let rig else { return [:] }
        return rig.poses.mapValues { pose in pose.layers.map { NSImage(data: Data($0.svg.utf8)) ?? NSImage() } }
    }()

    /// Each pose's layers as bitmaps for one pixel width, made once and reused (moving bitmaps is cheap; redrawing
    /// the vector artwork every frame isn't).
    private static var bitmaps: [String: [CGImage]] = [:]

    static func bitmaps(for pose: String, pixelWidth: Int, box: CGSize) -> [CGImage] {
        let width = max(32, (pixelWidth + 31) / 32 * 32)  // a few sizes, not one per point
        let key = "\(pose)@\(width)"
        if let cached = bitmaps[key] { return cached }
        let height = Int((Double(width) * box.height / box.width).rounded())
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        let made = (layers[pose] ?? []).compactMap { image -> CGImage? in
            image.size = NSSize(width: width, height: height)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        bitmaps[key] = made
        return made
    }

    /// Pip's head, sized for the menu bar (18 pt tall).
    static let icon: NSImage? = {
        guard let svg = rig?.icon, let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.size = NSSize(width: 19, height: 18)
        return image
    }()
}

struct PipView: View {
    var pose: PipPose = .read
    var size: CGFloat = 140
    /// Hover wiggle and click hearts. Off where Pip sits inside a button (book covers).
    var interactive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var phase = Double.random(in: 0..<60)  // Pips on the same screen never move in sync
    @State private var hovering = false
    @State private var boing: CGFloat = 1
    @State private var hearts: [HeartPop] = []

    var body: some View {
        // 30 frames a second is plenty for Pip's gentle loops.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate + phase
            Canvas { context, canvas in draw(in: &context, size: canvas, at: t) }
        }
        .frame(width: size, height: size * 0.92)
        .scaleEffect(x: 2 - boing, y: boing, anchor: .bottom)
        .offset(y: hovering && !reduceMotion ? -size * 0.035 : 0)
        .rotationEffect(.degrees(hovering && !reduceMotion ? -3 : 0), anchor: .bottom)
        .overlay { ForEach(hearts) { HeartView(pop: $0, size: size) } }
        .onHover { inside in
            guard interactive else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { hovering = inside }
        }
        .onTapGesture { if interactive { popHeart() } }
        .onChange(of: pose) { springIn() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PipArt.rig?.poses[pose.rawValue]?.label ?? "Pip")
    }

    private func draw(in context: inout GraphicsContext, size canvas: CGSize, at t: Double) {
        guard let rig = PipArt.rig, let rigPose = rig.poses[pose.rawValue], rigPose.viewBox.count == 4 else { return }
        let box = CGRect(x: rigPose.viewBox[0], y: rigPose.viewBox[1], width: rigPose.viewBox[2], height: rigPose.viewBox[3])
        let scale = min(canvas.width / box.width, canvas.height / box.height)
        // A little headroom so scaled-up parts (hops, puffs) stay sharp.
        let images = PipArt.bitmaps(for: pose.rawValue, pixelWidth: Int(box.width * scale * displayScale * 1.25), box: box.size)
        context.translateBy(x: (canvas.width - box.width * scale) / 2 - box.minX * scale,
                            y: (canvas.height - box.height * scale) / 2 - box.minY * scale)
        context.scaleBy(x: scale, y: scale)
        for (index, layer) in rigPose.layers.enumerated() where index < images.count {
            let (m, opacity) = rig.layerState(layer, in: rigPose, at: t, still: reduceMotion)
            guard opacity > 0.01 else { continue }
            var layerContext = context
            layerContext.concatenate(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
            layerContext.opacity = opacity
            layerContext.draw(Image(decorative: images[index], scale: 1), in: box)
        }
    }

    /// A squash then a springy bounce back, whenever Pip changes what it's doing.
    private func springIn() {
        guard !reduceMotion else { return }
        boing = 0.86
        withAnimation(.spring(response: 0.45, dampingFraction: 0.42)) { boing = 1 }
    }

    private func popHeart() {
        guard !reduceMotion else { return }
        springIn()
        let pop = HeartPop(x: .random(in: -0.22...0.22))
        hearts.append(pop)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { hearts.removeAll { $0.id == pop.id } }
    }
}

struct HeartPop: Identifiable {
    let id = UUID()
    let x: CGFloat
}

/// A little heart that floats up from Pip and fades.
private struct HeartView: View {
    let pop: HeartPop
    let size: CGFloat
    @State private var risen = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: max(10, size * 0.12)))
            .foregroundStyle(Theme.color(light: 0xF29AA6, dark: 0xF29AA6))
            .offset(x: pop.x * size, y: risen ? -size * 0.55 : -size * 0.2)
            .scaleEffect(risen ? 1.1 : 0.4)
            .opacity(risen ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 1.3)) { risen = true } }
            .allowsHitTesting(false)
    }
}

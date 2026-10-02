// Pip, drawn natively from the rig (Resources/pip-rig.json and Resources/PipLayers/*.png, written by
// design/pip/generate_pip.py): every pose is a stack of transparent layers drawn at 3x, and each animated part (tail,
// ears, eyelids, head, arms, stars, hearts…) moves around its own pivot, nested like the artwork (the eyelids ride on the
// tilting head). Reduce Motion shows Pip resting. On top: every Pip keeps its own rhythm, springs when its pose changes,
// wiggles when you hover (Mac), and pops hearts when you click or tap.

import ImageIO
import NeuralLoopCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum PipPose: String, CaseIterable { case read, hop, nap, stretch, play, hug, study, proud, sad, shocked }

@MainActor
enum PipArt {
    static let rig: PipRig? = {
        guard let url = Bundle.main.url(forResource: "pip-rig", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PipRig.self, from: data)
    }()

    /// A PNG from PipLayers/ as a bitmap, read once and reused (moving bitmaps is cheap; drawing artwork every frame isn't).
    private static var cache: [String: CGImage] = [:]

    static func image(_ name: String) -> CGImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "PipLayers"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        cache[name] = image
        return image
    }

    /// Each pose's layers, in drawing order, at about `pixelWidth` pixels wide: scaled down once per size and reused, so
    /// a small Pip never resamples the full 3x pictures on every frame.
    private static var scaled: [String: [CGImage]] = [:]

    static func layers(for pose: String, pixelWidth: Int) -> [CGImage] {
        let full = (rig?.poses[pose]?.layers ?? []).compactMap { image($0.image) }
        guard let first = full.first else { return [] }
        let width = max(32, (pixelWidth + 31) / 32 * 32)  // a few sizes, not one per point
        guard width < first.width else { return full }
        let key = "\(pose)@\(width)"
        if let cached = scaled[key] { return cached }
        let height = Int((Double(width) * Double(first.height) / Double(first.width)).rounded())
        let made = full.map { layer -> CGImage in
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return layer }
            context.interpolationQuality = .high
            context.draw(layer, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage() ?? layer
        }
        scaled[key] = made
        return made
    }

    /// Pip's head as a bitmap (3x), for avatars on every platform.
    static var iconImage: CGImage? { rig.flatMap { image($0.iconImage) } }

    #if os(macOS)
    /// Pip's head for the menu bar (18 pt tall): the vector version when the rig has it, else the 3x PNG.
    static let icon: NSImage? = {
        let size = NSSize(width: rig?.iconSize.first ?? 19, height: rig?.iconSize.last ?? 18)
        if let svg = rig?.icon, let image = NSImage(data: Data(svg.utf8)) {
            image.size = size
            return image
        }
        guard let bitmap = iconImage else { return nil }
        return NSImage(cgImage: bitmap, size: size)
    }()
    #endif
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
        #if os(macOS)
        .onHover { inside in
            guard interactive else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { hovering = inside }
        }
        #endif
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
        let images = PipArt.layers(for: pose.rawValue, pixelWidth: Int(box.width * scale * displayScale * 1.25))
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

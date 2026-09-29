// Pip, drawn from the generated artwork (Resources/pip-poses.js, written by design/pip/generate_pip.py).
// For now the whole pose breathes and bobs; the per-part rig (blinks, tail sway) comes with spec 04's pip-rig.json.

import AppKit
import SwiftUI

enum PipPose: String, CaseIterable { case read, hop, nap, stretch, play, hug, study, proud }

@MainActor
enum PipArt {
    /// Pip's head, sized for the menu bar (18 pt tall).
    static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "pip-poses", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let start = text.range(of: "window.PIP="), let end = text.range(of: ";\nwindow.PIP_CSS="),
              let poses = try? JSONSerialization.jsonObject(with: Data(text[start.upperBound..<end.lowerBound].utf8)) as? [String: String],
              let svg = poses["icon"]
        else { return nil }
        let sized = svg.replacingOccurrences(of: "width=\"100%\"", with: "width=\"38\" height=\"36\"")
        guard let image = NSImage(data: Data(sized.utf8)) else { return nil }
        image.size = NSSize(width: 19, height: 18)
        return image
    }()

    static let images: [String: NSImage] = {
        guard let url = Bundle.main.url(forResource: "pip-poses", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let start = text.range(of: "window.PIP="), let end = text.range(of: ";\nwindow.PIP_CSS=")
        else { return [:] }
        let json = String(text[start.upperBound..<end.lowerBound])
        guard let poses = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] else { return [:] }
        return poses.compactMapValues { svg in
            // The artwork scales with its container; give NSImage a fixed canvas to rasterise.
            let sized = svg.replacingOccurrences(of: "width=\"100%\"", with: "width=\"480\" height=\"440\"")
            return NSImage(data: Data(sized.utf8))
        }
    }()
}

struct PipView: View {
    var pose: PipPose = .read
    var size: CGFloat = 140
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breathe = reduceMotion ? 1 : 1 + 0.018 * sin(t * 1.7)
            let bob = reduceMotion ? 0 : (pose == .hop ? -abs(sin(t * 3.2)) * 10 : sin(t * 1.1) * 1.5)
            Group {
                if let image = PipArt.images[pose.rawValue] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Text("🐾").font(.system(size: size / 2))
                }
            }
            .scaleEffect(x: 1, y: breathe, anchor: .bottom)
            .offset(y: bob)
        }
        .frame(width: size, height: size * 0.92)
        .accessibilityLabel("Pip \(pose.rawValue == "read" ? "reading a book" : pose.rawValue)")
    }
}

// NeuralLoop's colours and type , light and dark.

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Theme {
    static func color(light: UInt32, dark: UInt32) -> Color {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = rgb(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }

    static let paper = color(light: 0xFFF7F2, dark: 0x1D1716)
    static let surface = color(light: 0xFFFFFF, dark: 0x2A2220)
    static let sunk = color(light: 0xFCEDE6, dark: 0x241D1B)
    static let ink = color(light: 0x35251F, dark: 0xFBEFEA)
    static let ink2 = color(light: 0x6E5A52, dark: 0xCDB9B1)
    static let ink3 = color(light: 0xA08E86, dark: 0x9A867E)
    static let line = color(light: 0xF1DDD3, dark: 0x3E3230)
    static let accent = color(light: 0xE0683F, dark: 0xF2875F)
    static let accentSoft = color(light: 0xFDE3D7, dark: 0x4A2B20)
    static let mint = color(light: 0x3FA88A, dark: 0x5CCBA9)
    static let mintSoft = color(light: 0xDDF3EA, dark: 0x1F3A33)
    static let sky = color(light: 0x5C86E0, dark: 0x86A8F2)
    static let skySoft = color(light: 0xE3ECFF, dark: 0x23304D)
    static let butter = color(light: 0xF2B640, dark: 0xF5C25C)
    static let butterSoft = color(light: 0xFCEFCF, dark: 0x3E331A)
    static let rose = color(light: 0xE2577E, dark: 0xF07E9E)
    static let roseSoft = color(light: 0xFDE2EA, dark: 0x462330)

    /// Fredoka's static faces are named "FredokaLight-…" inside the font files; pick the face by its PostScript name.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        let face = weight == .medium ? "FredokaLight-Medium" : weight == .regular ? "FredokaLight-Regular" : "FredokaLight-SemiBold"
        return .custom(face, size: size)
    }

    static func body(_ size: CGFloat = 15) -> Font { .custom("AtkinsonHyperlegible-Regular", size: size) }
}

/// A rounded card on the paper ground.
struct CardBox<Content: View>: View {
    var fill: Color = Theme.surface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }
}

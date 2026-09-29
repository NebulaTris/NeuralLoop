// Where the app is running from, so Pip can offer to move into Applications when it's still in Downloads or on the
// disk image (macOS runs downloaded apps from a hidden temporary copy until they're moved).

import Foundation

public enum InstallPlace: Equatable, Sendable {
    case applications, diskImage, downloads, temporary, elsewhere

    public static func of(_ path: String, home: String = NSHomeDirectory()) -> InstallPlace {
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        if path.contains("/AppTranslocation/") { return .temporary }
        if path.hasPrefix(home + "/Downloads/") { return .downloads }
        return .elsewhere
    }

    public var needsMove: Bool { self != .applications }

    /// Where Pip is right now, in words ("I'm running from …").
    public var words: String {
        switch self {
        case .applications: "Applications"
        case .diskImage: "the disk image"
        case .downloads, .temporary: "your Downloads"
        case .elsewhere: "a spot outside Applications"
        }
    }
}

// The book card's short line when an automatic run ended badly, by the pipeline's exit code and its last lines
// (`tail`): what happened and what would help.

public enum RunProblemText {
    public static func card(code: Int32, tail: [String] = []) -> String {
        switch code {
        case 2:
            // Exit 2 is also chapters asked for that didn't make sense (the pipeline's `parse_selection` messages),
            // which isn't about the file itself. (Another run already having the book is never a problem: the app
            // shows nothing for it, `Library.outcome`.)
            if tail.contains(where: { $0.hasPrefix("Invalid chapter selection") || $0.hasPrefix("Invalid range") }) {
                return "Pip got mixed up about which chapters to prepare. Open the book and choose Prepare more to prepare them all."
            }
            return "Pip couldn't read this book. Try a different PDF or EPUB copy."
        case 3: return "Pip needs a little setup first. Open Settings to sign in to Google or choose your AI."
        // Other failures back off and start again by themselves (`AutoResume.mayStart`).
        default: return "Pip hit a snag and will try again on its own in a little while."
        }
    }
}

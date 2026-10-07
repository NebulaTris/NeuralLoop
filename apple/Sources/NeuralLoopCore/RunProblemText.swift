// The book card's short line when an automatic run ended badly, by the pipeline's exit code: what would help.

public enum RunProblemText {
    public static func card(code: Int32) -> String {
        switch code {
        case 2: "Pip couldn't read this book. Try a different PDF or EPUB copy."
        case 3: "Pip needs a little setup first. Open Settings to sign in to Google or choose your AI."
        default: "Pip hit a snag. Open the book and choose Prepare more."
        }
    }
}

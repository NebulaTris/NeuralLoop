"""Constants shared across the pipeline."""

import re

# Every chapter gets these items; "audio" and "video" only for chapters selected with --media.
TASKS = ("study", "graph", "quiz", "cards", "mindmap", "audio", "video")
MEDIA_TASKS = frozenset({"audio", "video"})

AUDIO_FORMATS = {"deep-dive": "DEEP_DIVE", "brief": "BRIEF", "critique": "CRITIQUE", "debate": "DEBATE"}
AUDIO_LENGTHS = ("auto", "short", "default", "long")
SHORT_CHAPTER_CHARS = (
    30_000  # about 12 pages: less than this makes a short podcast, which is also quicker to make
)


def audio_length(choice: str, chars: int) -> str:
    """The podcast length for a chapter: the person's choice, or ("auto") short for short chapters."""
    if choice in ("short", "default", "long"):
        return choice
    return "short" if chars <= SHORT_CHAPTER_CHARS else "default"


VIDEO_FORMATS = {"explainer": "EXPLAINER", "brief": "BRIEF", "short": "SHORT"}
VIDEO_STYLES = {
    "auto": "AUTO_SELECT",
    "classic": "CLASSIC",
    "whiteboard": "WHITEBOARD",
    "kawaii": "KAWAII",
    "anime": "ANIME",
    "watercolor": "WATERCOLOR",
    "retro-print": "RETRO_PRINT",
    "heritage": "HERITAGE",
    "paper-craft": "PAPER_CRAFT",
}

# Pages around the chapters that aren't worth a learning loop: front matter, reading guides, and back matter.
# Each must be the whole title (trailing punctuation aside): "Index", but not "Index structures"; "Notes", but
# not "Notes on caching". Reading guides are about *this* book: "How to read this book", not "How to Read a
# Person Like a Book".
_BACK = r"(?:notes|endnotes|references|sources|bibliography|further reading|glossary)"
FRONT_MATTER = re.compile(
    r"^\s*(?:"
    r"cover|front cover|back cover|title page|half title|copyright(?: page)?|dedication|epigraph|colophon|"
    r"(?:table of )?contents|brief contents|contents at a glance|index|about the authors?|about this book|"
    r"acknowledge?ments?|praise|praise for (?:this book|the book|.*\bedition)|also by\b.*|other books by\b.*|"
    r"list of (?:figures|tables|illustrations|abbreviations)|"
    r"how to (?:use|read|get the most (?:out )?of|make the most (?:out )?of) this book\b.*|"
    rf"{_BACK}(?:\s*(?:and|&)\s*{_BACK})?"
    r")[\s.:;!?]*$",
    re.IGNORECASE,
)
# Appendices: kept as chapters when they're substantial (a forty-page tutorial), skipped when they're short.
APPENDIX = re.compile(r"^\s*(?:appendix\b|appendices[\s.:;!?]*$)", re.IGNORECASE)

# EPUB figures: at most this many bytes of pictures are copied out of one book (each picture once, however
# many chapters show it); figures past it become their alt text.
MAX_BOOK_IMAGE_BYTES = 200_000_000

# Timeouts in seconds. NotebookLM media generation is slow.
SOURCE_TIMEOUT = 900.0
LIGHT_TIMEOUT = 900.0
AUDIO_TIMEOUT = 2400.0
VIDEO_TIMEOUT = 3600.0
# NotebookLM is sometimes slow or drops a connection mid-item: pause and try again this many times before
# giving up (a podcast or video already asked for is waited for again, never asked for twice). Then the item
# waits for the next run instead of failing.
NOTEBOOKLM_RETRY_DELAYS = (20, 60, 120)
# Google's session cookie can rotate more than once during an hour-long video: reload it up to this many times
# per item before the item gives up (a podcast or video then waits for the next run).
NOTEBOOKLM_SESSION_RELOADS = 3


def quota_message(engine_name: str) -> str:
    return f"{engine_name} is at its limit for now. Pip will try again when it resets."


# The local engine's text models. Keys are read from these environment variables only.
PROVIDERS = ("auto", "anthropic", "openai", "openrouter", "custom", "ollama", "opencode", "hermes", "fake")
PROVIDER_KEYS = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
}
DEFAULT_MODELS = {
    "anthropic": "claude-opus-5-5",
    "openai": "gpt-6-sol",
    "openrouter": "deepseek/deepseek-v4.1-flash",
    # opencode and hermes: whatever the person set up in them; custom: you name it
    # ollama: the first model already installed
}
# How much chapter text (characters) goes to a model at once; longer chapters are condensed into notes first.
CONTEXT_CHARS = {
    "custom": 100_000,
    "hermes": 100_000,
    "anthropic": 400_000,
    "openai": 400_000,
    "openrouter": 400_000,
    "ollama": 24_000,
    "opencode": 24_000,
}
LOCAL_PROVIDERS = frozenset({"ollama", "opencode", "hermes"})  # one item at a time by default
SPEECH_ENGINES = ("auto", "rumik", "fake")
DEFAULT_INSTRUCTIONS = (
    "A friendly deep-dive for software engineers: section by section, "
    "concrete analogies and real engineering examples."
)

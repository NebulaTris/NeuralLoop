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

FRONT_MATTER = re.compile(
    r"^\s*(cover|title page|half title|copyright|table of contents|contents|brief contents|index|"
    r"about the authors?|acknowledge?ments?|colophon|praise for|also by|dedication|other books|"
    r"list of (figures|tables))\b",
    re.IGNORECASE,
)

# Timeouts in seconds. NotebookLM media generation is slow.
SOURCE_TIMEOUT = 900.0
LIGHT_TIMEOUT = 900.0
AUDIO_TIMEOUT = 2400.0
VIDEO_TIMEOUT = 3600.0


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
    "anthropic": "claude-opus-5",
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

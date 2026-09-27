"""Constants shared across the pipeline."""

import re

# Every chapter gets these items; "audio" and "video" only for chapters selected with --media.
TASKS = ("study", "graph", "quiz", "cards", "mindmap", "audio", "video")
MEDIA_TASKS = frozenset({"audio", "video"})

AUDIO_FORMATS = {"deep-dive": "DEEP_DIVE", "brief": "BRIEF", "critique": "CRITIQUE", "debate": "DEBATE"}
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

QUOTA_MESSAGE = "NotebookLM's limit was reached. Run the same command again later."
DEFAULT_INSTRUCTIONS = (
    "A friendly deep-dive for software engineers: section by section, "
    "concrete analogies and real engineering examples."
)

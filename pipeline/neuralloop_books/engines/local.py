"""The local engine: any text model writes each item; a speech engine voices podcasts and explainers."""

import asyncio
import json
import os
import re
import shutil
from pathlib import Path

from pypdf import PdfReader

from .. import audio, context, convert, prompts
from ..config import CONTEXT_CHARS
from ..notebook import UnusableAnswer
from ..state import BookState

LANGUAGES = {
    "en": "English",
    "hi": "Hindi",
    "es": "Spanish",
    "fr": "French",
    "de": "German",
    "ja": "Japanese",
}
_VOCALISATION = re.compile(r"\s*<(laugh|chuckle|sigh)>\s*")
# Descriptions from the prompts' JSON shapes; small models sometimes copy them instead of writing content.
_PLACEHOLDER = re.compile(
    r"\b(max \d+ words|\d+-\d+ (spoken )?words|kebab-case-id|layer id|concept ids?"
    r"|main branch|what they say)\b|^\.\.\.$",
    re.IGNORECASE,
)
# JSON structure inside a string value: a curly quote ended the string early and the rest leaked in.
_LEAKED_STRUCTURE = re.compile(r'[”"]\s*[}\]]|[}\]]\s*,\s*[{\["“]|["”]\s*,\s*["“]')
LINE_PAUSE = 0.35
LOCAL_SERVER_CHARS = 12_000  # ~3k tokens of chapter, leaving room for the prompt and the answer
# Fewer than this many items means the model skimped: ask again, saying so. (Prompts ask for more.)
MINIMUMS = {
    "study": ("recall prompts", lambda r: len(r["recall"]), 1),
    "graph": ("concepts", lambda r: len(r["concepts"]), 4),
    "quiz": ("questions", len, 2),
    "cards": ("cards", len, 3),
    "mindmap": ("branches", lambda r: len(r.get("children", [])), 2),
    "audio": ("lines", lambda r: len(r["lines"]), 4),
    "video": ("slides", lambda r: len(r["slides"]), 3),
}


class LocalEngine:
    def __init__(
        self,
        model,
        speech,
        out_dir: Path,
        *,
        budget: int,
        audio: str,
        video: str,
        language: str,
        instructions: str,
        task_models: dict | None = None,
        before_start=None,
    ):
        self.before_start = before_start  # e.g. start Ollama; awaited in prepare(), inside the run's loop
        self.model, self.speech, self.out_dir, self.budget = model, speech, out_dir, budget
        self.audio_format, self.video_format, self.instructions = audio, video, instructions
        self.system = prompts.SYSTEM.format(language=LANGUAGES.get(language, language))
        self.name = model.name
        self.task_models = task_models or {}  # a different model for some items, e.g. {"quiz": claude}
        self._sources: dict[int, str] = {}
        self._mind_maps: dict[int, dict] = {}
        self._source_locks: dict[int, asyncio.Lock] = {}
        self._speaking = asyncio.Lock()  # speech models are big: one clip at a time

    @classmethod
    def from_options(
        cls, opts, model, speech, task_models: dict | None = None, before_start=None
    ) -> "LocalEngine":
        budget = opts.context or CONTEXT_CHARS.get(getattr(model, "provider", ""), 400_000)
        if getattr(model, "local", False):
            budget = min(
                budget, LOCAL_SERVER_CHARS
            )  # LM Studio and friends often run with a ~4k-token context
        return cls(
            model,
            speech,
            opts.out,
            budget=budget,
            audio=opts.audio,
            video=opts.video,
            language=opts.language,
            instructions=opts.instructions,
            task_models=task_models,
            before_start=before_start,
        )

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def prepare(self, state: BookState) -> None:
        if self.before_start:
            await self.before_start()
        for model in {id(m): m for m in (self.model, *self.task_models.values())}.values():
            await model.check()
        voiced = ("audio", "video")
        if any(
            c["tasks"][t]["status"] == "todo"
            for c in state.chapters
            for t in voiced
            if t in c.get("tasks", {})
        ):
            self.speech.check()
        state.data.update(
            engine="local", provider=getattr(self.model, "provider", ""), model=self.model.model or ""
        )
        state.save()

    async def make(self, task: str, chapter: dict) -> dict:
        return await getattr(self, f"_{task}")(chapter)

    # ---- the chapter text, condensed when it doesn't fit ----

    async def _source(self, chapter: dict) -> str:
        n = chapter["n"]
        async with self._source_locks.setdefault(n, asyncio.Lock()):
            if n not in self._sources:
                text = await asyncio.to_thread(_chapter_text, self.out_dir / "chapters" / chapter["file"])
                cache = self.out_dir / "raw" / f"{n:02d}-notes.json"
                self._sources[n] = await context.source_for(self.model, text, self.budget, cache, self.system)
        return self._sources[n]

    async def _ask(self, kind: str, chapter: dict, prompt: str, check, label: str):
        """Ask for one JSON item; if it's unusable or skimpy, ask once more saying exactly what was wrong."""
        source = await self._source(chapter)
        model = self.task_models.get(kind, self.model)
        answer = await model.complete(kind, self.system, source, prompt)
        result, problem = self._judge(kind, answer, check)
        if problem:
            self._keep_rejected(chapter, kind, answer)
            retry = prompt + prompts.RETRY.format(problem=problem)
            second = await model.complete(kind, self.system, source, retry)
            again, second_problem = self._judge(kind, second, check)
            if second_problem:
                self._keep_rejected(chapter, kind, second)
            # A short but valid answer beats nothing; keep whichever of the two has more.
            result = max((r for r in (result, again) if r), key=lambda r: MINIMUMS[kind][1](r), default=None)
        if not result:
            raise UnusableAnswer(f"{model.name}'s {label} wasn't usable, even on a second try")
        raw = self.out_dir / "raw" / f"{chapter['n']:02d}-{kind}.json"
        raw.parent.mkdir(parents=True, exist_ok=True)
        raw.write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
        return result

    @staticmethod
    def _judge(kind: str, answer: str, check):
        """(result or None, problem or "")."""
        result = check(convert.loose_json(answer))
        if not result:
            return None, "it wasn't valid JSON in the shape asked for"
        if any(_LEAKED_STRUCTURE.search(text) for text in _strings(result)):
            return (
                None,
                'some strings contain JSON punctuation; use straight double quotes (") only, never “ or ”',
            )
        if any(_PLACEHOLDER.search(text) for text in _strings(result)):
            return None, "it copied the example text from the shape instead of writing about the chapter"
        noun, count, minimum = MINIMUMS[kind]
        if count(result) < minimum:
            return result, f"it had only {count(result)} {noun}; follow the rules above for how many"
        return result, ""

    def _keep_rejected(self, chapter: dict, kind: str, answer: str) -> None:
        path = self.out_dir / "raw" / f"{chapter['n']:02d}-{kind}-rejected.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as file:
            file.write(answer + "\n\n-----\n\n")

    def _fill(self, template: str, chapter: dict, **extra) -> str:
        return template.format(title=chapter["title"], instructions=self.instructions, **extra)

    # ---- the items ----

    async def _study(self, chapter):
        return await self._ask(
            "study", chapter, self._fill(prompts.LOCAL_STUDY, chapter), convert.study, "study guide"
        )

    async def _graph(self, chapter):
        try:
            graph = await self._ask(
                "graph",
                chapter,
                self._fill(prompts.LOCAL_GRAPH, chapter),
                convert.concept_graph,
                "concept graph",
            )
        except UnusableAnswer:
            # The map must always be there: grow it from the chapter's mind map instead.
            graph = convert.graph_from_mind_map((await self._mindmap(chapter))["mindmap"])
            if not graph:
                raise
        return {"graph": graph}

    async def _quiz(self, chapter):
        return {
            "quiz": await self._ask("quiz", chapter, self._fill(prompts.QUIZ, chapter), convert.quiz, "quiz")
        }

    async def _cards(self, chapter):
        return {
            "cards": await self._ask(
                "cards", chapter, self._fill(prompts.CARDS, chapter), convert.flashcards, "flashcards"
            )
        }

    async def _mindmap(self, chapter):
        n = chapter["n"]
        if n not in self._mind_maps:  # the graph fallback may already have made it
            self._mind_maps[n] = await self._ask(
                "mindmap", chapter, self._fill(prompts.MINDMAP, chapter), convert.mind_map, "mind map"
            )
        return {"mindmap": self._mind_maps[n]}

    async def _audio(self, chapter):
        style = prompts.PODCAST_FORMATS.get(self.audio_format, prompts.PODCAST_FORMATS["deep-dive"])
        script = await self._ask(
            "audio",
            chapter,
            self._fill(
                prompts.PODCAST,
                chapter,
                format=style,
                host_a=self.speech.voices[0],
                host_b=self.speech.voices[1],
            ),
            convert.podcast_script,
            "podcast script",
        )
        n = chapter["n"]
        transcript_file = self._media(f"{n:02d}-podcast.json")
        transcript = {"title": script["title"], "complete": False, "lines": []}
        line_wavs: list[Path] = []
        position = 0.0
        for i, line in enumerate(script["lines"]):
            voice = self.speech.voices[0 if line["speaker"] == "A" else 1]
            pieces = []
            for j, piece in enumerate(audio.split_for_speech(line["text"])):
                clip = self._clip_path(f"{n:02d}-podcast-{i:03d}-{j}")
                await self._say(piece, voice, line["delivery"], clip)
                pieces.append(clip)
            line_wav = self._clip_path(f"{n:02d}-podcast-line-{i:03d}")
            lengths = await asyncio.to_thread(audio.join_wavs, pieces, line_wav, 0.2)
            seconds = sum(lengths) + 0.2 * (len(pieces) - 1)
            _remove(pieces)
            # Each line is published once it's voiced, so the app can start playing while the rest is made.
            published = _copy(line_wav, self._media(f"{n:02d}-podcast-lines/{i:03d}.wav"))
            clip = await asyncio.to_thread(audio.to_m4a, published)
            transcript["lines"].append(
                {
                    "speaker": line["speaker"],
                    "voice": voice,
                    "text": _VOCALISATION.sub(" ", line["text"]).strip(),
                    "start": round(position, 3),
                    "clip": clip.relative_to(self.out_dir).as_posix(),
                }
            )
            _write_json(transcript_file, transcript)
            line_wavs.append(line_wav)
            position += seconds + LINE_PAUSE
        wav = self._media(f"{n:02d}-podcast.wav")
        await asyncio.to_thread(audio.join_wavs, line_wavs, wav, LINE_PAUSE)
        final = await asyncio.to_thread(audio.to_m4a, wav)
        transcript["complete"] = True
        _write_json(transcript_file, transcript)
        _remove(line_wavs)
        return {"audio": f"media/{final.name}", "transcript": f"media/{transcript_file.name}"}

    async def _video(self, chapter):
        style = prompts.EXPLAINER_FORMATS.get(self.video_format, prompts.EXPLAINER_FORMATS["explainer"])
        explainer = await self._ask(
            "video",
            chapter,
            self._fill(prompts.EXPLAINER, chapter, format=style),
            convert.explainer,
            "explainer",
        )
        n = chapter["n"]
        narration: list[Path] = []
        for k, slide in enumerate(explainer["slides"], 1):
            clips = []
            for j, piece in enumerate(audio.split_for_speech(slide["narration"])):
                clip = self._clip_path(f"{n:02d}-explainer-{k:02d}-{j}")
                await self._say(piece, self.speech.voices[0], "warm, playful, steady pace", clip)
                clips.append(clip)
            wav = self._media(f"{n:02d}-explainer-{k:02d}.wav")
            durations = await asyncio.to_thread(audio.join_wavs, clips, wav, 0.2)
            narration.append(_copy(wav, self._clip_path(f"{n:02d}-explainer-slide-{k:02d}")))
            final = await asyncio.to_thread(audio.to_m4a, wav)
            slide.update(
                audio=f"media/{final.name}", duration=round(sum(durations) + 0.2 * (len(durations) - 1), 3)
            )
            _remove(clips)
        result = {"explainer": explainer}
        film = await self._film(chapter, explainer["slides"], narration)
        if film:
            result["video"] = film
        _remove(narration)
        return result

    async def _film(self, chapter: dict, slides: list[dict], narration: list[Path]) -> str | None:
        """The explainer as a real MP4 (animated scene + narration); None when rendering isn't available."""
        if os.environ.get("NEURALLOOP_VIDEO") == "0":
            return None
        from .. import video

        out = self._media(f"{chapter['n']:02d}-explainer.mp4")
        try:
            await asyncio.to_thread(
                video.render, out, chapter["title"], slides, narration, video.FPS, video.SIZE
            )
        except Exception:  # no browser or encoder here: the narrated slideshow still plays in the app
            out.unlink(missing_ok=True)
            return None
        return f"media/{out.name}"

    # ---- speech ----

    def _media(self, name: str) -> Path:
        folder = self.out_dir / "media"
        folder.mkdir(parents=True, exist_ok=True)
        return folder / name

    def _clip_path(self, stem: str) -> Path:
        folder = self.out_dir / "raw" / "speech"
        folder.mkdir(parents=True, exist_ok=True)
        return folder / f"{stem}.wav"

    async def _say(self, text: str, voice: str, delivery: str, path: Path) -> None:
        async with self._speaking:
            await asyncio.to_thread(self.speech.synth, text, voice, delivery, path)


def _strings(value) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [s for v in value.values() for s in _strings(v)]
    if isinstance(value, list):
        return [s for v in value for s in _strings(v)]
    return []


_FIGURE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")


def _chapter_text(file: Path) -> str:
    if file.suffix == ".pdf":
        return "\n\n".join((page.extract_text() or "").strip() for page in PdfReader(str(file)).pages)
    # Models read the figure's description, not its file path.
    return _FIGURE.sub(
        lambda m: f"[Figure: {m.group(1)}]" if m.group(1) else "", file.read_text(encoding="utf-8")
    )


def _copy(source: Path, target: Path) -> Path:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return target


def _write_json(path: Path, data: dict) -> None:
    """Atomic, so the app never reads half a transcript."""
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)


def _remove(paths: list[Path]) -> None:
    for path in paths:
        path.unlink(missing_ok=True)

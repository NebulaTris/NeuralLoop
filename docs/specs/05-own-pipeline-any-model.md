# Spec 05 — Our own pipeline, with any model you plug in

Status: next (before 04's app screens; the app only needs the book folder contract) · Read first: `CLAUDE.md` ·
Touches: `pipeline/`

## Why

Every study item today comes from Google NotebookLM through the unofficial `notebooklm-py` library. If it stops working, or
the person has no Google account, or hits a daily limit, nothing gets made. We want a complete pipeline of our own that makes
everything (study guide, recall prompts, concept graph, quiz, flashcards, mind map, a two-host podcast, and an explainer) with
whichever model the person brings:

| Provider | How it's reached | Key |
|---|---|---|
| `anthropic` | Anthropic Messages API (`anthropic` SDK) | `ANTHROPIC_API_KEY` |
| `openai` | OpenAI Chat Completions (`openai` SDK) | `OPENAI_API_KEY` |
| `openrouter` | OpenAI-compatible API at `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` |
| `ollama` | OpenAI-compatible API at `http://localhost:11434/v1` (local, free) | none |
| `opencode` | `opencode run -m <provider/model> "<prompt>"` subprocess (for example `deepseek/deepseek-v4-flash`) | opencode's own config |
| `fake` | Deterministic canned answers (dry runs and tests) | none |

NotebookLM stays as an optional engine for people who like its voices and videos. It is no longer required.

## Engines

A run uses one **engine**:

- `local` (new default): chapter text goes to a text model; speech comes from a speech engine.
- `notebooklm`: today's behaviour, unchanged (`ChapterMaker`, sources, quota handling).

Both engines implement the same small interface, so `pipeline.run` no longer knows about notebooks:

```python
class Engine(Protocol):
    name: str                                    # shown in messages: "Claude", "Ollama", "NotebookLM"
    async def __aenter__(self) / __aexit__(...)
    async def prepare(self, state, out_dir) -> None   # notebooklm: add sources · local: extract chapter text
    async def make(self, task: str, chapter: dict) -> dict   # fields to store on the chapter
```

## What the local engine makes

Every JSON answer is parsed with `convert.loose_json` and checked by the **existing converters**, so a book made locally looks
exactly like one made with NotebookLM:

| Task | Prompt asks for | Checked by | Stored as |
|---|---|---|---|
| `study` | `{guide, recall}` (existing `STUDY` prompt, reworded for any model) | `convert.study` | `guide`, `recall` |
| `graph` | `{concepts, layers, edges, tour}` (existing `GRAPH` prompt) | `convert.concept_graph` | `graph` |
| `quiz` | `{questions:[{question, hint, answerOptions:[{text, isCorrect, rationale}]}]}`, 8–10 questions | `convert.quiz` | `quiz` |
| `cards` | `{cards:[{front, back}]}`, 12–20 cards | `convert.flashcards` | `cards` |
| `mindmap` | `{name, children:[{name, children}]}`, 3 levels deep | new `convert.mind_map` | `mindmap` |
| `audio` | a podcast script `{title, lines:[{speaker:"A"\|"B", text, delivery}]}` in the chosen format (deep-dive, brief, critique, debate) → speech → one `.m4a` | new `convert.podcast_script` | `audio: "media/NN-podcast.m4a"`, `transcript: "media/NN-podcast.json"` |
| `video` | an explainer `{slides:[{title, points, narration, pose}]}` (5–8 slides) → narration per slide | new `convert.explainer` | `explainer: {slides:[{title, points, narration, pose, audio}]}` |

The explainer is a new field. The desktop app plays it natively as an animated slideshow with Pip (spec 04), so no video file
or ffmpeg is needed. The task keeps the name `video` so existing `state.json` files stay valid. `chapter.video` (an `.mp4`)
is still filled by the NotebookLM engine.

If an answer isn't usable, the engine asks once more, adding the parse error to the prompt. If the second answer is also
unusable, the item fails with a clear note.

### Long chapters

Each provider has a context budget (characters, configurable with `--context`). Defaults: 400,000 for `anthropic`,
`openai`, and `openrouter`; 24,000 for `ollama` and `opencode`. A chapter that fits is sent as is. A longer chapter is
split on paragraph boundaries into chunks that fit. Each chunk is condensed into dense notes (one call per chunk, cached in
`raw/NN-notes.json`), and the notes stand in for the text. PDF chapters are turned into text with `pypdf`.

### Speech

| Engine | What | Needs |
|---|---|---|
| `rumik` (default when installed) | [Rumik OSS-1](https://huggingface.co/rumik-ai/rumik-oss-1-mlx-8bit) through `mlx-audio` on Apple silicon; voices Ira, Aisha, Siya, Zoya; `delivery` goes to `instruct`; `<laugh>`, `<chuckle>`, `<sigh>` pass through | `pip install mlx-audio`, about 3.8 GB of memory, a one-time model download |
| `say` (fallback, always there on macOS) | macOS `say` with two different system voices | nothing |
| `fake` | a short tone per line (tests, dry runs) | nothing |

Rumik is trained on 30-second utterances, so lines are split at sentence ends to stay under about 30 seconds (about 400
characters). Segments are joined with a short pause, written as WAV, and converted to AAC `.m4a` with the built-in
`afconvert`. Only one speech job runs at a time (a lock), because the model is big.

**License note, shown in the app next to the choice:** Rumik OSS-1 is CC-BY-NC 4.0 (non-commercial use). The `say` voices
have no such limit.

## Limits and errors

- Rate limits and quota errors (HTTP 429, "rate limit", "quota", "insufficient credits") use today's `waiting_quota` flow:
  the item waits, and the next run or `--retry` continues it.
- A missing key, a wrong model name, Ollama not running, or opencode not installed stops the run before any work, with exit
  code 3 and a plain message: "Ollama isn't running. Open the Ollama app, or run: ollama serve".
- Keys are only read from environment variables. They never go into argv, `state.json`, `meta.json`, or logs. The desktop
  app keeps them in the macOS Keychain and passes them to the pipeline process as environment variables.

## CLI and contracts (additions; everything else unchanged)

```
nl_book.py BOOK --out DIR [--engine local|notebooklm] [--provider anthropic|openai|openrouter|ollama|opencode|fake]
           [--model NAME] [--context CHARS] [--speech rumik|say|fake] [--voices A,B] …existing flags…
```

- `--dry-run` = `--engine local --provider fake --speech fake` (today's `FakeClient` still backs the NotebookLM engine tests).
- Default model per provider lives in `config.py` (`DEFAULT_MODELS`); `--model` overrides it.
- `parallel` defaults to 1 for `ollama`, `opencode`, and `rumik`, and to 2 otherwise.
- Progress line for limits becomes `  … chapter N task: {Engine name} limit reached; will continue next run` (the app matches
  `limit reached`).
- `state.json` gains `engine`, `provider`, and `model` at the top level (for display). The book-data payload gains
  `explainer` and `transcript` on chapters.
- Dependencies: the core needs only `pypdf`. Extras: `[anthropic]`, `[openai]` (also covers OpenRouter and Ollama),
  `[notebooklm]`, `[rumik]` (`mlx-audio`), and `[all]`.

## Files

```
pipeline/neuralloop_books/
  engines/__init__.py      make_engine(opts) → Engine; Engine protocol
  engines/notebooklm.py    today's ChapterMaker + source adding, moved from notebook.py/pipeline.py
  engines/local.py         LocalEngine: prompts → model → converters; podcast and explainer through speech
  models/__init__.py       TextModel protocol: async complete(system, prompt) -> str; make_model(provider, model, …)
  models/anthropic.py      Messages API
  models/openai_compat.py  openai / openrouter / ollama (base URL + key per provider)
  models/opencode.py       subprocess runner
  models/fake.py           canned JSON per prompt kind (reuses the fake NotebookLM content)
  speech/__init__.py       SpeechEngine protocol: synth(text, voice, delivery, path); make_speech(name)
  speech/rumik.py · speech/say.py · speech/fake.py
  audio.py                 split for TTS, join WAVs with pauses, afconvert to m4a
  context.py               fit(text, budget) → chunks; condense through the model
  prompts.py               + QUIZ, CARDS, MINDMAP, PODCAST, EXPLAINER, CONDENSE, SYSTEM
  convert.py               + mind_map, podcast_script, explainer
```

## Tests (write first)

- `test_convert.py`: `mind_map` drops empty names and caps depth; `podcast_script` needs both speakers and non-empty lines;
  `explainer` caps slides and falls back to pose `read` for unknown poses.
- `test_context.py`: short text is one chunk; long text splits on paragraphs within budget; no text is lost.
- `test_audio.py`: long lines split at sentence ends under the limit; WAVs join with pauses to the right length;
  `to_m4a` calls `afconvert` with the right arguments (subprocess stubbed).
- `test_models.py`: provider → base URL and key variable; a missing key raises the setup error; `opencode` builds the right
  argv; 429-style errors count as quota errors. No network: SDK clients and subprocess are stubbed.
- `test_local_engine.py`: with `FakeModel` + `FakeSpeech`, every task produces converter-valid output; one bad answer →
  one retry that succeeds; two bad answers → a clear failure; long chapters go through condensing.
- `test_pipeline.py`: the existing suite runs unchanged on the NotebookLM engine (`FakeClient`), plus a full local dry run
  that makes every item, including `explainer` and `transcript`, and the quota flow with a model that raises 429.
- `test_cli.py`: new flags parse; `--dry-run` picks the fake local engine; a missing key exits 3 with the friendly message.

## Definition of done

- `python pipeline/nl_book.py --dry-run --out /tmp/demo` runs fully offline on the local engine.
- With a real key (or Ollama running), the sample book produces every item. With `--speech rumik`, the podcast plays
  with two different Rumik voices.
- `make check` passes; the old NotebookLM path still passes its tests.

#!/usr/bin/env python3
"""NeuralLoop x NotebookLM: a one-chapter proof of concept.

What it does (about 3-5 minutes without audio, 10-20 minutes with it):
  1. Creates a temporary NotebookLM notebook in YOUR Google account
  2. Adds one chapter (the NeuralLoop sample chapter, or --file yours.md)
  3. Generates flashcards and a quiz (+ an Audio Overview with --audio, + a mind map with --mindmap)
  4. Downloads them and converts them into NeuralLoop's formats
  5. Writes everything to ./poc_out/ and prints a summary with timings
  6. Deletes the temporary notebook (unless --keep)

Setup once:
  uv tool install "notebooklm-py[browser]"      (or: pip install "notebooklm-py[browser]")
  notebooklm login                               (opens a browser to sign in to Google)
Run:
  python poc_notebooklm.py --check               (is my sign-in working?)
  python poc_notebooklm.py                       (cards + quiz on the sample chapter)
  python poc_notebooklm.py --audio --mindmap     (the full thing)

Note: notebooklm-py uses unofficial Google APIs that can change without notice,
and the chapter text is sent to Google.
"""
import argparse, asyncio, json, sys, time
from pathlib import Path
if sys.version_info < (3, 10):
    sys.exit("NeuralLoop's NotebookLM tools need Python 3.10 or newer (you have %d.%d).\n"
             "Easiest fix: install uv (https://docs.astral.sh/uv/) and run:\n"
             "  uv run --python 3.12 --with \"notebooklm-py[browser]\" %s ..." % (sys.version_info[0], sys.version_info[1], sys.argv[0]))
sys.path.insert(0, str(Path(__file__).parent))
from notebooklm_bridge import convert_cards, convert_quiz, convert_mindmap

SAMPLE_TITLE = "When the world moves: distribution shifts"
SAMPLE_TEXT = """## Why models get worse after launch
A model is trained on a snapshot of the world, but the world keeps moving after you ship. Users change habits, new products launch, and upstream teams change how fields are logged. The weights stay frozen while the data drifts away from what the model learned from. Not every drop in accuracy is a shift: rule out engineering bugs such as broken joins or zero-filled features first.

## Covariate shift
The distribution of inputs P(X) changes while the relationship P(Y|X) stays the same, for example a loan model that suddenly sees many younger applicants. A common response is importance weighting during retraining.

## Label shift
The output distribution P(Y) changes while P(X|Y) stays the same, for example an outbreak raising the base rate of positive cases.

## Concept drift
The relationship P(Y|X) itself changes, so the same input deserves a different answer, for example fraudsters adapting to your defenses. It is often seasonal.

## Detecting shifts
Ground truth often arrives late, so teams monitor input and prediction distributions against a reference window using summary statistics and two-sample tests such as Kolmogorov-Smirnov. With large data almost every difference is significant, so pair tests with a threshold for shifts that matter. Short windows detect quickly but raise false alarms.

## Responding to shifts
Retrain on a schedule or when monitoring detects a meaningful shift, choose what data to retrain on, and compare the new model against the current one on recent data before switching traffic.
"""

async def _open_client(cls):
    """Works with notebooklm-py 0.8+ (async context manager) and older builds (awaitable)."""
    cm = cls.from_storage()
    return cm if hasattr(cm, "__aenter__") else await cm

def log(msg, t0=None):
    extra = f"  ({time.monotonic() - t0:.0f}s)" if t0 else ""
    print(f"  {msg}{extra}", flush=True)

async def check():
    from notebooklm import NotebookLMClient
    async with await _open_client(NotebookLMClient) as client:
        nbs = await client.notebooks.list()
        print(f"Signed in. Your account has {len(nbs)} notebooks.")

async def run(a):
    from notebooklm import NotebookLMClient, MindMapKind
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    title, text = (Path(a.file).stem, Path(a.file).read_text(encoding="utf-8")) if a.file else (SAMPLE_TITLE, SAMPLE_TEXT)
    result = {"title": title, "cards": [], "quiz": [], "mindmap": None, "audio": None, "timings": {}, "errors": []}
    start = time.monotonic()
    async with await _open_client(NotebookLMClient) as client:
        t = time.monotonic(); nb = await client.notebooks.create(f"NeuralLoop POC: {title}"[:90]); log(f"notebook created {nb.id}", t)
        try:
            t = time.monotonic(); src = await client.sources.add_text(nb.id, title[:90], text, wait=True, wait_timeout=300.0)
            sid = [src.id]; result["timings"]["source"] = round(time.monotonic() - t); log("chapter added and processed", t)
            async def step(name, coro):
                t = time.monotonic()
                try: await coro; result["timings"][name] = round(time.monotonic() - t); log(f"{name} done", t)
                except Exception as ex: result["errors"].append(f"{name}: {type(ex).__name__}: {ex}"[:300]); log(f"{name} FAILED: {ex}")
            async def cards():
                st = await client.artifacts.generate_flashcards(nb.id, source_ids=sid)
                await client.artifacts.wait_for_completion(nb.id, st.task_id, timeout=600.0)
                p = out / "flashcards.json"; await client.artifacts.download_flashcards(nb.id, str(p), st.task_id, output_format="json")
                result["cards"] = convert_cards(json.loads(p.read_text()))
            async def quiz():
                st = await client.artifacts.generate_quiz(nb.id, source_ids=sid)
                await client.artifacts.wait_for_completion(nb.id, st.task_id, timeout=600.0)
                p = out / "quiz.json"; await client.artifacts.download_quiz(nb.id, str(p), st.task_id, output_format="json")
                result["quiz"] = convert_quiz(json.loads(p.read_text()))
            async def mindmap():
                mm = await client.mind_maps.generate(nb.id, source_ids=sid, kind=MindMapKind.NOTE_BACKED)
                p = out / "mindmap.json"; await client.artifacts.download_mind_map(nb.id, str(p), mm.id)
                result["mindmap"] = convert_mindmap(json.loads(p.read_text()))
            async def audio():
                st = await client.artifacts.generate_audio(nb.id, source_ids=sid, language=a.language,
                        instructions="A friendly deep-dive for software engineers, section by section, with analogies.")
                await client.artifacts.wait_for_completion(nb.id, st.task_id, timeout=1800.0)
                p = out / "audio-overview.m4a"; await client.artifacts.download_audio(nb.id, str(p), st.task_id)
                result["audio"] = str(p)
            await step("flashcards", cards()); await step("quiz", quiz())
            if a.mindmap: await step("mind map", mindmap())
            if a.audio: await step("audio overview", audio())
        finally:
            if not a.keep:
                try: await client.notebooks.delete(nb.id); log("temporary notebook deleted")
                except Exception as ex: log(f"could not delete notebook {nb.id}: {ex}")
    result["timings"]["total"] = round(time.monotonic() - start)
    (out / "neuralloop.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"\nDone in {result['timings']['total']}s: {len(result['cards'])} cards, {len(result['quiz'])} quiz questions"
          f"{', mind map with ' + str(len(result['mindmap']['nodes'])) + ' nodes' if result['mindmap'] else ''}"
          f"{', audio at ' + result['audio'] if result['audio'] else ''}.")
    for c in result["cards"][:3]: print(f"  card: {c['front']}  ->  {c['back']}")
    for q in result["quiz"][:2]: print(f"  quiz: {q['q']}  (answer: {q['options'][q['a']]})")
    if result["errors"]: print("Problems:", *result["errors"], sep="\n  ")
    print(f"Everything saved in {out.resolve()}")
    return 0 if (result["cards"] or result["quiz"]) else 1

def main():
    ap = argparse.ArgumentParser(description="NeuralLoop x NotebookLM proof of concept")
    ap.add_argument("--check", action="store_true", help="only check that sign-in works")
    ap.add_argument("--file", help="a Markdown/text chapter instead of the sample")
    ap.add_argument("--audio", action="store_true", help="also make an Audio Overview (slow)")
    ap.add_argument("--mindmap", action="store_true", help="also make a mind map")
    ap.add_argument("--language", default="en"); ap.add_argument("--out", default="poc_out"); ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    try:
        import notebooklm  # noqa: F401
    except ImportError:
        print('notebooklm-py is not installed. Run: uv tool install "notebooklm-py[browser]"  (or pip install "notebooklm-py[browser]")'); return 2
    try:
        if a.check: asyncio.run(check()); return 0
        return asyncio.run(run(a))
    except Exception as ex:
        name = type(ex).__name__
        hint = "Run: notebooklm login" if "Auth" in name or "login" in str(ex).lower() or "storage" in str(ex).lower() else "Check your internet connection, then try again."
        print(f"Couldn't talk to NotebookLM ({name}: {str(ex)[:200]}). {hint}"); return 3

if __name__ == "__main__":
    sys.exit(main())

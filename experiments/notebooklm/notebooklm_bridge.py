#!/usr/bin/env python3
"""NeuralLoop <-> Google NotebookLM bridge (optional).

Drives the community notebooklm-py library (unofficial Google APIs; may break
without notice) with the user's own Google account, then converts NotebookLM's
outputs into NeuralLoop's formats. Prints one JSON object to stdout:

  {"ok": bool, "notebookId": str|None, "audio": path|None,
   "cards": [{"front","back"}], "quiz": [{"q","options","a","explain"}],
   "mindmap": {"nodes": [...], "edges": [...]} | None, "errors": [str]}

Every step is independent: if one fails, the others still return.
Verified against notebooklm-py 0.8.3 method signatures and export formats
(quiz: questions[].answerOptions[].isCorrect; flashcards: cards[].front/back).
"""
import argparse, asyncio, json, subprocess, sys
from pathlib import Path
if sys.version_info < (3, 10):
    sys.exit("NeuralLoop's NotebookLM tools need Python 3.10 or newer (you have %d.%d).\n"
             "Easiest fix: install uv (https://docs.astral.sh/uv/) and run:\n"
             "  uv run --python 3.12 --with \"notebooklm-py[browser]\" %s ..." % (sys.version_info[0], sys.version_info[1], sys.argv[0]))

async def _open_client(cls):
    """Works with notebooklm-py 0.8+ (async context manager) and older builds (awaitable)."""
    cm = cls.from_storage()
    return cm if hasattr(cm, "__aenter__") else await cm

def run_cli(*args, timeout=900):
    p = subprocess.run(["notebooklm", *args], capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(f"notebooklm {' '.join(args[:2])}: {(p.stderr or p.stdout).strip()[:300]}")
    return p.stdout

# ---------- tolerant converters (NotebookLM export shapes vary by version) ----------
def _first(d, *keys):
    for k in keys:
        if isinstance(d, dict) and d.get(k) not in (None, ""):
            return d[k]
    return None

def _items(data, *keys):
    if isinstance(data, list): return data
    if isinstance(data, dict):
        for k in keys:
            if isinstance(data.get(k), list): return data[k]
    return []

def convert_cards(data):
    out = []
    for c in _items(data, "flashcards", "cards", "items"):
        front = _first(c, "front", "question", "term", "prompt")
        back = _first(c, "back", "answer", "definition", "explanation")
        if front and back: out.append({"front": str(front).strip(), "back": str(back).strip()})
    return out

def convert_quiz(data):
    out = []
    for q in _items(data, "questions", "quiz", "items"):
        text = _first(q, "question", "q", "prompt")
        opts = _first(q, "answerOptions", "options", "choices", "answers") or []
        opts = [(_first(o, "text", "option", "answer") if isinstance(o, dict) else o) for o in opts]
        opts = [str(o) for o in opts if o]
        ans = _first(q, "correct_index", "answer_index", "correctIndex")
        if ans is None:
            correct = _first(q, "correct_answer", "answer", "correct")
            if isinstance(correct, int): ans = correct
            elif correct is not None and str(correct) in opts: ans = opts.index(str(correct))
            else:
                flagged = [i for i, o in enumerate(_first(q, "answerOptions", "options", "choices", "answers") or []) if isinstance(o, dict) and (o.get("isCorrect") or o.get("correct") or o.get("is_correct"))]
                ans = flagged[0] if flagged else None
        if text and len(opts) >= 2 and isinstance(ans, int) and 0 <= ans < len(opts):
            out.append({"q": str(text), "options": opts[:6], "a": ans, "explain": str(_first(q, "explanation", "rationale", "hint") or "")})
    return out

def convert_mindmap(data):
    nodes, edges = [], []
    def walk(n, parent=None, depth=0):
        if not isinstance(n, dict) or depth > 6: return
        name = _first(n, "name", "title", "text", "label")
        if not name: return
        nid = f"nlm-{len(nodes)}"
        nodes.append({"id": nid, "name": str(name)[:60], "type": "topic" if depth < 2 else "concept", "summary": str(_first(n, "summary", "description") or name)})
        if parent: edges.append({"source": nid, "target": parent, "type": "categorized_under"})
        for ch in _items(n, "children", "nodes", "subtopics"):
            walk(ch, nid, depth + 1)
    roots = data if isinstance(data, list) else [data.get("root", data)] if isinstance(data, dict) else []
    for r in roots: walk(r)
    return {"nodes": nodes, "edges": edges} if nodes else None

# ---------- pipeline ----------
async def main_async(a):
    from notebooklm import NotebookLMClient, MindMapKind
    out = {"ok": False, "notebookId": None, "audio": None, "cards": [], "quiz": [], "mindmap": None, "errors": []}
    outdir = Path(a.out); outdir.mkdir(parents=True, exist_ok=True)
    async with await _open_client(NotebookLMClient) as client:
        nb = await client.notebooks.create(f"NeuralLoop: {a.title}"[:90])
        out["notebookId"] = nb.id
        text = Path(a.text_file).read_text(encoding="utf-8")
        src = await client.sources.add_text(nb.id, a.title[:90], text, wait=True, wait_timeout=300.0)
        sid = [src.id] if getattr(src, "id", None) else None
        async def step(name, fn):
            try: await fn()
            except Exception as ex: out["errors"].append(f"{name}: {type(ex).__name__}: {ex}"[:300])
        async def audio():
            st = await client.artifacts.generate_audio(nb.id, source_ids=sid, language=a.language, instructions=a.instructions)
            await client.artifacts.wait_for_completion(nb.id, st.task_id, timeout=1800.0)
            path = outdir / "audio-overview.m4a"
            await client.artifacts.download_audio(nb.id, str(path)); out["audio"] = str(path)
        async def quiz():
            st = await client.artifacts.generate_quiz(nb.id, source_ids=sid)
            await client.artifacts.wait_for_completion(nb.id, st.task_id, timeout=600.0)
            path = outdir / "quiz.json"
            await client.artifacts.download_quiz(nb.id, str(path), st.task_id, output_format="json")
            out["quiz"] = convert_quiz(json.loads(path.read_text()))
        async def cards():
            st = await client.artifacts.generate_flashcards(nb.id, source_ids=sid)
            await client.artifacts.wait_for_completion(nb.id, st.task_id, timeout=600.0)
            path = outdir / "flashcards.json"
            await client.artifacts.download_flashcards(nb.id, str(path), st.task_id, output_format="json")
            out["cards"] = convert_cards(json.loads(path.read_text()))
        async def mindmap():
            mm = await client.mind_maps.generate(nb.id, source_ids=sid, kind=MindMapKind.NOTE_BACKED, language=a.language)
            path = outdir / "mindmap.json"
            await client.artifacts.download_mind_map(nb.id, str(path), mm.id)
            out["mindmap"] = convert_mindmap(json.loads(path.read_text()))
        if not a.no_audio: await step("audio", audio)
        await step("quiz", quiz); await step("flashcards", cards); await step("mind map", mindmap)
    out["ok"] = bool(out["audio"] or out["cards"] or out["quiz"] or out["mindmap"])
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True); ap.add_argument("--text-file", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--instructions", default="A friendly deep-dive for software engineers."); ap.add_argument("--no-audio", action="store_true"); ap.add_argument("--language", default="en")
    ap.add_argument("--selftest", action="store_true", help="test the converters without calling Google")
    a = ap.parse_args()
    if a.selftest:
        print(json.dumps({"cards": convert_cards({"flashcards": [{"question": "Q", "answer": "A"}]}),
                          "quiz": convert_quiz({"questions": [{"question": "Q?", "options": [{"text": "x"}, {"text": "y", "is_correct": True}]}]}),
                          "mindmap": convert_mindmap({"name": "Root", "children": [{"name": "Child"}]})})); return
    try:
        res = asyncio.run(main_async(a))
    except ImportError:
        res = {"ok": False, "errors": ["notebooklm-py is not installed. Run: uv tool install \"notebooklm-py[browser]\""]}
    except Exception as ex:
        res = {"ok": False, "errors": [f"{type(ex).__name__}: {ex}"[:400]]}
    print(json.dumps(res))

if __name__ == "__main__":
    main()

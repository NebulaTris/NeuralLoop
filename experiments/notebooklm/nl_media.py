#!/usr/bin/env python3
"""NeuralLoop media POC: one command, book in -> podcast + video out.

    python nl_media.py mybook.pdf
    python nl_media.py https://example.com/some-article
    python nl_media.py notes.md --video brief --style kawaii --audio debate

It handles everything in one step:
  1. installs notebooklm-py if it's missing (asks first)
  2. signs you in to Google if needed (opens a browser once)
  3. creates a temporary NotebookLM notebook and adds your source
  4. makes an Audio Overview (podcast) and a Video Overview at the same time
  5. downloads both, writes a small player page, and opens it
  6. deletes the temporary notebook (unless --keep)

Uses the community notebooklm-py library (unofficial Google APIs that can change
without notice) with YOUR Google account; the source is sent to Google.
Try the whole flow without Google first:  python nl_media.py --dry-run
"""
import argparse, asyncio, html, importlib, json, math, os, shutil, struct, subprocess, sys, time, wave, webbrowser
from pathlib import Path
if sys.version_info < (3, 10):
    sys.exit("NeuralLoop's NotebookLM tools need Python 3.10 or newer (you have %d.%d).\n"
             "Easiest fix: install uv (https://docs.astral.sh/uv/) and run:\n"
             "  uv run --python 3.12 --with \"notebooklm-py[browser]\" %s ..." % (sys.version_info[0], sys.version_info[1], sys.argv[0]))

PIP_ICON = open(Path(__file__).with_name("pip_icon.svg")).read() if Path(__file__).with_name("pip_icon.svg").exists() else ""
FILE_TYPES = {".pdf", ".md", ".markdown", ".txt", ".docx"}
AUDIO = {"deep-dive": "DEEP_DIVE", "brief": "BRIEF", "critique": "CRITIQUE", "debate": "DEBATE"}
LENGTH = {"short": "SHORT", "default": "DEFAULT", "long": "LONG"}
VIDEO = {"explainer": "EXPLAINER", "brief": "BRIEF", "short": "SHORT", "cinematic": "CINEMATIC"}
STYLE = {"auto": "AUTO_SELECT", "classic": "CLASSIC", "whiteboard": "WHITEBOARD", "kawaii": "KAWAII", "anime": "ANIME",
         "watercolor": "WATERCOLOR", "retro-print": "RETRO_PRINT", "heritage": "HERITAGE", "paper-craft": "PAPER_CRAFT"}
DEFAULT_INSTRUCTIONS = ("A friendly deep-dive for software engineers. Go section by section, use concrete analogies and "
                        "real engineering examples, and end with three things to watch for while reading.")

async def _open_client(cls):
    """Works with notebooklm-py 0.8+ (async context manager) and older builds (awaitable)."""
    cm = cls.from_storage()
    return cm if hasattr(cm, "__aenter__") else await cm

def say(msg): print(msg, flush=True)

# ---------- step 0: setup ----------
MIN_LIB = (0, 8)
def _lib_version():
    try:
        from importlib.metadata import version
        return tuple(int(x) for x in version("notebooklm-py").split(".")[:2])
    except Exception:
        return (0, 0)
def ensure_library(auto_yes):
    try:
        mod = importlib.import_module("notebooklm")
        if _lib_version() >= MIN_LIB:
            return mod
        say(f"Your notebooklm-py is {'.'.join(map(str, _lib_version()))}, but this needs {'.'.join(map(str, MIN_LIB))} or newer.")
        if not auto_yes and input("Upgrade it now? [Y/n] ").strip().lower() not in ("", "y", "yes"):
            sys.exit('Upgrade with: pip install -U "notebooklm-py[browser]"')
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-U", "notebooklm-py[browser]"])
        sys.exit("Upgraded. Run the same command again.")
    except ImportError:
        pass
    say("notebooklm-py isn't installed.")
    if not auto_yes and input('Install it now with pip ("notebooklm-py[browser]")? [Y/n] ').strip().lower() not in ("", "y", "yes"):
        sys.exit('Install it yourself with: pip install "notebooklm-py[browser]"')
    subprocess.check_call([sys.executable, "-m", "pip", "install", "notebooklm-py[browser]"])
    subprocess.call([sys.executable, "-m", "playwright", "install", "chromium"])
    importlib.invalidate_caches()
    return importlib.import_module("notebooklm")

async def ensure_signed_in(nlm):
    try:
        async with await _open_client(nlm.NotebookLMClient) as c:
            await c.notebooks.list()
        return
    except Exception as ex:
        if not any(k in (type(ex).__name__ + str(ex)).lower() for k in ("auth", "login", "storage", "cookie", "expired")):
            raise
    say("You're not signed in to NotebookLM yet. A browser window will open; sign in to Google there.")
    exe = shutil.which("notebooklm") or str(Path(sys.executable).with_name("notebooklm"))
    if subprocess.call([exe, "login"]) != 0:
        sys.exit("Sign-in didn't finish. Run `notebooklm login` and try again.")

# ---------- dry run (no Google) ----------
class _Status:
    def __init__(self, tid): self.task_id = tid; self.status = "completed"
class _NS:  # tiny namespace
    def __init__(self, **kw): self.__dict__.update(kw)
class FakeClient:
    """Same method names as notebooklm-py, for testing the whole flow offline."""
    def __init__(self): self.notebooks = _NS(create=self._create, delete=self._delete); self.sources = _NS(add_file=self._add, add_url=self._add, add_text=self._add_text); self.artifacts = _NS(generate_audio=self._gen, generate_video=self._gen, generate_cinematic_video=self._gen, wait_for_completion=self._wait, download_audio=self._dl_audio, download_video=self._dl_video)
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def _create(self, title): await asyncio.sleep(0.05); return _NS(id="dry-notebook")
    async def _delete(self, nid): return None
    async def _add(self, nid, target, *a, **k): await asyncio.sleep(0.1); return _NS(id="dry-source")
    async def _add_text(self, nid, title, content, **k): return await self._add(nid, title)
    async def _gen(self, nid, **k): await asyncio.sleep(0.05); return _Status("dry-" + str(time.monotonic()))
    async def _wait(self, nid, tid, **k):
        await asyncio.sleep(0.3); cb = k.get("on_status_change"); cb and cb(_Status(tid)); return _Status(tid)
    async def _dl_audio(self, nid, path, *a, **k):
        with wave.open(path.replace(".m4a", ".wav") if path.endswith(".m4a") else path, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes(b"".join(struct.pack("<h", int(6000 * math.sin(2 * math.pi * f * i / 16000))) for f in (330, 440) for i in range(8000)))
        return path
    async def _dl_video(self, nid, path, *a, **k):
        return None  # no video in a dry run

# ---------- main flow ----------
async def run(a, nlm):
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    target = a.source
    is_url = target.startswith(("http://", "https://"))
    title = a.title or (target if is_url else Path(target).stem.replace("_", " ").replace("-", " "))
    t0 = time.monotonic(); timings = {}; errors = []
    Client = FakeClient if a.dry_run else nlm.NotebookLMClient
    enums = None if a.dry_run else nlm
    async with (Client() if a.dry_run else await _open_client(Client)) as client:
        nb = await client.notebooks.create(f"NeuralLoop: {title}"[:90])
        say(f"1/4  Notebook ready")
        try:
            t = time.monotonic()
            if is_url:
                src = await client.sources.add_url(nb.id, target, wait=True, wait_timeout=600.0)
            else:
                p = Path(target)
                if p.suffix.lower() not in FILE_TYPES: raise SystemExit(f"Unsupported file type {p.suffix}. Use PDF, Markdown, text, DOCX, or a link.")
                src = await client.sources.add_file(nb.id, str(p), wait=True, wait_timeout=900.0, title=title[:90])
            timings["source"] = round(time.monotonic() - t); sid = [src.id]
            say(f"2/4  Source added and processed ({timings['source']}s)")

            jobs = {}
            if a.audio != "none":
                kw = dict(source_ids=sid, language=a.language, instructions=a.instructions)
                if enums: kw.update(audio_format=nlm.AudioFormat[AUDIO[a.audio]], audio_length=nlm.AudioLength[LENGTH[a.length]])
                jobs["audio"] = await client.artifacts.generate_audio(nb.id, **kw)
            if a.video != "none":
                if a.video == "cinematic":
                    jobs["video"] = await client.artifacts.generate_cinematic_video(nb.id, source_ids=sid, language=a.language, instructions=a.instructions)
                else:
                    kw = dict(source_ids=sid, language=a.language, instructions=a.instructions)
                    if enums: kw.update(video_format=nlm.VideoFormat[VIDEO[a.video]], video_style=nlm.VideoStyle[STYLE[a.style]])
                    jobs["video"] = await client.artifacts.generate_video(nb.id, **kw)
            say(f"3/4  Making {' and '.join(jobs)} at the same time. This usually takes 5-20 minutes; you can leave it running.")

            started = time.monotonic()
            async def wait(kind, st, timeout):
                def changed(s): say(f"     {kind}: {getattr(s, 'status', s)}  ({time.monotonic() - started:.0f}s)")
                try:
                    await client.artifacts.wait_for_completion(nb.id, st.task_id, timeout=timeout, on_status_change=changed)
                    path = out / ("podcast.m4a" if kind == "audio" else "video.mp4")
                    dl = client.artifacts.download_audio if kind == "audio" else client.artifacts.download_video
                    res = await dl(nb.id, str(path), st.task_id)
                    timings[kind] = round(time.monotonic() - started)
                    if a.dry_run and kind == "audio": path = path.with_suffix(".wav")
                    return str(path) if (res is not None or path.exists()) else None
                except Exception as ex:
                    errors.append(f"{kind}: {type(ex).__name__}: {ex}"[:300]); return None
            results = dict(zip(jobs, await asyncio.gather(*(wait(k, v, 1800.0 if k == "audio" else 3600.0) for k, v in jobs.items()))))
            say("4/4  Downloaded")
        finally:
            if not a.keep:
                try: await client.notebooks.delete(nb.id)
                except Exception as ex: errors.append(f"cleanup: {ex}")
    timings["total"] = round(time.monotonic() - t0)
    manifest = {"source": {"title": title, "target": target, "type": "url" if is_url else Path(target).suffix.lstrip(".")},
                "media": {"audio": results.get("audio"), "video": results.get("video")},
                "options": {"audio": a.audio, "length": a.length, "video": a.video, "style": a.style, "language": a.language},
                "generator": {"engine": "notebooklm", "tool": "notebooklm-py", "dryRun": a.dry_run}, "timings": timings, "errors": errors}
    (out / "media.json").write_text(json.dumps(manifest, indent=2))
    page = out / "index.html"; page.write_text(player_page(manifest, out))
    say(f"\nDone in {timings['total']}s.")
    for k in ("audio", "video"):
        if k in results:
            status = results[k] or ("not made in a dry run" if a.dry_run and k == "video" else "failed (see Problems)")
            say(f"  {'Podcast' if k == 'audio' else 'Video'}: {status}" + (f"  ({timings[k]}s)" if results[k] and k in timings else ""))
    for e in errors: say(f"  Problem: {e}")
    say(f"  Player: {page.resolve()}")
    if not a.no_open: webbrowser.open(page.resolve().as_uri())
    return 0 if any(results.values()) else 1

def player_page(m, out):
    rel = lambda p: os.path.relpath(p, out) if p else None
    a, v = rel(m["media"]["audio"]), rel(m["media"]["video"])
    t = html.escape(m["source"]["title"])
    audio_block = f'<audio controls preload="metadata" src="{html.escape(a)}"></audio>' if a else '<p class="muted">No podcast this time.</p>'
    video_block = f'<video controls preload="metadata" src="{html.escape(v)}"></video>' if v else '<p class="muted">No video this time.' + (" (Dry runs don't make video.)" if m["generator"]["dryRun"] else "") + "</p>"
    errs = "".join(f"<li>{html.escape(e)}</li>" for e in m["errors"])
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{t} · NeuralLoop</title><style>
:root{{--paper:#F4F7FC;--surface:#fff;--ink:#1C2340;--ink2:#58607A;--line:#DDE3EF;--accent:#3552D8;color-scheme:light}}
@media (prefers-color-scheme:dark){{:root{{--paper:#131A2D;--surface:#1B2440;--ink:#EEF1FA;--ink2:#A9B1C8;--line:#2D3858;--accent:#8196FF;color-scheme:dark}}}}
body{{margin:0;background:var(--paper);color:var(--ink);font:17px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif}}
main{{max-width:860px;margin:0 auto;padding:32px 20px 48px}} header{{display:flex;gap:16px;align-items:center;margin-bottom:24px}}
h1{{margin:0;font-size:1.7rem;line-height:1.2}} .muted{{color:var(--ink2)}} section{{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:18px;margin-top:16px}}
h2{{margin:0 0 10px;font-size:1.1rem}} audio,video{{width:100%;border-radius:12px}} small{{color:var(--ink2)}}
</style></head><body><main>
<header>{PIP_ICON}<div><p class="muted" style="margin:0">Made for you by NeuralLoop</p><h1>{t}</h1></div></header>
<section><h2>Podcast</h2>{audio_block}<small>{html.escape(m["options"]["audio"])} · {html.escape(m["options"]["length"])} length</small></section>
<section><h2>Video</h2>{video_block}<small>{html.escape(m["options"]["video"])} · {html.escape(m["options"]["style"])} style</small></section>
{f'<section><h2>Problems</h2><ul>{errs}</ul></section>' if errs else ''}
<p class="muted" style="margin-top:20px">Generated with Google NotebookLM via notebooklm-py{" (dry run)" if m["generator"]["dryRun"] else ""} in {m["timings"].get("total", 0)} seconds.</p>
</main></body></html>"""

def main():
    ap = argparse.ArgumentParser(description="Book in, podcast and video out, in one step.")
    ap.add_argument("source", nargs="?", help="a PDF, Markdown, text, or DOCX file, or a link")
    ap.add_argument("--audio", choices=[*AUDIO, "none"], default="deep-dive")
    ap.add_argument("--length", choices=list(LENGTH), default="default")
    ap.add_argument("--video", choices=[*VIDEO, "none"], default="explainer")
    ap.add_argument("--style", choices=list(STYLE), default="whiteboard", help="video look (kawaii matches Pip)")
    ap.add_argument("--language", default="en", help="e.g. en, hi")
    ap.add_argument("--instructions", default=DEFAULT_INSTRUCTIONS)
    ap.add_argument("--title"); ap.add_argument("--out", default="neuralloop_media")
    ap.add_argument("--keep", action="store_true", help="keep the NotebookLM notebook afterwards")
    ap.add_argument("--no-open", action="store_true", help="don't open the player page")
    ap.add_argument("--yes", action="store_true", help="install without asking")
    ap.add_argument("--dry-run", action="store_true", help="run the whole flow offline with a fake NotebookLM")
    a = ap.parse_args()
    if a.dry_run and not a.source:
        a.source = str(Path(a.out) / "sample.md"); Path(a.out).mkdir(parents=True, exist_ok=True)
        Path(a.source).write_text("# Distribution shifts\n\nModels decay after launch because the world keeps moving.\n")
    if not a.source: ap.error("give a file or a link (or use --dry-run)")
    if not a.source.startswith(("http://", "https://")) and not Path(a.source).exists(): ap.error(f"file not found: {a.source}")
    nlm = None
    if not a.dry_run:
        nlm = ensure_library(a.yes)
        asyncio.run(ensure_signed_in(nlm))
    try:
        return asyncio.run(run(a, nlm))
    except KeyboardInterrupt:
        say("\nStopped. If a notebook was created, delete it at notebooklm.google.com."); return 130

if __name__ == "__main__":
    sys.exit(main())

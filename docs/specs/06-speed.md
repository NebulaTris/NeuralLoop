# Spec 06 — Fast enough to feel instant

Status: in progress (items 1, 2, and 6 done) · Read first: `CLAUDE.md`, specs 04 and 05 · Touches: `pipeline/`, the app

## Where the time goes (measured, Apple M5, 24 GB)

| Step | Time | Why |
|---|---|---|
| NotebookLM, one chapter, every item | ~11 min (reported) | each item is generated on Google's servers, then waited for, two at a time |
| Local text items (`qwen3:8b`): guide, graph, quiz, cards, mind map | 19–76 s each, ~4 min per chapter | the model re-reads the chapter for every item |
| Rumik podcast, 15 lines, 4.5 min of audio | ~18 min | Rumik speaks about 4× slower than real time on this Mac |
| Rumik explainer, 7 slides | ~9 min | same |
| Recall check (`gemma2:2b`), 3 key points | 4–7 s, including Python startup | one small call per key point, in parallel |
| First Rumik load | 6 min once (download), ~20 s after | model loaded fresh in every pipeline process |

The person waits for **their current chapter**, not the whole book. So the goal is: the Read step is available right away,
text items for chapter 1 arrive in under a minute, and audio starts playing while the rest is still being voiced.

## Practices

1. **Reading order, not item order.** *(done)* `BookState.pending()` finishes chapter 1 before starting chapter 2. Before
   this, every chapter's study guide came first, then every graph, and so on, so chapter 1 was complete only near the end.
2. **Separate lanes.** *(done)* Podcasts and explainers run in their own lane (`Options.media_parallel`), so a 20-minute
   voice job never holds up a 30-second quiz.
3. **Just in time, one chapter ahead.** Chapters unlock one at a time, so only make chapter N+1 while the person studies
   chapter N. The Read step needs no AI at all: the chapter text exists seconds after the split; reading-plan labels fill
   in when the guide arrives.
4. **NotebookLM: submit everything, then wait.** NotebookLM makes items on its servers, so waiting shouldn't take up a
   slot. Start all of a chapter's generations at once, then poll them together. A chapter then takes as long as its slowest
   item (usually the podcast) instead of the sum of all items. Needs one real run to find NotebookLM's concurrency limit;
   quota errors already fall back to the local engine per item.
5. **Right tool per item.** With `auto`, text items come from the local model (seconds to a minute) while NotebookLM makes
   its excellent podcasts and videos in the background. `ai.json` already allows this per item.
6. **Stream audio.** *(done in the pipeline; the app plays `clip`s in order until `complete`)* Voice the podcast line by line and let the app start playing as soon as the first lines exist (first
   sound in about a minute instead of 18). The transcript already has per-line start times; write it progressively.
7. **One warm worker instead of a process per run.** A long-lived pipeline worker that the app talks to over stdin/stdout
   JSON keeps Rumik and the models loaded: no 20-second Rumik load per book, and a recall check in 1–2 seconds instead of
   4–7. Ollama already keeps models warm for 30 minutes (`keep_alive`).
8. **Reuse the chapter prefix.** Every local prompt starts with the same system text and chapter, so Ollama and Claude
   reuse the cached prefix instead of re-reading the chapter (already structured this way; Claude uses `cache_control`).
   Next: one combined call for guide + quiz + cards, if quality holds.
9. **Faster voices when it matters.** Offer Rumik's 4-bit model as "faster voices" in Settings, and voice only the
   chapters the person has reached.
10. **Prewarm on launch.** When the app opens, load the recall model and Rumik in the background.

## Definition of done

- Chapter 1's Read step is usable within 10 seconds of adding a book.
- Chapter 1's text items are ready within 2 minutes on the default local model, and within 1 minute with a cloud key.
- The first podcast audio plays within 90 seconds of the podcast starting.
- A recall check answers within 2 seconds with a warm worker.

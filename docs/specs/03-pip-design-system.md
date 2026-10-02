# Spec 03 — Pip design system (reference)

Pip is NeuralLoop's companion: an original chibi red panda (not a cat, and never modelled on any other product's mascot).
This document is the reference for anything that shows Pip. The live character sheet (poses animated) is the canvas artifact
"Pip the red panda: NeuralLoop companion"; the code below is the source of truth.

## Files

| Path | What |
|---|---|
| `design/pip/generate_pip.py` | **Source of truth.** Draws every pose as SVG from shared parts (head, ears, fluffy cheeks, body, tail, arms, feet) and defines the animation CSS |
| `pipeline/site/pip-poses.js` | Generated: `window.PIP = {read, hop, nap, stretch, play, hug, study, proud, icon}` + `window.PIP_CSS` (study site) |
| `src/pip-poses.js` | Generated: same, for the desktop app and `pip.html` |
| `design/pip/app-icon.svg` | App icon (happy Pip head on moss green) |
| `src-tauri/icons/*` | Generated from the icon: `npx tauri icon design/pip/app-icon.png` after exporting a 1024×1024 PNG |

Regenerate after any artwork change: `python design/pip/generate_pip.py` (writes both `pip-poses.js` files). Add a CI step that
regenerates and fails if `git diff --exit-code` shows the committed files are stale.

## Using Pip in UI code

```js
element.innerHTML = `<div class="pip moving">${window.PIP[pose]}</div>`;   // animated
element.innerHTML = `<div class="pip">${window.PIP[pose]}</div>`;          // still (screenshots, reduced motion is automatic)
```
Inject `window.PIP_CSS` once per page (`<style>`). Each pose SVG has `role="img"` and an `aria-label` like "Pip reading a book";
when the person renamed Pip, replace the name in the label. Helpers already exist: `pip()` in `pipeline/site/src/ui/dom.js` and
`src/js/dom.js`.

## Poses and when to use them

| Pose | Looks like | Use for |
|---|---|---|
| `read` | sitting with an open book; blinks, head tilts, page turns, tail sways | default, content, "all good" |
| `hop` | bouncing with both paws up (pink beans), stars twinkle | a step finished, a correct answer, a nudge arriving |
| `nap` | curled up, slow breathing, drifting "z" | focus running, quiet hours, waiting for NotebookLM's limit |
| `stretch` | long stretch with a yawn | welcome back after days away, something failed and will be retried |
| `play` | batting a loose blue yarn ball | due cards, a half-finished chapter ("loose yarn") |
| `hug` | hugging a wound-up yarn ball, hearts float up | a loop closed, a session finished |
| `study` | tiny round glasses at a laptop with a spinner | something is being prepared |
| `proud` | chest puffed, medal swinging, stars | goal met, a great score, a finished book |
| `icon` | happy head only | tray, headers, small sizes |
| `sad` | floppy ears hanging down, a tear, its own little rain cloud | Silly mode nudges only (the sad violin and sad meow steps): the big on-screen Pip and the notification picture |
| `shocked` | fur on end, paws on cheeks, "!" | Silly mode nudges only (the "fahhh" step): the big on-screen Pip and the notification picture |

Rules: Pip is **never** angry, disappointed, or hungry. No guilt copy. Only one Pip per screen region. The only sad Pip is a joke:
the `sad` and `shocked` poses appear only in Silly mode's nudges (by default 8, 12, and 24 hours away; the steps are the
person's to change), which always say what's ready and can be turned off in Settings → Nudges.

## Sizes

| Place | Size |
|---|---|
| Menu bar / tray | 22 px (template icon on macOS: single colour) |
| Headers, chips | 36–46 px (`icon`) |
| Book cover corner | 58 px |
| Side column, bubbles | 160–220 px |
| Empty and locked states | 190 px |
| Hero | 280–400 px |
| Desktop companion | 96 / 140 / 180 px (spec 01) |

## Colour

| Part | Hex |
|---|---|
| Fur (rust) | `#CF5F39` |
| Fur highlight | `#E4855A` |
| Tail rings | `#F2B48E` |
| Face, cheeks, ear insides (cream) | `#FFF4E6` |
| Paws, legs, belly (cocoa) | `#4B302A` |
| Outline | `#3B2A26` |
| Blush, paw beans | `#F29AA6` |
| Eyes | `#2A1D1B` with iris `#6A3A2B` |
| Yarn | `#6F8FE8` |
| App icon ground | `#3E7A62` (moss green) |
Pip's colours do not change in dark mode. UI tokens for surrounding UI are at the top of `pipeline/site/styles.css`
(warm peach light theme, cocoa dark theme) and `src/styles.css`.

## Motion

All animation is CSS on classes inside the SVG (`tail`, `lids`, `tilt`, `breathe`, `hop`, `twinkle`, `zz`, `yawn`, `swipe`,
`roll`, `rock`, `heart`, `spin`, `type-l`, `type-r`, `swing`, `page`, `puff`, `bob`, `watch`), enabled only under
`.moving` and only when `prefers-reduced-motion: no-preference`. Loops are 1–5 s, small amplitude (tail ±8°, breathing 2–7 %).
Never animate the tray icon or anything to demand attention. `transform-box: fill-box` is set only on animated classes (setting
it globally breaks the SVG's own mirroring transforms).

## Voice

Pip talks in short, warm sentences in the first person, offers one next step with a time estimate, and suggests rest at night
("It's late. One small loop, then sleep. Sleep is when memories set."). No exclamation-mark storms, no emoji in body text
(emoji are fine at the start of notification titles: 🐾 🧶 📚 🌱 🔓).

## Future art

For final artwork, give an illustrator this document and the character sheet; animate their art in Rive with a state machine
whose inputs are the pose names above, and keep the SVG poses as the fallback.

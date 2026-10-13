# Spec 03 — Pip design system (reference)

Pip is NeuralLoop's companion: an original chibi red panda (not a cat, and never modelled on any other product's mascot).
This document is the reference for anything that shows Pip. The live character sheet (poses animated) is the canvas artifact
"Pip the red panda: NeuralLoop companion"; the code below is the source of truth.

## Files

| Path | What |
|---|---|
| `design/pip/generate_pip.py` | **Source of truth.** Draws every pose as SVG from shared parts (head, ears, fluffy cheeks, body, tail, arms, feet); every animation is data in `ANIM` there. `make pip` runs it |
| `apple/App/Resources/pip-rig.json` | Generated: every pose as layers, each animated group's pivot and keyframes (the Mac and iPad apps) |
| `apple/App/Resources/PipLayers/*.png` | Generated: each layer as a transparent 3x bitmap, plus the menu-bar icon (redrawn only when a layer's art hash changes) |
| `pipeline/neuralloop_books/assets/pip-poses.js` | Generated: the poses as SVG plus the animation CSS, for explainer videos |
| `design/pip/app-icon.svg` | App icon (happy Pip head on moss green) |
| `apple/App/Resources/AppIcon.icns` | Generated from the icon: `python design/pip/make_app_icon.py` |
| `docs/readme/*` | Generated README pictures (hero, poses, demo GIF): `python design/readme/make_readme_art.py` (needs ffmpeg) |
| `apple/Sources/NeuralLoopCore/PipRig.swift` | Plays `pip-rig.json`: layers, pivots, keyframes, CSS easing (pure, tested) |
| `apple/App/Views/PipView.swift` | `PipView(pose:size:interactive:)` and `PipPose`, the SwiftUI view every screen uses |

Never edit the generated files by hand. Regenerate after any artwork change with `make pip` (`--force` redraws every
PNG). `make check` runs `generate_pip.py --check` and `make_app_icon.py --check`, and CI
(`.github/workflows/check.yml`) already regenerates Pip and fails when the committed files are stale.

## Using Pip in UI code

```swift
PipView(pose: .hop, size: 160)                      // animated; Reduce Motion stills it automatically
PipView(pose: .read, size: 58, interactive: false)  // inside a button (book covers): no hover wiggle or click hearts
```
Each pose's accessibility label (like "Pip reading a book") comes from `pip-rig.json`. Pips on the same screen start at
different points in their loops, so they never move in sync.

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
| `icon` | happy head only | the menu-bar icon, small sizes |
| `sad` | floppy ears hanging down, a tear, its own little rain cloud | Silly mode nudges only (the sad violin and sad meow steps): the big on-screen Pip and the notification picture |
| `shocked` | fur on end, paws on cheeks, "!" | Silly mode nudges only (the "fahhh" step): the big on-screen Pip and the notification picture |

Rules: Pip is **never** angry, disappointed, or hungry. No guilt copy. Only one Pip per screen region. The only sad Pip is a joke:
the `sad` and `shocked` poses appear only in Silly mode's nudges (by default 8, 12, and 24 hours away; the steps are the
person's to change), which always say what's ready and can be turned off in Settings → Nudges.

## Sizes

| Place | Size |
|---|---|
| Menu bar | 19 × 18 pt (`ICON_SIZE` in `generate_pip.py`) |
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
Pip's colours do not change in dark mode. Tokens for the surrounding UI (warm peach light theme, cocoa dark theme) are in
`apple/App/Views/Theme.swift`.

## Motion

Every animation is data in `ANIM` in `design/pip/generate_pip.py`, keyed by the animated groups inside each pose (`tail`,
`lids`, `tilt`, `breathe`, `hop`, `twinkle`, `zz`, `yawn`, and so on). The same data becomes CSS for explainer videos
(`pip-poses.js`) and keyframes in `pip-rig.json`, which `PipRig` plays in the apps. Reduce Motion stops it (`PipView` shows the
still pose); the CSS only runs under `.moving` and `prefers-reduced-motion: no-preference`. Loops are 1–5 s, small amplitude
(tail about ±8°, breathing 2–7 %). Never animate the menu-bar icon or anything to demand attention. In the CSS,
`transform-box: fill-box` is set only on animated classes (setting it globally breaks the SVG's own mirroring transforms).

## Voice

Pip talks in short, warm sentences in the first person, offers one next step with a time estimate, and suggests rest at night
("It's late. One small loop, then sleep. Sleep is when memories set."). No exclamation-mark storms, no emoji in body text
(emoji are fine at the start of notification titles: 🐾 🧶 📚 🌱 🔓).

## Future art

For final artwork, give an illustrator this document and the character sheet; animate their art in Rive with a state machine
whose inputs are the pose names above, and keep the generated rig as the fallback.

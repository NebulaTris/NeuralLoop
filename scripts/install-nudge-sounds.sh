#!/usr/bin/env bash
# Your own sounds for Pip's silly nudges (Settings → Nudges → Silly mode), on this Mac only:
#
#   scripts/install-nudge-sounds.sh VIOLIN MEOW FAHHH
#
# Each file (MP3, M4A, WAV, …) becomes ~/Library/Sounds/NeuralLoop-<name>.caf, at an even loudness and at most 12
# seconds (fading out), which is where notifications find it. The app ships no sounds of its own: only bundle sounds
# whose licence allows it. Needs ffmpeg (brew install ffmpeg). Pass "-" to skip one.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 VIOLIN MEOW FAHHH   (use - to skip one)" >&2
  exit 2
fi
command -v ffmpeg >/dev/null || { echo "This needs ffmpeg: brew install ffmpeg" >&2; exit 3; }

out="$HOME/Library/Sounds"
mkdir -p "$out"
names=(sad-violin sad-meow fahhh)
i=0
for source in "$@"; do
  name="${names[$i]}"
  i=$((i + 1))
  [ "$source" = "-" ] && continue
  [ -f "$source" ] || { echo "Not found: $source" >&2; exit 2; }
  target="$out/NeuralLoop-$name.caf"
  # Even loudness, a short fade if it's cut at 12 s, 16-bit PCM in a CAF (what notification sounds accept).
  ffmpeg -nostdin -loglevel error -y -i "$source" -t 12 \
    -af "loudnorm=I=-16:TP=-1.5,afade=t=out:st=10.5:d=1.5" -ar 44100 -c:a pcm_s16le -f caf "$target"
  echo "  ✓ $name → $target"
done
echo "Done. Try them in NeuralLoop: Settings → Nudges → Silly mode."

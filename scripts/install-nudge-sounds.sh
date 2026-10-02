#!/usr/bin/env bash
# Sounds for Pip's silly nudges (Settings → Nudges → Silly mode):
#
#   scripts/install-nudge-sounds.sh VIOLIN MEOW FAHHH                      # yours, on this Mac (~/Library/Sounds)
#   OUT=apple/App/Resources scripts/install-nudge-sounds.sh VIOLIN MEOW FAHHH  # the ones the app ships
#
# Each file (MP3, M4A, WAV, …) becomes NeuralLoop-<name>.caf: every tag stripped (no export or device details), an
# even loudness, at most 12 seconds (fading out), IMA4-compressed (a format notification sounds accept). The app's own
# sounds win over ~/Library/Sounds. Needs ffmpeg (brew install ffmpeg) and macOS's afconvert. Pass "-" to skip one.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 VIOLIN MEOW FAHHH   (use - to skip one)" >&2
  exit 2
fi
command -v ffmpeg >/dev/null || { echo "This needs ffmpeg: brew install ffmpeg" >&2; exit 3; }

out="${OUT:-$HOME/Library/Sounds}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
names=(sad-violin sad-meow fahhh)
i=0
for source in "$@"; do
  name="${names[$i]}"
  i=$((i + 1))
  [ "$source" = "-" ] && continue
  [ -f "$source" ] || { echo "Not found: $source" >&2; exit 2; }
  target="$out/NeuralLoop-$name.caf"
  # No tags, even loudness, a short fade if it's cut at 12 s; then IMA4 in a CAF.
  ffmpeg -nostdin -loglevel error -y -i "$source" -t 12 -map_metadata -1 -map 0:a:0 -fflags +bitexact \
    -af "loudnorm=I=-16:TP=-1.5,afade=t=out:st=10.5:d=1.5" -ar 44100 -ac 2 -c:a pcm_s16le "$work/$name.wav"
  afconvert -f caff -d ima4 "$work/$name.wav" "$target"
  echo "  ✓ $name → $target"
done
echo "Done. Try them in NeuralLoop: Settings → Nudges → Silly mode."

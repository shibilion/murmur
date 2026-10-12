#!/bin/zsh
# Records voice clips for the optional engine tests (Tests/Fixtures/audio, not committed).
# Output: Tests/Fixtures/audio/<name>.wav (16 kHz mono 16-bit PCM) and <name>.txt (what you said).
# Usage: scripts/record-fixtures.sh            record all four clips
#        scripts/record-fixtures.sh hi_short   re-record one clip
#        MIC=1 scripts/record-fixtures.sh      use a different input device (see the list printed below)
set -euo pipefail

cd "${0:A:h}/.."
OUT=Tests/Fixtures/audio
mkdir -p "$OUT"
MIC="${MIC:-default}"

typeset -A PROMPTS=(
  en_short       "A normal English sentence with a name in it (~5 s)."
  en_long        "A ~20 s paragraph. Include an 'um' or two and a self-correction, like 'Tuesday, no, Wednesday'."
  hi_short       "A Hindi sentence (~5 s)."
  hinglish_short "A mixed Hindi-English sentence, like 'kal ki meeting reschedule kar do, please' (~5 s)."
)
ORDER=(en_short en_long hi_short hinglish_short)
(( $# )) && ORDER=("$@")

echo "Input devices:"
ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n '/audio devices/,$p' | sed 's/^\[[^]]*\] /  /' || true
echo "Using mic: $MIC  (set MIC=<index> to change)\n"

record() {
  local name=$1 wav="$OUT/$1.wav"
  while true; do
    echo "── $name ─────────────────────────"
    echo "Say: ${PROMPTS[$name]:-anything}"
    read -r "?Press Enter to start recording… "
    ffmpeg -hide_banner -loglevel error -y -f avfoundation -i ":$MIC" \
      -ac 1 -ar 16000 -c:a pcm_s16le "$wav" </dev/null &
    local pid=$!
    sleep 0.3
    read -r "?● Recording. Press Enter to stop… "
    kill -INT $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true

    local secs
    secs=$(afinfo "$wav" 2>/dev/null | awk '/estimated duration/ {printf "%.1f", $3}')
    echo "Saved $wav (${secs:-?} s). Playing it back…"
    afplay "$wav"
    read -r "?Keep it? [Y/n] " keep
    [[ "${keep:-y}" == [nN]* ]] && continue

    read -r "?Type exactly what you said: " text
    print -r -- "$text" > "$OUT/$name.txt"
    echo "Saved $OUT/$name.txt\n"
    break
  done
}

for n in $ORDER; do record "$n"; done
echo "Done. Clips are in $OUT:"
ls -1 "$OUT"

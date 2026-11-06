#!/usr/bin/env bash
# Verifica automatica della pipeline video (Linux, dentro una sessione Wayland —
# anche headless: `WLR_BACKENDS=headless sway` e WAYLAND_DISPLAY puntato lì).
#
# Genera clip di prova con ffmpeg (H.264+AAC, HEVC, VP9, senza audio, 2 s, solo
# audio), poi con `zuer-video-bench` controlla per ciascuno apertura, play, pausa,
# seek e, sul clip principale, 100 cicli apri/chiudi e 30 a freddo. Fallisce se:
# un'apertura fallisce, la pausa consuma CPU, un seek non arriva, fd o thread
# crescono tra i cicli, ci sono chiamate GL/mpv dal thread sbagliato.
#
#   scripts/video-check.sh [cartella-lavoro]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-$(mktemp -d)}
BENCH="$ROOT/zig-out/bin/zuer-video-bench"
mkdir -p "$WORK"

[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "serve una sessione Wayland (WAYLAND_DISPLAY)"; exit 2; }
command -v ffmpeg >/dev/null || { echo "serve ffmpeg per generare i clip"; exit 2; }
(cd "$ROOT" && zig build video-bench -Doptimize=ReleaseFast -j2)

gen() { [ -f "$WORK/$1" ] || ffmpeg -loglevel error -y "${@:2}" "$WORK/$1"; }
SRC=(-f lavfi -i testsrc2=size=1920x1080:rate=60)
TONE=(-f lavfi -i sine=frequency=440:sample_rate=48000)
gen h264.mp4   "${SRC[@]}" "${TONE[@]}" -t 20 -c:v libx264 -preset veryfast -g 60 -pix_fmt yuv420p -c:a aac -shortest
gen hevc.mp4   -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 10 -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1
gen vp9.webm   -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 10 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 2M
gen noaudio.mp4 "${SRC[@]}" -t 10 -c:v libx264 -preset veryfast -pix_fmt yuv420p
gen short.mp4  "${SRC[@]}" "${TONE[@]}" -t 2 -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest
gen tone.mp3   "${TONE[@]}" -t 5

fail=0
check() { if ! eval "$2"; then echo "FALLITO: $1"; fail=1; else echo "ok: $1"; fi; }

run() { "$BENCH" "$@" 2>&1 | grep '^bench:' || true; }

for clip in h264.mp4 hevc.mp4 vp9.webm noaudio.mp4 short.mp4; do
    out=$(run "$WORK/$clip" play 3 pause 2 seek)
    echo "$out" | sed "s|^|  [$clip] |"
    check "$clip si apre" "grep -q 'bench: open ms=' <<<\"\$out\""
    check "$clip in pausa sotto 2% CPU" "awk '/bench: pause/{split(\$0,a,\"cpu=\"); exit !(a[2]+0 < 2.0)}' <<<\"\$out\""
    check "$clip ogni seek arriva" "! grep -q 'ok=false' <<<\"\$out\""
    check "$clip niente chiamate dal thread sbagliato" "grep -q 'wrong_thread_calls=0' <<<\"\$out\""
done

out=$(run "$WORK/tone.mp3")
check "mp3 (senza video) rifiutato senza crash" "! grep -q 'bench: open ms=' <<<\"\$out\""

out=$(run "$WORK/h264.mp4" cycles 100 cycles-cold 30)
echo "$out" | grep -E 'cycles|end' | sed 's|^|  [cicli] |'
# A caldo gli fd oscillano (il motore resta vivo e l'uscita audio si apre e chiude
# a ogni sessione): conta la crescita, non l'uguaglianza — il massimo degli ultimi
# 20 cicli non supera quello dei primi 20. A freddo tutto torna al valore iniziale.
cyc() { awk -v k="$1" '/bench: cycle [0-9]+ /{n=$3; split($4,f,"="); split($5,t,"="); v=(k=="fds")?f[2]:t[2]; if(n<=20 && v>a) a=v; if(n>80 && v>b) b=v} END{print a, b}' <<<"$out"; }
check "cicli a caldo: fd non crescono" "read a b < <(cyc fds); [ \"\$b\" -le \"\$a\" ]"
check "cicli a caldo: thread non crescono" "read a b < <(cyc threads); [ \"\$b\" -le \$((a + 1)) ]"
check "cicli a freddo: fd e thread tornano" "awk '/bench: cycles-cold/{split(\$5,a,\"->\"); split(\$7,b,\"->\"); exit !(a[1]==a[2] && b[1]==b[2])}' <<<\"\$out\""
check "fine: fd e thread come all'inizio" "awk '/bench: start/{s=\$0} /bench: end/{e=\$0} END{sub(/.*start /,\"\",s); sub(/.*end /,\"\",e); exit !(s==e)}' <<<\"\$out\""

exit $fail

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

gen() { [ -f "$WORK/$1" ] && [ "$WORK/$1" -nt "$0" ] || ffmpeg -loglevel error -y "${@:2}" "$WORK/$1"; }
SRC=(-f lavfi -i testsrc2=size=1920x1080:rate=60)
# Traccia audio SILENZIOSA: il percorso audio lavora uguale, senza suonare nelle
# casse di chi lancia la verifica. In più mpv non apre l'uscita audio vera.
TONE=(-f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000)
export ZUER_MPV_OPTS="${ZUER_MPV_OPTS:-ao=null}"
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

# Sorgenti malformate (TS senza indice: libavformat non vi si riposiziona). Prima:
# apertura dopo 20 s di attesa del primo frame (anche `start=0` è un seek), chiusura
# da 1000 ms dopo un'apertura fallita, loop a vuoto al 95% di CPU sul file corto.
gen seg.ts "${SRC[@]}" "${TONE[@]}" -t 4 -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest -f mpegts
[ -f "$WORK/trunc.ts" ] && [ "$WORK/trunc.ts" -nt "$WORK/seg.ts" ] || head -c 1500000 "$WORK/seg.ts" > "$WORK/trunc.ts"
[ -f "$WORK/tiny.ts" ] && [ "$WORK/tiny.ts" -nt "$WORK/seg.ts" ] || head -c 188000 "$WORK/seg.ts" > "$WORK/tiny.ts"
[ -f "$WORK/garbage.ts" ] || head -c 2000000 /dev/urandom > "$WORK/garbage.ts"
: > "$WORK/empty.ts"
for clip in trunc.ts tiny.ts; do
    out=$(ZUER_TRACE=1 run "$WORK/$clip" play 3 seek)
    echo "$out" | sed "s|^|  [$clip] |"
    check "$clip si apre in meno di 3 s" "awk '/bench: open ms=/{split(\$0,a,\"ms=\"); f=(a[2]+0 < 3000)} END{exit !f}' <<<\"\$out\""
    check "$clip in riproduzione sotto 60% CPU" "awk '/bench: play/{split(\$0,a,\"cpu=\"); exit !(a[2]+0 < 60)}' <<<\"\$out\""
done
# Riaccensione del video (tasto v) da 1 s sul TS troncato: mpv non vi si posiziona;
# deve dirlo subito (ripiego) invece di aspettare 20 s il primo frame.
out=$(run "$WORK/trunc.ts" open-at 1)
echo "$out" | grep open-at | sed "s|^|  [trunc.ts] |"
check "trunc.ts riaperto da 1 s in meno di 3 s" "awk '/bench: open-at/{split(\$0,a,\" ms=\"); f=(a[2]+0 < 3000 && /ok=true/)} END{exit !f}' <<<\"\$out\""
# Decoder hardware che cede a metà: H.264 4:2:0 -> 4:4:4 (profilo che VA-API in genere
# non decodifica) -> 4:2:0, GOP da 5 s. Senza la ripartenza dal keyframe il software
# non mostrava nulla fino al keyframe successivo: 7 s di video fermo.
for part in "a yuv420p high 0" "b yuv444p high444 6" "c yuv420p high 12"; do
    set -- $part
    gen "hw_$1.ts" -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 6 -c:v libx264 -preset veryfast -g 150 -bf 0 -pix_fmt "$2" -profile:v "$3" -output_ts_offset "$4" -f mpegts
done
[ -f "$WORK/hwswitch.ts" ] && [ "$WORK/hwswitch.ts" -nt "$WORK/hw_c.ts" ] || cat "$WORK"/hw_{a,b,c}.ts > "$WORK/hwswitch.ts"
out=$("$BENCH" "$WORK/hwswitch.ts" play 14 2>&1 || true)
if grep -q 'riparto dal keyframe' <<<"$out"; then
    echo "$out" | grep -E 'bench: play|riparto' | sed "s|^|  [hwswitch.ts] |"
    check "hw->sw a metà: il video riparte subito (>= 330 frame in 14 s)" "awk '/bench: play/{split(\$0,a,\"frames=\"); exit !(a[2]+0 >= 330)}' <<<\"\$out\""
else
    echo "non applicabile: hw->sw a metà (qui l'hardware non cede sul 4:4:4, o non c'è)"
fi
for clip in garbage.ts empty.ts; do
    out=$(ZUER_TRACE=1 "$BENCH" "$WORK/$clip" 2>&1 || true)
    check "$clip rifiutato senza crash" "grep -q 'bench: open fallita' <<<\"\$out\" && grep -q 'bench: end fds=4 threads=1' <<<\"\$out\""
    check "$clip: il motore chiude in meno di 100 ms" "awk '/mpv stop in/{if (\$(NF-1)+0 >= 100) bad=1} END{exit bad}' <<<\"\$out\""
done

out=$(run "$WORK/h264.mp4" cycles 100 cycles-cold 30)
echo "$out" | grep -E 'cycles|end' | sed 's|^|  [cicli] |'
# A caldo gli fd oscillano di qualche unità (lo stream audio di PipeWire si apre e
# chiude in modo asincrono) e i thread di uno: conta la crescita lungo i 100 cicli —
# un leak vero (≥ 1 fd o thread per ciclo) la porta a ≥ 100. Il ritorno esatto ai
# valori di partenza lo verifica la riga di fine, dopo l'assestamento.
# cyc CAMPO SERIE FINE_PRIMI INIZIO_ULTIMI: massimo nei primi cicli, massimo negli ultimi.
cyc() { awk -v k="$1" -v c="$2" -v lo="$3" -v hi="$4" '$0 ~ "bench: cycle [0-9]+ " && seen==c {n=$3; split($4,f,"="); split($5,t,"="); v=(k=="fds")?f[2]:t[2]; if(n<=lo && v>a) a=v; if(n>hi && v>b) b=v} /bench: cycles/{seen++} END{print a+0, b+0}' <<<"$out"; }
check "cicli a caldo: fd non crescono" "read a b < <(cyc fds 0 20 80); [ \"\$b\" -le \$((a + 6)) ]"
check "cicli a caldo: thread non crescono" "read a b < <(cyc threads 0 20 80); [ \"\$b\" -le \$((a + 2)) ]"
check "cicli a freddo: fd tornano a ogni giro" "awk '/bench: cycles-cold/{split(\$5,a,\"->\"); exit !(a[1]==a[2])}' <<<\"\$out\""
check "cicli a freddo: thread non crescono" "read a b < <(cyc threads 1 10 20); [ \"\$b\" -le \$((a + 2)) ]"
check "fine: fd e thread come all'inizio" "awk '/bench: start/{s=\$0} /bench: end/{e=\$0} END{sub(/.*start /,\"\",s); sub(/.*end /,\"\",e); exit !(s==e)}' <<<\"\$out\""

exit $fail

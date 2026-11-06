#!/usr/bin/env bash
# Verifica di buffering e chiusura con sorgenti di rete (Linux, sessione Wayland,
# anche headless). Server locale `slow_http.py` (lento, muto, che cade, che non
# risponde), traccia video e audio separate come un DASH di YouTube, stesso
# percorso dell'apertura da yt-dlp (`video.setupStream`) via `zuer-video-bench`.
#
# Fallisce se: un'apertura che deve riuscire fallisce (o viceversa), una chiusura
# supera CLOSE_MAX_MS (anche con la rete ferma), un'apertura impossibile ci mette
# più di OPEN_FAIL_MAX_MS a dirlo, fd o thread non tornano ai valori di partenza,
# ci sono chiamate GL/mpv dal thread sbagliato, o la stessa traccia viene aperta
# più volte del necessario (sessioni duplicate).
#
#   scripts/net-check.sh [cartella-lavoro]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-$(mktemp -d)}
BENCH="$ROOT/zig-out/bin/zuer-video-bench"
PORT=${PORT:-18734}
CLOSE_MAX_MS=${CLOSE_MAX_MS:-300}
OPEN_FAIL_MAX_MS=${OPEN_FAIL_MAX_MS:-17000} # network-timeout di mpv: 15 s
mkdir -p "$WORK"

[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "serve una sessione Wayland (WAYLAND_DISPLAY)"; exit 2; }
command -v ffmpeg >/dev/null || { echo "serve ffmpeg per generare i clip"; exit 2; }
(cd "$ROOT" && zig build video-bench -Doptimize=ReleaseFast -j2)

# Audio muto, mai sulle casse (vedi video-check.sh).
export ZUER_MPV_OPTS="${ZUER_MPV_OPTS:-ao=null}"
gen() { [ -f "$WORK/$1" ] && [ "$WORK/$1" -nt "$0" ] || ffmpeg -loglevel error -y "${@:2}" "$WORK/$1"; }
gen net_v.mp4 -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 40 -c:v libx264 -preset veryfast -g 30 -b:v 6M -maxrate 6M -bufsize 6M -pix_fmt yuv420p -movflags +faststart
gen net_a.m4a -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 -t 40 -c:a aac -movflags +faststart

python3 "$ROOT/scripts/slow_http.py" "$WORK" "$PORT" 2> "$WORK/server.log" &
SP=$!
trap 'kill $SP 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
U="http://127.0.0.1:$PORT"

fail=0
check() { if ! eval "$2"; then echo "FALLITO: $1"; fail=1; else echo "ok: $1"; fi; }
run() { # nome url_video url_audio comandi...
    local name=$1 v=$2 a=$3; shift 3
    local from; from=$(wc -l < "$WORK/server.log")
    out=$(ZUER_BENCH_AUDIO_URL="$a" "$BENCH" "$v" "$@" 2>&1 | grep '^bench:' || true)
    reqs=$(tail -n +$((from + 1)) "$WORK/server.log")
    echo "$out" | sed "s|^|  [$name] |"
}
close_ok() { awk -v m="$CLOSE_MAX_MS" '/bench: close ms=/{split($3,a,"="); exit !(a[2]+0 <= m)}' <<<"$out"; }
end_ok() { awk '/bench: start/{s=$0} /bench: end/{e=$0} END{sub(/.*start /,"",s); sub(/.*end /,"",e); exit !(s==e)}' <<<"$out"; }
# Richieste GET per file: un DASH apre video e audio (più eventuali riaperture per
# Range dopo un seek); una sessione duplicata raddoppierebbe le aperture iniziali.
gets() { grep -c "\"GET /[^ ]*$1" <<<"$reqs" || true; }

# 1. Rete normale: si apre, suona, una connessione per traccia.
run normale "$U/ok/net_v.mp4" "$U/ok/net_a.m4a" play 4
check "normale: si apre" "grep -q 'bench: open ms=' <<<\"\$out\""
check "normale: frame a schermo" "awk '/bench: play/{split(\$4,a,\"=\"); exit !(a[2]+0 > 60)}' <<<\"\$out\""
check "normale: una sola apertura per traccia (niente sessioni duplicate)" "[ \$(gets net_v.mp4) -le 2 ] && [ \$(gets net_a.m4a) -le 2 ]"
check "normale: chiusura entro ${CLOSE_MAX_MS} ms" close_ok
check "normale: fd e thread come all'inizio" end_ok

# 2. Rete più lenta del bitrate: buffering prolungato, seek durante il buffering.
run lenta "$U/slow/450000/net_v.mp4" "$U/ok/net_a.m4a" play 8 seek
check "lenta: si apre" "grep -q 'bench: open ms=' <<<\"\$out\""
check "lenta: il buffering viene segnalato" "awk '/bench: play/{split(\$NF,a,\"=\"); exit !(a[2]+0 > 0)}' <<<\"\$out\""
check "lenta: chiusura durante il buffering entro ${CLOSE_MAX_MS} ms" close_ok
check "lenta: fd e thread come all'inizio" end_ok
check "lenta: niente chiamate dal thread sbagliato" "grep -q 'wrong_thread_calls=0' <<<\"\$out\""

# 3. La rete si ferma a metà (server muto, connessione aperta): chiusura in stallo.
run stallo "$U/stall-after/3000000/net_v.mp4" "$U/ok/net_a.m4a" play 8
check "stallo: chiusura con la rete ferma entro ${CLOSE_MAX_MS} ms" close_ok
check "stallo: fd e thread come all'inizio" end_ok

# 4. La connessione cade a metà: niente crash, chiusura pulita.
run caduta "$U/drop/3000000/net_v.mp4" "$U/ok/net_a.m4a" play 6
check "caduta: chiusura entro ${CLOSE_MAX_MS} ms" close_ok
check "caduta: fd e thread come all'inizio" end_ok

# 5. Server che accetta e non risponde: l'apertura fallisce entro il timeout.
run muto "$U/hang/net_v.mp4" "$U/ok/net_a.m4a"
check "muto: apertura fallita entro ${OPEN_FAIL_MAX_MS} ms" "awk -v m=$OPEN_FAIL_MAX_MS '/bench: open fallita/{split(\$4,a,\"=\"); ok=(a[2]+0 <= m)} END{exit !ok}' <<<\"\$out\""
check "muto: fd e thread come all'inizio" end_ok

# 6. 404 e porta chiusa: errore subito, una sola richiesta (niente secondo decoder).
run 404 "$U/ok/manca.mp4" "$U/ok/net_a.m4a"
check "404: apertura fallita" "grep -q 'bench: open fallita' <<<\"\$out\""
check "404: una sola richiesta (nessun ritentativo con FFmpeg)" "[ \$(gets manca.mp4) -le 1 ]"
check "404: fd e thread come all'inizio" end_ok
run rifiutata "http://127.0.0.1:1/x.mp4" "http://127.0.0.1:1/x.m4a"
check "porta chiusa: apertura fallita" "grep -q 'bench: open fallita' <<<\"\$out\""
check "porta chiusa: fd e thread come all'inizio" end_ok

exit $fail

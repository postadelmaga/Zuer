#!/usr/bin/env bash
# Perdita del contesto GPU durante la riproduzione (prova di GUASTO INIETTATO, non un
# reset vero): ZUER_TEST_GPU_RESET_AFTER fa dichiarare perso il contesto del primo
# motore mpv dopo N frame. Verifica la ripartenza controllata del solo motore: video
# di nuovo a schermo, motore perso distrutto (thread e fd come prima), protocollo
# Wayland pulito. Muto (ao=null). Dentro una sessione Wayland, anche headless.
#
#   scripts/gpu-reset-check.sh [clip]
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "serve WAYLAND_DISPLAY"; exit 2; }
WORK=$(mktemp -d); LOG=$WORK/gui.log; gp=
trap '[ -n "$gp" ] && kill $gp 2>/dev/null; rm -rf "$WORK"' EXIT
CLIP=${1:-}
if [ -z "$CLIP" ]; then
    CLIP=$WORK/clip.mp4
    ffmpeg -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=60 -t 20 -c:v libx264 -preset veryfast -pix_fmt yuv420p "$CLIP"
fi
ZUER_MPV_OPTS=ao=null ZUER_TRACE=1 ZUER_TEST_GPU_RESET_AFTER=200 WAYLAND_DEBUG=client "$ROOT/zig-out/bin/zuer-gui" "$CLIP" > "$LOG" 2>&1 &
gp=$!
sleep 2.5; t1=$(ls /proc/$gp/task | wc -l); f1=$(ls /proc/$gp/fd | wc -l)
sleep 9;   t2=$(ls /proc/$gp/task | wc -l); f2=$(ls /proc/$gp/fd | wc -l)
kill $gp; wait $gp 2>/dev/null; gp=
after=$(python3 - "$LOG" <<'PY'
import re,sys
# frame video attaccati DOPO la riga di ripartenza
lines=open(sys.argv[1],errors='replace').read().splitlines()
i=next((k for k,l in enumerate(lines) if 'riparto il motore video' in l), None)
if i is None: print(-1); sys.exit()
A=re.compile(r'-> wl_surface#(\d+)\.attach\(wl_buffer#')
from collections import Counter
c=Counter(m[1] for l in lines[i:] for m in [A.search(l)] if m)
print(max(c.values()) if c else 0)
PY
)
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FALLITO: $1"; fail=1; fi; }
check "contesto perso rilevato" "grep -q 'contesto GPU perso' '$LOG'"
check "motore rifatto (ripartenza dalla posizione)" "grep -q 'riparto il motore video da' '$LOG'"
check "video di nuovo a schermo (>= 300 frame dopo, in ~8 s): $after" "[ $after -ge 300 ]"
check "motore perso distrutto: thread $t1 -> $t2, fd $f1 -> $f2" "[ $t2 -le $t1 ] && [ $f2 -le $f1 ]"
check "protocollo Wayland pulito" "python3 '$ROOT/scripts/wayland_check.py' '$LOG' > /dev/null"
exit $fail

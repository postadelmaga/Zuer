#!/usr/bin/env bash
# Verifica della sincronizzazione del piano video dmabuf (produttore mpv/GPU →
# compositor) su un compositor wlroots (sway, anche headless) con `grim`.
#
# Riproduce un clip a 60 fps in cui ogni frame è un colore pieno diverso dal
# precedente, e cattura N schermate dal compositor. Se il compositor campiona un
# buffer che la GPU sta ancora scrivendo (fence mancante o ignorato), o se mpv
# riscrive un buffer ancora in lettura, la schermata mostra due colori: frame
# "strappato". Con la sincronizzazione corretta ogni schermata è uniforme.
#
#   scripts/video-sync-check.sh [N] [env...]     (es. ZUER_VIDEO_SYNC=flush)
#
# Da rifare su ogni driver nuovo (NVIDIA proprietario in particolare): la riga
# "dmabuf su … consegna: …" del log dice quale modalità era attiva.
set -euo pipefail

N=${1:-300}; shift || true
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUI=${ZUER_GUI:-$ROOT/zig-out/bin/zuer-gui}
WORK=$(mktemp -d); GP=
# Anche se una cattura fallisce (set -e): la GUI non deve restare aperta, una
# seconda finestra falserebbe le verifiche successive.
trap '[ -n "$GP" ] && kill $GP 2>/dev/null; rm -rf "$WORK"' EXIT
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "serve WAYLAND_DISPLAY (compositor wlroots)"; exit 2; }
command -v grim >/dev/null || { echo "serve grim"; exit 2; }
export ZUER_MPV_OPTS="${ZUER_MPV_OPTS:-ao=null}"

ffmpeg -loglevel error -y -f lavfi \
    -i "color=c=black:s=1280x720:r=60,geq=r='255*mod(N\,2)':g='255*mod(floor(N/2)\,2)':b='255*mod(floor(N/4)\,2)'" \
    -t 30 -c:v libx264 -preset veryfast -crf 10 -pix_fmt yuv420p "$WORK/flash.mp4"

env "$@" "$GUI" "$WORK/flash.mp4" > "$WORK/gui.log" 2>&1 &
GP=$!
sleep 4 # apertura e controlli che spariscono
for i in $(seq -w 1 "$N"); do grim -t ppm "$WORK/s$i.ppm"; done
kill $GP; wait $GP 2>/dev/null || true; GP=
grep -E "dmabuf su|piano dmabuf|readback" "$WORK/gui.log" || true

python3 - "$WORK" <<'EOF'
import glob, sys
from PIL import Image
files = sorted(glob.glob(sys.argv[1] + "/s*.ppm"))
torn = 0; colors = set()
for f in files:
    im = Image.open(f).convert("RGB")
    W, H = im.size
    # Griglia nel centro (dentro il video anche con le bande nere).
    pts = [im.getpixel((int(W * (0.2 + 0.1 * i)), int(H * (0.3 + 0.1 * j)))) for i in range(7) for j in range(5)]
    spread = max(max(p[k] for p in pts) - min(p[k] for p in pts) for k in range(3))
    q = tuple(1 if v > 127 else 0 for v in pts[0])
    colors.add(q)
    if spread > 80:
        torn += 1
        print("strappato:", f.rsplit("/", 1)[1], "colori", sorted(set(tuple(1 if v > 127 else 0 for v in p) for p in pts)))
print("sync: schermate=%d strappate=%d colori_distinti=%d" % (len(files), torn, len(colors)))
sys.exit(1 if torn or len(colors) < 4 else 0)
EOF

#!/usr/bin/env bash
# Prove del decoder immagini con file veri (tests/images: le immagini di esempio di
# ImageMagick convertite in ogni formato, più casi costruiti apposta) e con file
# corrotti o enormi generati al volo. Gira uguale su Linux, macOS e Windows (Git Bash):
# usa feature-probe, cioè lo stesso registro dei plugin di zuer-gui.
#
#   scripts/image-check.sh <feature-probe> [cartella-immagini]
#
# Esce 1 al primo gruppo di prove fallito; stampa ogni esito.
set -uo pipefail
PROBE="$1"
IMG="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../tests/images" && pwd)}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
case "$(uname -s)" in
  Darwin) OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *) OS=linux ;;
esac
W() { if [[ $OS == windows ]]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
PY=python3; command -v python3 >/dev/null || PY=python
FAIL=0
run() { "$PROBE" "$@" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }
must() { run "$@" || FAIL=1; }
# Codec di sistema che può mancare (HEIC/AVIF su Windows senza le estensioni dello
# Store): avviso, non errore — ma l'errore dev'essere pulito, non un crash.
optional() {
  local f=$1; shift
  if ! run doc "$(W "$f")"; then
    echo "::warning::$(basename "$f"): codec di sistema assente su $OS"
    run fail "$(W "$f")" "Errore caricamento immagine" || FAIL=1
  fi
}

echo "── formati ($OS)"
for f in rose.png rose.jpg rose16.png logo.png logo.gif logo.bmp logo.tga logo.psd logo.ppm \
         logo.webp alpha.webp anim.webp logo.ico png-entry.ico icon8.ico logo.svg logo.svgz logo.tiff; do
  must doc "$(W "$IMG/$f")"
done
if [[ $OS == windows ]]; then optional "$IMG/logo.avif"; optional "$IMG/rose.heic"
else must doc "$(W "$IMG/logo.avif")"; must doc "$(W "$IMG/rose.heic")"; fi

echo "── contenuto: colori, trasparenza, orientamento EXIF"
must pixel "$(W "$IMG/alpha.png")" 0.04 0.05 255 255 255   # trasparente → bianco
must pixel "$(W "$IMG/alpha.png")" 0.5 0.5 0 0 255
must pixel "$(W "$IMG/alpha.webp")" 0.04 0.05 255 255 255
must pixel "$(W "$IMG/alpha.webp")" 0.5 0.5 0 0 255
must pixel "$(W "$IMG/anim.webp")" 0.5 0.5 255 0 0          # primo fotogramma
must pixel "$(W "$IMG/png-entry.ico")" 0.5 0.5 0 0 255      # vince la voce PNG 64x64
must pixel "$(W "$IMG/icon8.ico")" 0.2 0.5 255 0 0          # DIB a palette
must pixel "$(W "$IMG/icon8.ico")" 0.8 0.5 255 255 255
must pixel "$(W "$IMG/logo.svg")" 0.05 0.3 0 0 255
must pixel "$(W "$IMG/logo.svg")" 0.99 0.02 255 255 255
must pixel "$(W "$IMG/logo.svgz")" 0.05 0.3 0 0 255
# Sorgente 200x100: metà sinistra rossa, destra blu.
must pixel "$(W "$IMG/orient6.jpg")" 0.5 0.2 255 0 0        # 90° orario: rosso in alto
must pixel "$(W "$IMG/orient6.jpg")" 0.5 0.8 0 0 255
must pixel "$(W "$IMG/orient8.jpg")" 0.5 0.2 0 0 255        # 90° antiorario: blu in alto
must pixel "$(W "$IMG/orient3.jpg")" 0.2 0.5 0 0 255        # 180°: blu a sinistra
OUT="$(run doc "$(W "$IMG/orient6.jpg")")"; echo "$OUT"
grep -q 'immagine 80x160' <<<"$OUT" || { echo "FALLITO: orient6.jpg non ruotata (attese 80x160 da 200x100)"; FAIL=1; }

echo "── file corrotti, vuoti, enormi"
"$PY" - "$(W "$IMG")" "$(W "$TMP")" <<'EOF'
import os, struct, sys, zlib
img, tmp = sys.argv[1], sys.argv[2]
def cut(src, n, dst):
    b = open(os.path.join(img, src), 'rb').read(); open(os.path.join(tmp, dst), 'wb').write(b[:n])
cut('logo.png', 300, 'troncato.png')
cut('rose.jpg', 400, 'troncato.jpg')
cut('logo.webp', 200, 'troncato.webp')
cut('logo.tiff', 500, 'troncato.tiff')
open(os.path.join(tmp, 'vuoto.png'), 'wb').close()
open(os.path.join(tmp, 'spazzatura.jpg'), 'wb').write(os.urandom(4096))
open(os.path.join(tmp, 'rotto.svg'), 'w').write('<svg xmlns="http://www.w3.org/2000/svg"><rect')
def png(path, w, h):
    # Righe tutte uguali (strisce verticali): il PNG compresso resta piccolo anche a
    # 13000 px, e l'immagine non è di un colore solo.
    row = b'\x00' + (b'\x00\x00\x00' * 50 + b'\xff\xff\xff' * 50) * (w // 100) + b'\x80\x80\x80' * (w % 100)
    z = zlib.compressobj(9); data = b''.join(z.compress(row) for _ in range(h)) + z.flush()
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', data) + chunk(b'IEND', b''))
png(os.path.join(tmp, 'grande.png'), 9000, 9000)      # 81 Mpx: si apre
png(os.path.join(tmp, 'enorme.png'), 13000, 12000)    # 156 Mpx: oltre il tetto
EOF
for f in troncato.webp troncato.tiff vuoto.png spazzatura.jpg; do
  must fail "$(W "$TMP/$f")" "Errore"
done
# Esito accettabile in entrambi i modi, purché senza crash: JPEG e PNG troncati si
# mostrano fino a dove arrivano (stb per i JPEG; ImageIO su macOS anche per i PNG),
# come nei browser; un SVG rotto lo rende ImageMagick su Linux e dà errore altrove.
for f in troncato.jpg troncato.png rotto.svg; do
  OUT="$(run doc "$(W "$TMP/$f")")"; RC=$?; echo "$OUT"
  grep -qE '^(ok|FALLITO): ' <<<"$OUT" && [[ $RC -le 1 ]] || { echo "FALLITO: $f ha fatto cadere il processo (rc=$RC)"; FAIL=1; }
done
must fail "$(W "$TMP/enorme.png")" "troppo grande"
must doc "$(W "$TMP/grande.png")"

[[ $FAIL == 0 ]] && echo "image-check: tutto ok" || echo "image-check: FALLITO"
exit "$FAIL"

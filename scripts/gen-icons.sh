#!/usr/bin/env bash
# Rigenera le icone derivate da icons/zuer.svg (l'unica sorgente):
#   icons/png/zuer-<lato>.png   Linux (hicolor) e Android (mipmap)
#   icons/zuer.ico              Windows (installer NSIS e "Apri con")
#   icons/zuer.icns             macOS (Zuer.app)
# I derivati sono versionati: gli script di pacchetto li copiano e basta, così un
# pacchetto non dipende da ImageMagick né dai font della macchina che lo compila.
# Va rilanciato solo quando cambia l'SVG. Servono rsvg-convert, magick e python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/icons/zuer.svg"
OUT="$ROOT/icons"
for t in rsvg-convert magick python3; do
  command -v "$t" >/dev/null || { echo "✗ manca $t" >&2; exit 1; }
done

TMP="$ROOT/zig-out/tmp/gen-icons.$$"
mkdir -p "$TMP" "$OUT/png"
trap 'rm -rf "$TMP"' EXIT

# Ogni taglia è resa dall'SVG, non rimpicciolita da una più grande: a 16 px i bordi
# cadono sui pixel invece di sfumare.
for s in 16 24 32 48 64 72 96 128 144 192 256 512; do
  rsvg-convert -w "$s" -h "$s" "$SVG" -o "$OUT/png/zuer-$s.png"
done

# ICO: BMP fino a 128 (li scrive ImageMagick), PNG a 256 (lo aggiunge python: ImageMagick
# lo lascerebbe BMP, 270 KB per quella sola voce). È il formato che Windows e NSIS
# si aspettano: voci piccole non compresse, la 256 in PNG.
magick "$OUT"/png/zuer-{16,24,32,48,64,128}.png "$TMP/small.ico"
python3 - "$TMP/small.ico" "$OUT/png/zuer-256.png" "$OUT/zuer.ico" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    ico = f.read()
with open(sys.argv[2], "rb") as f:
    png = f.read()
assert png[:8] == b"\x89PNG\r\n\x1a\n", "zuer-256.png non è un PNG"
entries = []
for i in range(struct.unpack("<H", ico[4:6])[0]):
    e = ico[6 + 16 * i : 22 + 16 * i]
    size, off = struct.unpack("<II", e[8:16])
    entries.append((e[:8], ico[off : off + size]))
entries.append((struct.pack("<BBBBHH", 0, 0, 0, 0, 1, 32), png))  # lato 0 = 256
head, body = struct.pack("<HHH", 0, 1, len(entries)), b""
first = 6 + 16 * len(entries)
for meta, data in entries:
    head += meta + struct.pack("<II", len(data), first + len(body))
    body += data
with open(sys.argv[3], "wb") as f:
    f.write(head + body)
PY

# macOS vuole l'icona più piccola della tela (griglia Apple: il riquadro occupa ~80%
# del lato, il nostro SVG ~94%), altrimenti nel Dock risulta più grossa delle vicine.
for s in 16 32 64 128 256 512 1024; do
  inner=$(( (s * 86 + 50) / 100 ))
  rsvg-convert -w "$inner" -h "$inner" "$SVG" -o "$TMP/in.png"
  magick "$TMP/in.png" -background none -gravity center -extent "${s}x${s}" "$TMP/mac_$s.png"
done

# L'ICNS è assemblato a mano (intestazione 'icns' + blocchi PNG tipizzati): l'encoder
# di ImageMagick con certe build scrive un PNG con estensione .icns senza errore.
python3 - "$TMP" "$OUT/zuer.icns" <<'PY'
import struct, sys
tmp, out = sys.argv[1], sys.argv[2]
# 1x: icp4/icp5 = 16/32, ic07/ic08/ic09/ic10 = 128/256/512/1024.
# 2x: ic11/ic12/ic13/ic14 = 16@2x/32@2x/128@2x/256@2x.
TYPES = ((16, b"icp4"), (32, b"icp5"), (128, b"ic07"), (256, b"ic08"), (512, b"ic09"),
         (1024, b"ic10"), (32, b"ic11"), (64, b"ic12"), (256, b"ic13"), (512, b"ic14"))
chunks = []
for size, typ in TYPES:
    with open(f"{tmp}/mac_{size}.png", "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"mac_{size}.png non è un PNG"
    chunks.append(typ + struct.pack(">I", 8 + len(data)) + data)
body = b"".join(chunks)
with open(out, "wb") as f:
    f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
PY

echo "✓ icone rigenerate in $OUT"
ls -l "$OUT" "$OUT/png" | awk 'NF>=9 {printf "  %8d  %s\n", $5, $9}'

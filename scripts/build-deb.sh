#!/usr/bin/env bash
# Pacchetto .deb di Zuer per Ubuntu LTS (amd64), da una build fatta SULLA versione
# di Ubuntu di destinazione: i soname di FFmpeg e le versioni delle librerie sono
# quelli della distribuzione, e dpkg-shlibdeps ne ricava le dipendenze.
#
#   scripts/build-deb.sh [--out DIR]
#
# Senza compute_vp9 (-Dcvp9=false): non è nei repository di Ubuntu, il VP9 passa da
# libav come su macOS e Windows. Serve: zig, dpkg-dev, i -dev della build (vedi la
# workflow di release) e, per l'icona, ImageMagick.
#
# Layout: binari e plugin in /usr/lib/zuer (zuer-gui cerca i plugin in
# <eseguibile>/decoders, risolvendo i link), link in /usr/bin, voce di menu e icona in
# /usr/share. Nessuno script di installazione: menu e icone si aggiornano con i
# trigger di dpkg, e le associazioni dei file restano una scelta dell'utente.
set -euo pipefail

OUT="zig-out/deb"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    *) echo "argomento sconosciuto: $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."
VERSION="$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' build.zig.zon | head -1)"
[[ -n "$VERSION" ]] || { echo "versione non trovata in build.zig.zon" >&2; exit 1; }
ARCH="$(dpkg --print-architecture)"
# 0.1.0-rc1 → 0.1.0~rc1: per dpkg la prerelease viene prima della versione finale.
DEBVER="${VERSION//-/\~}"

WORK="$(mktemp -d "${TMPDIR:-zig-out}/zuer-deb.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PREFIX="$WORK/build"
ROOT="$WORK/root"

echo "→ build ReleaseSafe (senza compute_vp9)"
zig build -Doptimize=ReleaseSafe -Dcvp9=false --prefix "$PREFIX"

echo "→ albero del pacchetto"
LIB="$ROOT/usr/lib/zuer"
install -d "$LIB/decoders" "$ROOT/usr/bin" "$ROOT/usr/share/applications" "$ROOT/usr/share/doc/zuer"
install -m755 "$PREFIX/bin/zuer" "$PREFIX/bin/zuer-gui" "$LIB/"
install -m644 "$PREFIX"/lib/libdecoder_*.so "$LIB/decoders/"
ln -s ../lib/zuer/zuer "$ROOT/usr/bin/zuer"
ln -s ../lib/zuer/zuer-gui "$ROOT/usr/bin/zuer-gui"
for f in "$LIB/zuer" "$LIB/zuer-gui" "$LIB"/decoders/*.so; do
  if readelf -d "$f" | grep -q compute_vp9; then echo "✗ $f linka compute_vp9" >&2; exit 1; fi
done

ICON=utilities-terminal
IM="$(command -v magick || command -v convert || true)"
if [[ -n "$IM" ]]; then
  # Stessa "Z" su tondo blu del bundle macOS e dell'installer Windows.
  for s in 16 32 48 64 128 256 512; do
    d="$ROOT/usr/share/icons/hicolor/${s}x${s}/apps"
    install -d "$d"
    "$IM" -size ${s}x${s} xc:none \
      -fill '#2563eb' -draw "roundrectangle $((s/32)),$((s/32)) $((s-1-s/32)),$((s-1-s/32)) $((s*3/16)),$((s*3/16))" \
      -fill white -font "${ZUER_ICON_FONT:-DejaVu-Sans-Bold}" -pointsize $((s*3/4)) -gravity center -annotate +0-$((s/42)) 'Z' \
      "$d/zuer.png"
  done
  ICON=zuer
else
  echo "  · ImageMagick assente: icona generica"
fi

# Stesso nome del file di install.sh (zuer-gui.desktop): le associazioni già scelte
# dall'utente continuano a valere.
cat > "$ROOT/usr/share/applications/zuer-gui.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Zuer
GenericName=Visualizzatore universale
Comment=Immagini, modelli 3D, testo, archivi e media
Exec=zuer-gui %f
Icon=$ICON
Terminal=false
StartupWMClass=it.zuer.gui
Categories=Graphics;Viewer;
MimeType=image/png;image/jpeg;image/gif;image/bmp;image/webp;image/svg+xml;image/tiff;application/pdf;model/obj;model/gltf-binary;application/zip;application/x-tar;text/plain;text/csv;text/markdown;audio/mpeg;audio/flac;audio/ogg;audio/x-wav;video/mp4;video/x-matroska;video/webm;video/x-msvideo;video/quicktime;
EOF
command -v desktop-file-validate >/dev/null && desktop-file-validate "$ROOT/usr/share/applications/zuer-gui.desktop"

cat > "$ROOT/usr/share/doc/zuer/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Zuer
Source: https://github.com/postadelmaga/Zuer

Files: *
Copyright: Francesco Magazzu
License: AGPL-3.0-or-later
 Il testo completo è in /usr/share/doc/zuer/LICENSE. Il codice di terze parti
 compilato nei binari (libwebp, nanosvg, TinySoundFont, stb) ha le sue licenze in
 /usr/share/doc/zuer/THIRD-PARTY-NOTICES.txt.
EOF
install -m644 LICENSE THIRD-PARTY-NOTICES.txt "$ROOT/usr/share/doc/zuer/"

echo "→ dipendenze (dpkg-shlibdeps)"
# dpkg-shlibdeps vuole un debian/control: ne basta uno minimo nella cartella di lavoro.
install -d "$WORK/debian"
printf 'Source: zuer\n\nPackage: zuer\nArchitecture: any\n' > "$WORK/debian/control"
DEPENDS="$(cd "$WORK" && dpkg-shlibdeps -O root/usr/lib/zuer/zuer root/usr/lib/zuer/zuer-gui root/usr/lib/zuer/decoders/*.so 2>/dev/null \
  | sed -n 's/^shlibs:Depends=//p')"
[[ -n "$DEPENDS" ]] || { echo "dpkg-shlibdeps non ha prodotto dipendenze" >&2; exit 1; }

install -d "$ROOT/DEBIAN"
SIZE="$(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)"
# Aperte a runtime (dlopen o processi), quindi invisibili a dpkg-shlibdeps:
# libmpv (video in hardware), Vulkan (renderer 3D/testo), VA-API su Wayland
# (capacità hardware), poppler (PDF), wl-clipboard, xdg-utils, 7z e bsdtar (archivi).
cat > "$ROOT/DEBIAN/control" <<EOF
Package: zuer
Version: $DEBVER
Architecture: $ARCH
Maintainer: Francesco Magazzu <postadelmaga@users.noreply.github.com>
Installed-Size: $SIZE
Depends: $DEPENDS
Recommends: libmpv2, libvulkan1, mesa-vulkan-drivers, libva-wayland2, poppler-utils, wl-clipboard, xdg-utils
Suggests: 7zip, libarchive-tools
Section: graphics
Priority: optional
Homepage: https://github.com/postadelmaga/Zuer
Description: visualizzatore universale di file (Wayland)
 Immagini, PDF, modelli 3D, testo, CSV, Markdown, archivi, audio e video in
 un'unica finestra, con anteprima rapida e navigazione tra i file della cartella.
 Richiede una sessione Wayland.
EOF

mkdir -p "$OUT"
DEB="$OUT/zuer_${DEBVER}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$ROOT" "$DEB" >/dev/null
echo "✓ $DEB"
dpkg-deb --info "$DEB" | sed -n '/Depends\|Recommends\|Version/p'

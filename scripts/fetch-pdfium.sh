#!/usr/bin/env bash
# Scarica PDFium (motore PDF di Windows, vedi src/decoders/pdf_pdfium.zig) e mette
# pdfium.dll accanto all'eseguibile, con le licenze. Come le DLL FFmpeg NON è nel
# repository: viaggia con l'app, scaricata qui con hash verificato.
#
# Uso: scripts/fetch-pdfium.sh [dest-dir]   (default: zig-out/bin)
set -euo pipefail
DEST="${1:-zig-out/bin}"

# ── Build pinnata di bblanchon/pdfium-binaries ───────────────────────────────
# PDFium di Chromium compilato senza V8 né XFA (args.gn nel pacchetto), una sola
# DLL senza dipendenze oltre al sistema. Licenze: PDFium BSD-3-Clause/Apache-2.0,
# componenti di terze parti (FreeType, libjpeg-turbo, OpenJPEG, lcms2, zlib, ICU,
# HarfBuzz, abseil…) con licenze permissive, raccolte in PDFium-LICENSE.txt.
# Tutte compatibili con l'AGPL-3.0-or-later di Zuer.
# Per aggiornare: `gh release list -R bblanchon/pdfium-binaries`, scegliere un tag
# con almeno due settimane, aggiornare TAG e hash (il digest è nella pagina della
# release) e ripetere le prove PDF della CI Windows.
TAG="chromium/8111" # PDFium 158.0.8111.0
ASSET="pdfium-win-x64.tgz"
URL="https://github.com/bblanchon/pdfium-binaries/releases/download/$TAG/$ASSET"
EXPECTED_SHA256="3452d11031050ec65e57f180215b57b9e6d465e3fbedafa8a77ad90885c7d23e"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "→ scarico PDFium ($TAG, ~4 MB)…"
curl -fsSL -o "$TMP/pdfium.tgz" "$URL"
echo "$EXPECTED_SHA256  $TMP/pdfium.tgz" | sha256sum -c - >/dev/null \
  || { echo "✗ sha256 non corrisponde: asset compromesso o cambiato ($URL)"; exit 1; }
mkdir -p "$TMP/x"
tar -xzf "$TMP/pdfium.tgz" -C "$TMP/x"
[[ -f "$TMP/x/bin/pdfium.dll" ]] || { echo "✗ bin/pdfium.dll assente nel pacchetto"; exit 1; }
grep -q 'pdf_enable_v8 = false' "$TMP/x/args.gn" || { echo "✗ build con V8 (JavaScript): non è quella prevista"; exit 1; }
mkdir -p "$DEST"
cp -v "$TMP/x/bin/pdfium.dll" "$DEST"/
{
  echo "pdfium.dll: PDFium $(tr '\n' ' ' < "$TMP/x/VERSION")"
  echo "Build:   $URL"
  echo "SHA-256: $EXPECTED_SHA256"
  echo
  # licenses/pdfium.txt per primo, poi le terze parti e lo script di build (MIT).
  for f in "$TMP/x/licenses/pdfium.txt" $(ls "$TMP/x"/licenses/* | grep -v '/pdfium.txt$') "$TMP/x/LICENSE"; do
    echo "================================================================================"
    echo "$(basename "$f")"
    echo "================================================================================"
    cat "$f"
    echo
  done
} > "$DEST/PDFium-LICENSE.txt"
echo "✓ pdfium.dll e PDFium-LICENSE.txt in $DEST"

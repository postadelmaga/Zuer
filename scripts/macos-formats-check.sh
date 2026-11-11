#!/usr/bin/env bash
# Formati che su macOS passano dai componenti di SISTEMA (nessun codec nel bundle):
#   immagini  → ImageIO (HEIC, JPEG 2000, OpenEXR, JPEG XL, DDS), orientamento EXIF
#   archivi   → /usr/bin/tar = bsdtar (7z, ISO, XAR, CPIO, tar.xz) + zstd in processo
#   documenti → /usr/bin/textutil (DOC, RTF)
# I file si generano al momento con gli strumenti del sistema (sips, textutil, tar) e
# ImageMagick di Homebrew; ognuno passa da feature-probe, cioè dagli stessi plugin di
# zuer-gui. Un formato che il runner non sa GENERARE è un avviso, non un errore; uno
# generato ma non aperto è un errore (tranne quelli marcati "facoltativo": il loro
# codec dipende dalla versione di macOS).
#
#   scripts/macos-formats-check.sh <feature-probe> <cartella-di-lavoro>
set -uo pipefail
PROBE="$1"
D="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
I="$ROOT/tests/images"
mkdir -p "$D"
FAIL=0; N=0

ok_or() { # livello(errore|avviso) descrizione comando...
  local lvl="$1" what="$2"; shift 2
  N=$((N+1))
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [[ $rc == 0 ]] && ! grep -q FALLITO <<<"$out"; then
    echo "ok: $what — $(head -1 <<<"$out")"
  elif [[ $lvl == avviso ]]; then
    echo "::warning::$what non aperto (facoltativo): $(head -1 <<<"$out")"
  else
    echo "FALLITO: $what"; sed 's/^/    /' <<<"$out" | head -6; FAIL=1
  fi
}
gen() { "$@" >/dev/null 2>&1 || { echo "::warning::non generato: ${*: -1}"; return 1; }; }

echo "── immagini (ImageIO)"
gen sips -s format heic "$I/rose.png" --out "$D/rose.heic" && ok_or errore HEIC "$PROBE" doc "$D/rose.heic"
gen sips -s format jp2 "$I/rose.png" --out "$D/rose.jp2" && ok_or errore "JPEG 2000" "$PROBE" doc "$D/rose.jp2"
gen magick "$I/rose.png" "$D/rose.exr" && ok_or avviso OpenEXR "$PROBE" doc "$D/rose.exr"
gen magick "$I/rose.png" "$D/rose.jxl" && ok_or avviso "JPEG XL" "$PROBE" doc "$D/rose.jxl"
gen magick "$I/rose.png" "$D/rose.dds" && ok_or avviso DDS "$PROBE" doc "$D/rose.dds"
# Orientamento EXIF 6 (ruota di 90°): 70x46 deve uscire 46x70, come per i JPEG.
if gen magick "$I/rose.png" -orient RightTop "$D/rose-o6.tiff"; then
  N=$((N+1))
  out="$("$PROBE" doc "$D/rose-o6.tiff" 2>&1)"
  if grep -q 'immagine 46x70' <<<"$out"; then echo "ok: TIFF orientamento 6 → 46x70"
  else echo "FALLITO: TIFF orientamento 6 non applicato: $out"; FAIL=1; fi
fi

echo "── archivi (bsdtar di sistema)"
S="$D/src"; rm -rf "$S"; mkdir -p "$S/sotto"
echo ciao > "$S/a b.txt"; head -c 5000 /dev/urandom > "$S/sotto/dati.bin"
arch() { # livello nome comando... (crea $D/nome)
  local lvl="$1" name="$2"; shift 2
  gen "$@" || return 0
  ok_or "$lvl" "$name" "$PROBE" contains "$D/$name" "a b.txt"
}
arch errore t.7z      tar --format 7zip -cf "$D/t.7z" -C "$S" .
arch errore t.iso     tar --format iso9660 -cf "$D/t.iso" -C "$S" .
arch avviso t.xar     tar --format xar -cf "$D/t.xar" -C "$S" .
arch errore t.cpio    tar --format cpio -cf "$D/t.cpio" -C "$S" .
arch errore t.tar.xz  tar -cJf "$D/t.tar.xz" -C "$S" .
arch errore t.tar.bz2 tar -cjf "$D/t.tar.bz2" -C "$S" .
if command -v zstd >/dev/null; then
  tar -cf "$D/t.tar" -C "$S" . && zstd -q -f "$D/t.tar" -o "$D/t.tar.zst" &&
    ok_or errore t.tar.zst "$PROBE" contains "$D/t.tar.zst" "a b.txt"
fi
# Un archivio rotto dà un errore, non un crash né una tabella vuota.
echo "non sono un archivio" > "$D/rotto.7z"
ok_or errore "7z rotto → errore" "$PROBE" fail "$D/rotto.7z" "archivio"

echo "── documenti (textutil)"
printf 'Documento di prova Zuer\nSeconda riga\n' > "$D/prova-tu.txt"
gen textutil -convert doc "$D/prova-tu.txt" -output "$D/prova.doc" && ok_or errore DOC "$PROBE" contains "$D/prova.doc" "Documento di prova"
gen textutil -convert rtf "$D/prova-tu.txt" -output "$D/prova.rtf" && ok_or errore RTF "$PROBE" contains "$D/prova.rtf" "Seconda riga"

echo "macos-formats-check: $N prove"
[[ $FAIL == 0 ]] && echo "macos-formats-check: tutto ok" || echo "macos-formats-check: FALLITO"
exit "$FAIL"

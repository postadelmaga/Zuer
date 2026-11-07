#!/usr/bin/env bash
# Prove del plugin PDF, identiche sulle tre piattaforme (poppler su Linux,
# CoreGraphics su macOS, PDFium su Windows): stessi file, stessi esiti attesi.
# I documenti vengono da scripts/make-test-docs.py.
#
#   scripts/pdf-check.sh <feature-probe> <cartella-documenti>
set -uo pipefail
PROBE="$1"
D="$2"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) W() { cygpath -w "$1"; } ;;
  *) W() { printf '%s' "$1"; } ;;
esac
FAIL=0
run() { "$PROBE" "$@" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }
must() { run "$@" || FAIL=1; }
expect() { # $1 regex atteso nell'output; il resto è il comando
  local re=$1; shift
  local out; out="$(run "$@")"; echo "$out"
  grep -qE "$re" <<<"$out" || { echo "FALLITO: atteso /$re/"; FAIL=1; }
}

echo "── apertura, pagine, orientamento"
expect 'immagine 1275x1650, pagine 3' doc "$(W "$D/prova.pdf")"
expect 'immagine 1650x1275, pagine 3' page "$(W "$D/prova.pdf")" 2   # /Rotate 90
expect 'pagina 3 di 3' page "$(W "$D/prova.pdf")" 3
expect 'pagina 3 di 3' page "$(W "$D/prova.pdf")" 99                # oltre la fine: clamp
expect 'pagina 1 di 3' doc "$(W "$D/perché è così.pdf")"            # percorso non ASCII
expect 'immagine 1275x1650, pagine 1' doc "$(W "$D/immagine.pdf")"

echo "── contenuto"
must pixel "$(W "$D/prova.pdf")" 0.36 0.62 0 0 255         # rettangolo blu (ordine dei canali)
must pixel "$(W "$D/prova.pdf")" 0.9 0.05 255 255 255      # fondo bianco
must pixel "$(W "$D/immagine.pdf")" 0.3 0.4 200 50 50      # dentro la foto JPEG (rosa rossa)

echo "── errori"
must fail "$(W "$D/rotto.pdf")" "danneggiato"
must fail "$(W "$D/finto.pdf")" "danneggiato"
must fail "$(W "$D/enorme.pdf")" "pagina troppo grande"

echo "── tempi (3 pagine; su Linux dalla cache su disco se già rese)"
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; } # date +%N non esiste su macOS
T0=$(ms)
for p in 1 2 3; do run page "$(W "$D/immagine.pdf")" "$p" >/dev/null; done
echo "3 aperture di immagine.pdf: $(( $(ms) - T0 )) ms (processo intero, caricamento plugin compreso)"

[[ $FAIL == 0 ]] && echo "pdf-check: tutto ok" || echo "pdf-check: FALLITO"
exit "$FAIL"

#!/usr/bin/env bash
# File ostili: piccoli su disco, costruiti per far cadere il processo, tenerlo
# occupato per minuti o fargli chiedere decine di GB. Ogni caso deve dare l'esito
# atteso entro 60 s e dentro 4 GB di memoria virtuale, senza crash. I file li
# scrive scripts/hostile-gen.py (servono python3 e, per nulla di più, zuer).
#
#   scripts/hostile-check.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
Z=$ROOT/zig-out/bin/zuer
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cd "$W"
python3 "$ROOT/scripts/hostile-gen.py" || { echo "FALLITO: generazione dei file"; exit 1; }
fail=0
# caso <file> <tipo atteso> [stringa che NON deve comparire nei primi 4 KB]
caso() {
    local f=$1 want=$2 never=${3:-} t0 rc ms kind
    t0=$(date +%s%N)
    # Si tengono i primi 4 KB e il resto si butta, ma leggendolo tutto: l'output
    # di un foglio troncato dal budget sono centinaia di MB.
    (ulimit -v 4000000; cd / && timeout 60 "$Z" --json "$W/$f" 2> "$W/err" | { head -c 4096 > "$W/out"; cat > /dev/null; }; exit "${PIPESTATUS[0]}"); rc=$?
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    kind=$(grep -aoE '"type":"[a-z]+"' "$W/out" | head -1 | cut -d'"' -f4)
    if [ $rc = 0 ] && [ "$kind" = "$want" ] && { [ -z "$never" ] || ! grep -aqE "$never" "$W/out"; }; then
        echo "ok: $f → $kind in $ms ms"
    else
        echo "FALLITO: $f → ${kind:-nessun esito} (atteso $want) in $ms ms, rc=$rc"; fail=1
    fi
}
# #27 — contenuto diverso dall'estensione: mai a ImageMagick, quindi errore.
for f in finto.png finto.jpg finto.tif finto.tga finto.dng finto.heic finto.pct; do caso $f error; done
# #28 — glTF: stride, cicli e ventagli di nodi, troppi vertici, troppe facce,
# texture grandi e texture ripetute (il budget ne tiene una parte).
caso ok.glb mesh; caso istanze.glb mesh; caso ciclo.glb mesh; caso ventaglio.glb mesh
caso stride0.glb error; caso stride1.glb error; caso troppi.glb error
caso facce_ok.glb mesh; caso facce.glb error
caso texture.glb mesh; caso texture_grande.glb mesh; caso texture_tante.glb mesh
# #34 — coordinate non finite: diventano 0, niente NaN nel modello.
caso nan.obj mesh '[[,:]-?(nan|inf)[],]'; caso nan.stl mesh '[[,:]-?(nan|inf)[],]'; caso huge.obj mesh
# #30 — documenti che si gonfiano: troncati dal budget, non rifiutati.
caso sano.xlsx csv; caso sano.ods csv; caso sano.pptx text
caso condivisa.xlsx csv; caso riempimento.xlsx csv; caso ripetute.ods csv; caso alias.pptx text
# #32 — UTF-8 non valido in un documento: il testo esce sanificato (una stringa
# JSON, non l'elenco dei byte che --json stampa per il testo non valido).
caso rotto.docx text '"content":\['; caso sano.docx text '"content":\['
exit $fail

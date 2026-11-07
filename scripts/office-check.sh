#!/usr/bin/env bash
# Prove del plugin Office con documenti VERI (tests/office: file di Microsoft Office
# e LibreOffice dai test di Apache POI e LibreOffice, più i casi corrotti trovati dai
# loro fuzzer — vedi tests/office/SOURCES.md) e con i documenti generati da
# scripts/make-test-docs.py. Il plugin è Zig puro: stessi esiti attesi ovunque.
#
#   scripts/office-check.sh <feature-probe> [cartella-office]
set -uo pipefail
PROBE="$1"
O="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../tests/office" && pwd)}"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) W() { cygpath -w "$1"; } ;;
  *) W() { printf '%s' "$1"; } ;;
esac
FAIL=0
run() { "$PROBE" "$@" 2>&1 | tr -d '\r'; return "${PIPESTATUS[0]}"; }
must() { run "$@" || FAIL=1; }

echo "── documenti di Office e LibreOffice"
for f in footnotes.docx table_footnotes.docx TestDocument.docx protected_sample.docx \
         ExternalEntityInText.docx bug65649.docx \
         "54084 - Greek - beyond BMP.xlsx" Booleans.xlsx formula-eval.xlsx InlineString.xlsx unicodeSheetName.xlsx \
         table_test.pptx text-highlight.pptx \
         MadeByLO7.odt tdf145871.odt Magick++_tutorial.odt formula-across-sheets.ods named-ranges-hidden.ods; do
  must doc "$(W "$O/$f")"
done

echo "── contenuto"
must contains "$(W "$O/InlineString.xlsx")" "more text"            # run multipli, prefisso x:
must contains "$(W "$O/InlineString.xlsx")" $'\xf0\x9f\x98\x9c'    # 😜 scritto come &#x1f61c;
must contains "$(W "$O/formula-eval.xlsx")" "6.75"                 # valore calcolato della formula
must contains "$(W "$O/54084 - Greek - beyond BMP.xlsx")" $'\xf0\x9d\x9d\x8a'  # 𝝊, greco matematico fuori dal BMP
must contains "$(W "$O/Magick++_tutorial.odt")" "Magick++"
must contains "$(W "$O/text-highlight.pptx")" "Highlight with preset color"

echo "── documenti corrotti o non supportati: errore chiaro, nessun crash"
must fail "$(W "$O/clusterfuzz-testcase-minimized-POIFuzzer-6709287337197568.docx")" "Archivio ZIP non valido"
must fail "$(W "$O/clusterfuzz-testcase-minimized-POIXSLFFuzzer-4838644450394112.pptx")" "Archivio ZIP non valido"
must fail "$(W "$O/deep-data.xlsx")" "Archivio ZIP non valido"     # manca la directory centrale
must fail "$(W "$O/crash-9bf3cd4bd6f50a8a9339d363c2c7af14b536865c.xlsx")" "protetto da password o in formato binario"
must fail "$(W "$O/Headers.docx")" "non contiene testo"            # testo solo nelle intestazioni

[[ $FAIL == 0 ]] && echo "office-check: tutto ok" || echo "office-check: FALLITO"
exit "$FAIL"

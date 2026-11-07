# Documenti Office di prova

Documenti veri, prodotti da Microsoft Office, LibreOffice e altri programmi, usati da
`scripts/office-check.sh` su Linux, Windows e macOS. Non modificati.

| File | Origine | Licenza |
|---|---|---|
| `footnotes.docx`, `table_footnotes.docx`, `Headers.docx`, `TestDocument.docx`, `protected_sample.docx`, `ExternalEntityInText.docx`, `bug65649.docx`, `clusterfuzz-testcase-minimized-POIFuzzer-6709287337197568.docx` | Apache POI, `test-data/document/` | Apache-2.0 |
| `54084 - Greek - beyond BMP.xlsx`, `Booleans.xlsx`, `formula-eval.xlsx`, `InlineString.xlsx`, `unicodeSheetName.xlsx`, `deep-data.xlsx`, `crash-9bf3cd4bd6f50a8a9339d363c2c7af14b536865c.xlsx` | Apache POI, `test-data/spreadsheet/` | Apache-2.0 |
| `table_test.pptx`, `text-highlight.pptx`, `clusterfuzz-testcase-minimized-POIXSLFFuzzer-4838644450394112.pptx` | Apache POI, `test-data/slideshow/` | Apache-2.0 |
| `MadeByLO7.odt`, `tdf145871.odt` | LibreOffice core, `sw/qa/extras/odfexport/data/` | MPL-2.0 |
| `formula-across-sheets.ods`, `named-ranges-hidden.ods` | LibreOffice core, `sc/qa/unit/data/ods/` | MPL-2.0 |
| `Magick++_tutorial.odt` | ImageMagick, documentazione di Magick++ | ImageMagick License |

Scaricati il 2026-11-07 da `https://github.com/apache/poi/tree/trunk/test-data` e
`https://github.com/LibreOffice/core`.

Casi particolari, con l'esito atteso in `scripts/office-check.sh`:

- `clusterfuzz-*`: archivi corrotti trovati dai fuzzer di POI → errore "Archivio ZIP non valido".
- `deep-data.xlsx`: ZIP senza directory centrale (anche Python lo rifiuta) → stesso errore.
- `crash-9bf3….xlsx`: contenitore OLE cifrato, non ZIP → "protetto da password o in formato binario".
- `InlineString.xlsx`: SpreadsheetML col prefisso `x:` e stringhe inline a più run, con un
  carattere fuori dal BMP.
- `ExternalEntityInText.docx`: entità esterna XML (XXE) nel testo; Zuer non risolve DTD.
- `Headers.docx`: testo solo nelle intestazioni di pagina, che Zuer non estrae → "non contiene testo".

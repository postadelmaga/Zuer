#!/usr/bin/env python3
"""Documenti di prova minimi ma validi, senza dipendenze (solo la stdlib): un PDF di
3 pagine (una ruotata di 90°), DOCX, XLSX (2 fogli), PPTX, ODT, ODS, un cubo OBJ.
Servono a feature-probe in CI (scripts/feature-check.sh), su ogni piattaforma.

    scripts/make-test-docs.py <cartella>
"""
import os, sys, zipfile

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def pdf(path):
    objs = []
    pages = []
    for i, (text, rot) in enumerate([("Pagina uno", 0), ("Pagina due", 90), ("Pagina tre", 0)]):
        stream = f"BT /F1 48 Tf 72 640 Td ({text}) Tj ET 0 0 1 rg 72 200 300 200 re f".encode()
        objs.append(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        content = len(objs)
        objs.append(b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate %d "
                    b"/Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> "
                    b"/Contents %d 0 R >>" % (rot, content + 2))
        pages.append(len(objs) + 2)
    body = [b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [%s] /Count %d >>" % (b" ".join(b"%d 0 R" % p for p in pages), len(pages))] + objs
    data = bytearray(b"%PDF-1.4\n")
    offs = []
    for n, o in enumerate(body, 1):
        offs.append(len(data))
        data += b"%d 0 obj\n" % n + o + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 %d\n0000000000 65535 f \n" % (len(body) + 1)
    for off in offs:
        data += b"%010d 00000 n \n" % off
    data += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(body) + 1, xref)
    open(path, "wb").write(data)

def zipdoc(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, content in files.items():
            z.writestr(name, content)

CT = '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">%s</Types>'
REL = '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">%s</Relationships>'

pdf(os.path.join(out, "prova.pdf"))

def pdf_raw(path, page_objs, media=(612, 792), extra=()):
    """PDF di una pagina: `page_objs` sono gli oggetti dopo Catalog e Pages, il
    primo è la pagina (riferita come 3 0 R)."""
    body = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"] + list(page_objs)
    data = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offs = []
    for n_, o in enumerate(body, 1):
        offs.append(len(data))
        data += b"%d 0 obj\n" % n_ + o + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 %d\n0000000000 65535 f \n" % (len(body) + 1)
    for off in offs:
        data += b"%010d 00000 n \n" % off
    data += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(body) + 1, xref)
    open(path, "wb").write(data)

# Pagina con testo E un'immagine JPEG vera (DCTDecode): la foto di esempio di
# ImageMagick in tests/images, scalata a 300x200 punti in (72, 400).
here = os.path.dirname(os.path.abspath(__file__))
jpg = open(os.path.join(here, "..", "tests", "images", "rose.jpg"), "rb").read()
cs = b"q 300 0 0 200 72 400 cm /Im1 Do Q BT /F1 24 Tf 72 300 Td (Testo e immagine) Tj ET"
pdf_raw(os.path.join(out, "immagine.pdf"), [
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im1 5 0 R >> "
    b"/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents 4 0 R >>",
    b"<< /Length %d >>\nstream\n" % len(cs) + cs + b"\nendstream",
    b"<< /Type /XObject /Subtype /Image /Width 70 /Height 46 /ColorSpace /DeviceRGB /BitsPerComponent 8 "
    b"/Filter /DCTDecode /Length %d >>\nstream\n" % len(jpg) + jpg + b"\nendstream",
])
# Pagina enorme (200 × 200 pollici): a 150 DPI sarebbero 30000 px per lato.
cs = b"0 0 1 rg 0 0 14400 14400 re f"
pdf_raw(os.path.join(out, "enorme.pdf"), [
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 14400 14400] /Contents 4 0 R >>",
    b"<< /Length %d >>\nstream\n" % len(cs) + cs + b"\nendstream",
])
# Danneggiato: i primi 200 byte di un PDF valido.
open(os.path.join(out, "rotto.pdf"), "wb").write(open(os.path.join(out, "prova.pdf"), "rb").read()[:200])
# Non è un PDF affatto, ma ha l'estensione.
open(os.path.join(out, "finto.pdf"), "wb").write(b"questo non e' un pdf\n" * 10)
# Nome non ASCII: il percorso deve arrivare intatto al motore (UTF-8/UTF-16).
open(os.path.join(out, "perché è così.pdf"), "wb").write(open(os.path.join(out, "prova.pdf"), "rb").read())
zipdoc(os.path.join(out, "prova.docx"), {
    "[Content_Types].xml": CT % '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>',
    "_rels/.rels": REL % '<Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>',
    "word/document.xml": '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Documento di prova Zuer</w:t></w:r></w:p><w:p><w:r><w:t>Seconda riga</w:t></w:r></w:p></w:body></w:document>',
})
sheet = lambda v: '<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>nome</t></is></c><c r="B1" t="inlineStr"><is><t>valore</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>a</t></is></c><c r="B2"><v>%d</v></c></row></sheetData></worksheet>' % v
zipdoc(os.path.join(out, "prova.xlsx"), {
    "[Content_Types].xml": CT % '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
    "_rels/.rels": REL % '<Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>',
    "xl/workbook.xml": '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Uno" sheetId="1" r:id="rId1"/><sheet name="Due" sheetId="2" r:id="rId2"/></sheets></workbook>',
    "xl/_rels/workbook.xml.rels": REL % '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>',
    "xl/worksheets/sheet1.xml": sheet(1),
    "xl/worksheets/sheet2.xml": sheet(2),
})
zipdoc(os.path.join(out, "prova.pptx"), {
    "[Content_Types].xml": CT % '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>',
    "_rels/.rels": REL % '<Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>',
    "ppt/presentation.xml": '<?xml version="1.0" encoding="UTF-8"?><p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst></p:presentation>',
    "ppt/_rels/presentation.xml.rels": REL % '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>',
    "ppt/slides/slide1.xml": '<?xml version="1.0" encoding="UTF-8"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Diapositiva di prova</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
})
ODF = "urn:oasis:names:tc:opendocument:xmlns:"
zipdoc(os.path.join(out, "prova.odt"), {
    "mimetype": "application/vnd.oasis.opendocument.text",
    "content.xml": f'<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="{ODF}office:1.0" xmlns:text="{ODF}text:1.0"><office:body><office:text><text:p>Testo ODT di prova</text:p></office:text></office:body></office:document-content>',
})
zipdoc(os.path.join(out, "prova.ods"), {
    "mimetype": "application/vnd.oasis.opendocument.spreadsheet",
    "content.xml": f'<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="{ODF}office:1.0" xmlns:table="{ODF}table:1.0" xmlns:text="{ODF}text:1.0"><office:body><office:spreadsheet><table:table table:name="Foglio"><table:table-row><table:table-cell><text:p>nome</text:p></table:table-cell><table:table-cell><text:p>valore</text:p></table:table-cell></table:table-row><table:table-row><table:table-cell><text:p>a</text:p></table:table-cell><table:table-cell><text:p>1</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>',
})
v = [(x, y, z) for x in (0, 1) for y in (0, 1) for z in (0, 1)]
f = [(1, 2, 4, 3), (5, 7, 8, 6), (1, 5, 6, 2), (3, 4, 8, 7), (1, 3, 7, 5), (2, 6, 8, 4)]
with open(os.path.join(out, "cubo.obj"), "w") as o:
    for p in v: o.write("v %d %d %d\n" % p)
    for q in f: o.write("f %d %d %d\nf %d %d %d\n" % (q[0], q[1], q[2], q[0], q[2], q[3]))
open(os.path.join(out, "prova.txt"), "w").write("testo di prova\n")
print("documenti di prova in", out)

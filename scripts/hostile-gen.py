#!/usr/bin/env python3
"""File ostili per scripts/hostile-check.sh: uno o più per issue della milestone
«File ostili e robustezza dei decoder» (#27, #28, #30, #32, #34). Li scrive nella
cartella corrente. Sono piccoli su disco e grandi in memoria: è il loro mestiere.
I casi del parser Markdown (#33) stanno nei test di src/md_parse.zig."""
import io, json, struct, zipfile, zlib

# ---- #27: contenuti travestiti
ps = b"%!PS-Adobe-3.0\n%%BoundingBox: 0 0 100 100\n/Helvetica findfont 20 scalefont setfont 10 40 moveto (PS!) show showpage\n"
open('finto.png','wb').write(ps)
open('finto.jpg','wb').write(ps)
svg = b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="red"/></svg>'
open('finto.tif','wb').write(svg)
open('finto.tga','wb').write(svg)
mvg = b"push graphic-context\nviewbox 0 0 64 64\nfill 'blue'\nrectangle 0,0 64,64\npop graphic-context\n"
open('finto.dng','wb').write(mvg)
open('finto.heic','wb').write(mvg)
open('finto.pct','wb').write(svg)
# ---- #34: mesh con NaN / enormi
open('nan.obj','w').write("v nan 0 0\nv 1 inf 0\nv 0 1 -inf\nv 1 1 1\nf 1 2 3\nf 2 3 4\n")
open('huge.obj','w').write("v 1e38 0 0\nv -1e38 3e38 0\nv 0 1e38 -3e38\nv 1 1 1\nf 1 2 3\nf 2 3 4\n")
nanf = struct.pack('<f', float('nan')); inff = struct.pack('<f', float('inf'))
tri = struct.pack('<3f',0,0,1) + nanf + struct.pack('<2f',0,0) + struct.pack('<3f',1,0,0) + struct.pack('<f',0)+inff+struct.pack('<f',0) + b'\0\0'
tri2 = struct.pack('<12f',0,0,1, 0,0,0, 1,0,0, 0,1,0) + b'\0\0'
open('nan.stl','wb').write(b'\0'*80 + struct.pack('<I',2) + tri + tri2)
# ---- #28: glb
def glb(doc, binbuf, name):
    j = json.dumps(doc).encode(); j += b' '*((4-len(j)%4)%4)
    binbuf += b'\0'*((4-len(binbuf)%4)%4)
    total = 12 + 8 + len(j) + 8 + len(binbuf)
    open(name,'wb').write(b'glTF'+struct.pack('<II',2,total)+struct.pack('<I',len(j))+b'JSON'+j+struct.pack('<I',len(binbuf))+b'BIN\0'+binbuf)
pos = struct.pack('<9f', 0,0,0, 1,0,0, 0,1,0)
base = lambda: {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
  "buffers":[{"byteLength":36}],
  "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
  "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}]}
d = base(); glb(d, pos, 'ok.glb')
# stride 0 / count enorme
d = base(); d["bufferViews"][0]["byteStride"] = 0; d["accessors"][0]["count"] = 1500000000; glb(d, pos, 'stride0.glb')
d = base(); d["bufferViews"][0]["byteStride"] = 1; d["accessors"][0]["count"] = 20; glb(d, pos, 'stride1.glb')
# ventaglio: ogni nodo ha due volte lo stesso figlio (2^40 visite)
d = base(); N=40
d["nodes"] = [{"children":[i+1,i+1]} for i in range(N)] + [{"mesh":0}]
glb(d, pos, 'ventaglio.glb')
# ciclo
d = base(); d["nodes"] = [{"children":[1,1,1,1]},{"children":[0,0,0,0],"mesh":0}]; glb(d, pos, 'ciclo.glb')
# tante istanze lecite della stessa mesh (nodi distinti): deve restare apribile
d = base(); d["nodes"] = [{"children":list(range(1,1001))}] + [{"mesh":0,"translation":[i,0,0]} for i in range(1000)]; glb(d, pos, 'istanze.glb')
# troppi vertici: un accessor da 6M vertici (72 MB di zeri) istanziato da 4 nodi = 24M > 16M
big = b'\0'*(6_000_000*12)
d = base(); d["buffers"][0]["byteLength"]=len(big); d["bufferViews"][0]["byteLength"]=len(big); d["accessors"][0]["count"]=6_000_000
d["nodes"] = [{"children":[1,2,3,4]}] + [{"mesh":0} for _ in range(4)]
glb(d, big, 'troppi.glb')
# facce: 3 vertici, un milione di triangoli (indici a un byte), istanziati da N nodi
def facce(name, n_nodes):
    idx = b'\x00\x01\x02' * 1_000_000
    d = base()
    d["buffers"][0]["byteLength"] = 36 + len(idx)
    d["bufferViews"].append({"buffer":0,"byteOffset":36,"byteLength":len(idx)})
    d["accessors"].append({"bufferView":1,"componentType":5121,"count":len(idx),"type":"SCALAR"})
    d["meshes"][0]["primitives"][0]["indices"] = 1
    d["nodes"] = [{"children":list(range(1, n_nodes+1))}] + [{"mesh":0} for _ in range(n_nodes)]
    glb(d, pos + idx, name)
facce('facce_ok.glb', 4)
facce('facce.glb', 40)
# texture: un PNG incorporato, referenziato da K voci di `images` (e K materiali)
def png(w, h):
    raw = (b'\x00' + b'\x40\x80\xc0' * w) * h
    def chunk(t, data): return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
def con_texture(name, w, h, k):
    img = png(w, h)
    uv = struct.pack('<6f', 0,0, 1,0, 0,1)
    binbuf = pos + uv + img
    d = base()
    d["buffers"][0]["byteLength"] = len(binbuf)
    d["bufferViews"] += [{"buffer":0,"byteOffset":36,"byteLength":24}, {"buffer":0,"byteOffset":60,"byteLength":len(img)}]
    d["accessors"].append({"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"})
    d["images"] = [{"bufferView":2,"mimeType":"image/png"} for _ in range(k)]
    d["textures"] = [{"source":i} for i in range(k)]
    d["materials"] = [{"pbrMetallicRoughness":{"baseColorTexture":{"index":i}}} for i in range(k)]
    d["meshes"][0]["primitives"] = [{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":i} for i in range(k)]
    glb(d, binbuf, name)
con_texture('texture.glb', 64, 64, 1)
con_texture('texture_grande.glb', 5000, 4000, 2)   # oltre 4096²: decodificate una alla volta
con_texture('texture_tante.glb', 2048, 2048, 200)  # 200 × 16 MB: il budget ne tiene 64

# ---- #32: docx con UTF-8 non valido
def docx(name, body):
    z = zipfile.ZipFile(name,'w',zipfile.ZIP_DEFLATED)
    z.writestr('[Content_Types].xml','<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>')
    z.writestr('word/document.xml', b'<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>'+body+b'</w:t></w:r></w:p></w:body></w:document>')
    z.close()
docx('rotto.docx', b'prima \xff\xfe dopo \xe2\x82 coda \xf0\x9f')
docx('sano.docx', 'testo sano con accenti: è €'.encode())

CT='<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>'
WB='<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="F1" sheetId="1" r:id="rId1"/></sheets></workbook>'
RELS='<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'
def xlsx(name, sheet, sst=None):
    z = zipfile.ZipFile(name,'w',zipfile.ZIP_DEFLATED)
    z.writestr('[Content_Types].xml',CT); z.writestr('xl/workbook.xml',WB); z.writestr('xl/_rels/workbook.xml.rels',RELS)
    z.writestr('xl/worksheets/sheet1.xml', sheet)
    if sst: z.writestr('xl/sharedStrings.xml', sst)
    z.close()
H='<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
T='</sheetData></worksheet>'
# sano
xlsx('sano.xlsx', H+'<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row><row r="2"><c r="C2" t="inlineStr"><is><t>ciao</t></is></c></row>'+T,
     '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>condivisa</t></si></sst>')
# stringa condivisa da 1 MiB ripetuta in 100.000 celle = 100 GB
big = 'A'*(1024*1024)
rows = ''.join('<row r="%d">%s</row>' % (r+1, ''.join('<c t="s"><v>0</v></c>' for _ in range(100))) for r in range(1000))
xlsx('condivisa.xlsx', H+rows+T, '<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>'+big+'</t></si></sst>')
# celle di riempimento: 100.000 righe con una sola cella in colonna 1024 (XFD-ish → AMJ)
rows = ''.join('<row r="%d"><c r="AMJ%d"><v>1</v></c></row>' % (r+1, r+1) for r in range(100000))
xlsx('riempimento.xlsx', H+rows+T)
# ods con number-columns-repeated
ODS_H='<?xml version="1.0"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:spreadsheet><table:table table:name="F1">'
ODS_T='</table:table></office:spreadsheet></office:body></office:document-content>'
cell='<table:table-cell table:number-columns-repeated="1024"><text:p>'+('B'*4096)+'</text:p></table:table-cell>'
z=zipfile.ZipFile('ripetute.ods','w',zipfile.ZIP_DEFLATED); z.writestr('mimetype','application/vnd.oasis.opendocument.spreadsheet')
z.writestr('content.xml', ODS_H + ''.join('<table:table-row>'+cell+'</table:table-row>' for _ in range(100000)) + ODS_T); z.close()
z=zipfile.ZipFile('sano.ods','w',zipfile.ZIP_DEFLATED); z.writestr('mimetype','application/vnd.oasis.opendocument.spreadsheet')
z.writestr('content.xml', ODS_H + '<table:table-row><table:table-cell table:number-columns-repeated="3"><text:p>x</text:p></table:table-cell><table:table-cell><text:p>y</text:p></table:table-cell></table:table-row>' + ODS_T); z.close()

# pptx: 200 voci di central directory che puntano tutte allo stesso stream da 400 MiB
def pptx_alias(name, n, size):
    raw = b'<p:sld xmlns:p="p" xmlns:a="a"><a:t>' + b'Z'*(size-60) + b'</a:t></p:sld>'
    co = zlib.compressobj(9, zlib.DEFLATED, -15); comp = co.compress(raw) + co.flush()
    crc = zlib.crc32(raw)
    out = io.BytesIO()
    fn0 = b'ppt/slides/slide1.xml'
    off = out.tell()
    out.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, 8, 0, 0, crc, len(comp), len(raw), len(fn0), 0) + fn0 + comp)
    # content types (stored)
    ct = CT.encode(); fnc = b'[Content_Types].xml'; offc = out.tell()
    out.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, 0, 0, 0, 0, zlib.crc32(ct), len(ct), len(ct), len(fnc), 0) + fnc + ct)
    cd = io.BytesIO()
    cd.write(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, 0, 0, 0, 0, zlib.crc32(ct), len(ct), len(ct), len(fnc), 0, 0, 0, 0, 0, offc) + fnc)
    for i in range(n):
        fn = b'ppt/slides/slide%d.xml' % (i+1)
        # stesso offset: l'header locale ha un nome di lunghezza diversa, ma chi legge usa il local header
        cd.write(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, 0, 8, 0, 0, crc, len(comp), len(raw), len(fn), 0, 0, 0, 0, 0, off) + fn)
    cdb = cd.getvalue(); cdoff = out.tell(); out.write(cdb)
    out.write(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, n+1, n+1, len(cdb), cdoff, 0))
    open(name,'wb').write(out.getvalue())
pptx_alias('alias.pptx', 200, 400*1024*1024)
pptx_alias('sano.pptx', 2, 4096)

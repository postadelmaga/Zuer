# Formati supportati

Quello che Zuer apre e con cosa, per sistema. Il riepilogo è nel [README](../README.md).

| Categoria | Estensioni | Note |
|-----------|-----------|------|
| **Testo / codice / markdown** | `.txt`, sorgenti, `.md`, … | rasterizzazione nativa (stb_truetype), selezione + copia |
| **Tabelle** | `.csv`, `.tsv`, `.xlsx`, `.xls`, `.ods`, `.zip`, `.jar`, `.cbz`, `.epub`, … | griglia con header fisso; workbook multi-foglio con linguette |
| **Archivi** | `.zip`, `.tar`, `.tar.gz`/`.xz`/`.bz2`/`.zst`, `.7z`, `.rar`, `.iso`, `.cab`, `.cpio`, `.xar`/`.pkg`, `.rpm`, `.lha` | elenco del contenuto. zip, tar, gzip, xz e zstd in processo; il resto dal `tar` di sistema quando è bsdtar (macOS, Windows 10+; su Linux il pacchetto `libarchive-tools`) |
| **Immagini** | `.png`, `.jpg`, `.gif`, `.bmp`, `.webp`, `.svg`, `.svgz`, `.ico`, `.tga`, `.psd`, `.hdr`, `.ppm`, `.tif`, `.avif`, `.heic` | in processo ovunque: stb_image, libwebp (anche il primo frame dei WebP animati), nanosvg, ICO in Zig; orientamento EXIF dei JPEG. TIFF/AVIF/HEIC, JPEG XL, JPEG 2000, OpenEXR, DDS e i RAW delle fotocamere (`.dng`, `.cr2`/`.cr3`, `.nef`, `.arw`, `.orf`, `.rw2`, `.raf`, …) dal codec di sistema: ImageIO su macOS (orientamento EXIF applicato), WIC su Windows (AVIF, HEIC, JPEG XL e RAW con le estensioni gratuite dello Store), ImageMagick su Linux |
| **Mesh 3D** | `.obj`, `.stl`, `.glb`, `.gltf`, `.ply`, `.fbx`, `.dae`, `.3ds` | renderer Vulkan (PBR-ish, shadow pass), orbita col mouse |
| **Video** | `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`, `.wmv`, `.flv`, `.mpg`/`.vob`, `.m2ts`, `.3gp`, `.dv`, … | libmpv (Linux) o libav, timeline/scrubbing stile YouTube. La FFmpeg di macOS/Windows include anche WMV/VC-1, ProRes, DNxHD, DV, VP6, Cinepak |
| **Audio** | `.mp3`, `.flac`, `.wav`, `.ogg`/`.opus`, `.m4a`, `.aac`, `.aiff`, `.caf`, `.wma`, `.ac3`, `.dts`, `.wv`, `.ape`, `.mpc`, `.tta`, `.mka`, `.mid` | oscilloscopio; MIDI col synth integrato |
| **Documenti** | `.pdf` | pagina resa come immagine: poppler (`pdftoppm`) su Linux, CoreGraphics su macOS, PDFium (incluso nell'installer) su Windows |
| **Office** | `.docx`, `.xlsx`, `.xlsm`, `.pptx`, `.odt`, `.ods`, `.odp`; su macOS anche `.doc`, `.rtf`, `.webarchive` | decoder Zig, nessuna dipendenza, tutte le piattaforme; su macOS `.doc`/`.rtf` come testo via `textutil` di sistema; `.xls`/`.ppt` non supportati |

Il formato si riconosce anche **senza estensione o con quella sbagliata**:
`src/detect.zig` legge i byte magici dai primi 8 KB (immagini, PDF, ZIP/tar/gzip,
glb, MP4/MKV/WebM/AVI, MP3/FLAC/Ogg/WAV/MIDI) e carica solo il plugin che serve.
I formati riconosciuti ma senza decoder (ELF, PE, SQLite, …) e gli
header troncati danno un errore esplicito. Test: `zig build test`.

Aprendo una **cartella** si apre il primo file e si passa agli altri con le frecce
`↑ ↓` (sempre, per ogni tipo di file). `← →` sfogliano le pagine nei PDF, fanno un
seek di ±5 s nei video e altrove cambiano file anche loro; nel testo si scorre con
PagSu/PagGiù o la rotellina.

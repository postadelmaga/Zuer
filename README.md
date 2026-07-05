# zuer

Un **viewer di file** veloce e GPU-accelerato, scritto in Zig. Apre in un lampo
documenti, tabelle, immagini, mesh 3D e video — sia nel **terminale** (`zuer`) sia
in una **finestra** (`zuer-gui`) — costruito sui framework [zicro](../Zicro) (UI/paint
in stile egui) e [zrame](../Zrame) (finestra + input cross-platform).

Gira su **Linux** (Wayland) e **Windows** (GDI); il rendering 3D passa per Vulkan e
la decodifica video per libav (FFmpeg).

---

## Formati supportati

| Categoria | Estensioni | Note |
|-----------|-----------|------|
| **Testo / codice / markdown** | `.txt`, sorgenti, `.md`, … | rasterizzazione nativa (stb_truetype), selezione + copia |
| **Tabelle** | `.csv`, `.tsv`, `.xlsx`, `.xls`, `.ods`, `.zip`, `.jar`, `.cbz`, `.epub`, … | griglia con header fisso; workbook multi-foglio con linguette |
| **Immagini** | `.png`, `.jpg`, `.gif`, `.bmp`, `.webp`, `.tif`, `.avif`, `.heic`, `.ico` | decodifica nativa (stb_image) |
| **Mesh 3D** | `.obj`, `.stl`, `.glb`, `.gltf`, `.ply`, `.fbx`, `.dae`, `.3ds` | renderer Vulkan (PBR-ish, shadow pass), orbita col mouse |
| **Video** | `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`, `.m4v`, … | player libav con timeline/scrubbing stile YouTube |
| **Documenti** | `.pdf`, office | reso come immagine di pagina (via `pdftoppm`/`soffice`, solo Linux) |

Aprendo una **cartella** si apre il primo file e si naviga tra gli altri con le
frecce `← →`.

---

## Requisiti

- **Zig 0.16-dev** (vedi `minimum_zig_version` in `build.zig.zon`)
- **glslc** (shaderc) — compila gli shader GLSL → SPIR-V durante la build
- I framework **zicro** e **zrame** come repository fratelli in `../Zicro` e `../Zrame`
- **Linux**: loader Vulkan di sistema, FFmpeg (pkg-config), `wayland-client`;
  opzionali per pdf/office: `poppler` (`pdftoppm`) e LibreOffice (`soffice`)

---

## Build & installazione (Linux)

```sh
zig build                 # produce zig-out/bin/{zuer, zuer-gui} + i plugin decoder
./install.sh              # installa in ~/.local/bin + associazioni file (ReleaseSafe)
./install.sh --fast       # build Debug senza LLVM: compila in pochi secondi (sviluppo)
```

Uso:

```sh
zuer file.csv             # viewer nel terminale (kitty graphics o fallback half-block)
zuer-gui immagine.png     # viewer a finestra
zuer-gui ~/cartella/       # naviga i file della cartella con le frecce
```

---

## Windows (cross-compile da Linux)

`zuer-gui.exe` gira su Windows — verificato sotto Wine, mesh 3D e video inclusi.
Il rendering GPU passa per il loader Vulkan di sistema (o `winevulkan`), il testo/
immagini per il compositing CPU. La finestra è **frameless con vetro**, come su
Wayland: pannello arrotondato, ombra decorativa e traslucenza sono dipinti
client-side (stesso `drawChrome` di zicro) e spinti con alpha per-pixel via
`UpdateLayeredWindow` — quindi si vedono **anche sotto Wine**. L'unico pezzo
riservato a Windows vero è il **blur sfocato dietro** il vetro (l'acrilico DWM,
esattamente come su Linux il blur richiede KWin).

```sh
# zuer-gui.exe + i plugin decoder come .dll — SEMPRE in ReleaseFast (vedi sotto)
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

# DLL runtime di FFmpeg (per il video) accanto all'eseguibile — NON sono in git
scripts/fetch-ffmpeg-dlls.sh          # → zig-out/bin/
```

> **Compila sempre con `-Doptimize=ReleaseFast`.** Il default di `zig build` è Debug:
> il rendering GPU resta veloce (lo fa la GPU) ma il **compositing CPU** dei frame
> gira non ottimizzato ed è 3–4× più lento — il 3D diventa scattoso.

### Variabili d'ambiente utili

| Var | Effetto |
|-----|---------|
| `ZUER_GPU=<indice\|nome>` | forza la GPU (es. `ZUER_GPU=intel` o `ZUER_GPU=0`); zuer logga i device che vede. Off-Linux preferisce l'**integrata** (readback economico) |
| `ZUER_OPAQUE=1` | finestra **opaca** (BitBlt veloce) invece del vetro layered: utile per testare 3D/video fluidi **sotto Wine**, dove senza DWM il vetro va composto in software. Su Windows vero il DWM compone il vetro in GPU, quindi non serve |

Due capacità native, ognuna con la sua import-lib, attivabili a parte:

| Flag | Default | Cosa abilita |
|------|---------|--------------|
| `-Dvulkan` | Linux + Windows | renderer mesh/testo. Su Windows usa la import-lib vendorata in `vendor/vulkan/` (→ `vulkan-1.dll`) |
| `-Dffmpeg` | Linux + Windows | player video libav. Su Windows usa header + import-lib in `vendor/ffmpeg/` (le DLL si scaricano a parte) |

> Le DLL FFmpeg (~130 MB) seguono il modello VLC: **spediscono con l'app, non con il
> sorgente**. In git stanno solo header e import-lib (~2.3 MB) per compilare.

Ancora solo su Linux: la **TUI** (`zuer`, il present GPU nel terminale usa un memfd
cross-process del protocollo kitty) e i decoder **pdf/office** (tool esterni).

---

## Architettura

Due frontend condividono lo stesso stack di decodifica e rendering:

```
 zuer (TUI)  ─┐                        ┌─ decoder.zig ──┬─ decoders/*.zig  (plugin .so/.dll:
 zuer-gui  ──┼─ loader.zig (data plane)┤                │   text, csv, markdown, image, glb,
             │                         └─ (dispatch)    │   mesh, archive, media, pdf, office)
             │
             ├─ rendering GPU:  gpu_renderer.zig (Vulkan) · renderer/vk.zig (binding) · voxel.zig
             ├─ rendering CPU:  text_render.zig · glyph.zig (stb_truetype) · compose.zig
             └─ seam per-OS:    terminal.zig · clipboard.zig · dynlib.zig · (finestra: zrame)
```

Il **GUI** (`gui.zig`) è organizzato in moduli coesi:

- **`compose.zig`** — compositing CPU dei frame (immagini aspect-fit + zoom/pan, testo
  blittato 1:1 con header ancorato, selezione, barra linguette)
- **`layout.zig`** — dal percorso/decodifica al tipo di contenuto (`WinKind`) e da lì
  a zoom e dimensione iniziale della finestra
- **`video.zig`** — player video nativo (apertura container, riproduzione, controlli
  overlay); possiede l'import condizionale di libav
- **`loader.zig`** — piano dati: decodifica su thread worker + staging GPU della geometria
  (memfd zero-copy su Linux, buffer CPU altrove)

I **decoder** sono librerie dinamiche caricate a runtime (`decoder_<fmt>.so`/`.dll`):
aggiungerne uno = un nuovo file in `src/decoders/` più una voce nella lista di `build.zig`.

Portabilità: zicro e zrame nascondono le differenze di OS (finestra, input, clipboard,
dynamic loading) dietro API uniformi, così zuer resta in gran parte agnostico rispetto
alla piattaforma. I punti che restano specifici sono isolati in file per-OS
(`terminal.zig`, `clipboard.zig`, `dynlib.zig`) o dietro flag comptime.

---

## Strumenti di sviluppo

```sh
zig build gpu-selftest    # render headless di un cubo per validare la pipeline mesh
zig build raster-debug -- file      # rasterizza un file su PPM (stdout)
zig build decode-test -- file       # decodifica un file e stampa il risultato
zig build player-test -- video      # itera i frame video col motore libav
```

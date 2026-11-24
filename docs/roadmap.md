# Roadmap di Zuer

Stato al 24 novembre 2026, versione 0.4.0 (commit `205bc6a`). Nasce dalla revisione
completa del codice di quel giorno: 39 difetti aperti come issue (#26–#64), più le
issue che erano già aperte. Come è fatto il progetto: [architettura.md](architettura.md).

L'idea di fondo: Zuer regge bene nei punti difficili (scheduler, coda video, confine
host↔plugin). I difetti si concentrano in tre cause, e conviene togliere le cause
invece di rincorrere i sintomi:

1. **nessun tetto complessivo di memoria nei decoder** — ogni plugin inventa i suoi
   limiti o non ne ha;
2. **percorsi `file#frammento` interpretati a mano** in oltre 25 punti, con tre
   grammatiche diverse;
3. **più strade per installare un contenuto** (`applyDecoded`, YouTube, riapertura
   video), ognuna con un sottoinsieme diverso dello stato.

## Ordine proposto

| Passo | Cosa | Issue | Finito quando |
|---|---|---|---|
| 0 | Correzioni rapide: una o poche righe, effetto subito visibile | 11 issue (sotto) | **fatto** il 24 novembre 2026 |
| 1 | [File ostili e robustezza dei decoder](https://github.com/postadelmaga/Zuer/milestone/2) + budget di memoria (A1) | #26–#36 | nessun file della raccolta ostile fa cadere il processo o supera il budget |
| 2 | [Navigazione, apertura e GUI](https://github.com/postadelmaga/Zuer/milestone/3) + riferimento a documento (A2) + punto unico di installazione (A3) | #37–#50 | i frammenti passano da un solo parser; un solo commit dello stato |
| 3 | [Media e YouTube](https://github.com/postadelmaga/Zuer/milestone/4) | #51–#57 | `scripts/video-check.sh` copre seek a fine file, TS con partenza ≠ 0, stream che cade |
| 4 | [Cache, plugin e piattaforme](https://github.com/postadelmaga/Zuer/milestone/5) | #58–#64 | Android provato su un dispositivo; anteprima delle voci d'archivio su Windows |
| 5 | Riordino (fase B) | da aprire | vedi sotto |
| 6 | Già in programma prima della revisione | #5, #13, #14, #16, #17, #20–#25 | — |

I passi 1–4 non dipendono l'uno dall'altro: l'ordine è per rischio (prima ciò che fa
cadere l'applicazione su un file qualsiasi della cartella aperta).

## Passo 0 — Correzioni rapide

**Fatto il 24 novembre 2026.** Poche righe ciascuna, nessuna scelta di disegno da fare.
Da sole giustificano una 0.4.1. Resta da aggiungere un caso per ciascuna a
`scripts/edge-check.sh` (i file di prova usati sono descritti nelle issue).

| Issue | Correzione |
|---|---|
| #37 | il `#` è un separatore solo dopo un'estensione che ha frammenti (pdf, fogli, archivi): regola unica in `src/fragment.zig`, usata da host, GUI e plugin |
| #26 | aritmetica controllata in `media.zig` (4 punti) |
| #47 | `-resize WxH!` |
| #48 | chiudere l'ultima riga del CSV |
| #29 | `.svgz` con `allocRemaining(.limited)` |
| #31 | cast controllati su ICO e glTF, somme saturanti negli archivi |
| #58 | Android: non liberare due volte i byte di mesh e glb |
| #44 | richiesta e `loading` pubblicati insieme, sotto lo stesso lock |
| #40 | un messaggio per ogni errore di installazione della mesh |
| #38 + #39 | un solo formato per il frammento di pagina **e**, nello stesso cambio, non mettere in cache la pagina a bassa risoluzione (sistemare solo #38 rende #39 molto più frequente) |

## Fase A — Tre cambi che tolgono la causa

**A1 · Budget di memoria per decode** (passo 1; chiude alla radice #28, #29, #30, #33).
L'host conosce già `max_size` (`decoder.zig:1891`) ma non lo passa ai plugin.
- Avvolgere l'allocatore passato via ABI in un allocatore con tetto (k × `max_size`),
  uno per decode: i casi da decine di GB diventano `OutOfMemory` gestiti invece
  dell'OOM killer.
- Mettere `max_size` in `HostServices`, per i plugin che devono decidere prima di
  allocare (pixel di una texture, celle di un foglio).
- Raccolta di file ostili in `tests/` + un passo di `edge-check.sh`: uno per issue
  della milestone 1.
- Il ripiego ImageMagick (#27) è a parte: è un processo esterno, serve la lista dei
  formati ammessi e il coder esplicito.

**A2 · Riferimento a documento** (passo 2; chiude alla radice #37, #38, e parte di #42).
Il primo pezzo c'è già: `src/fragment.zig` decide in un solo punto dove finisce il
percorso e dove comincia il frammento. Manca il resto: un tipo `percorso + selezione` (`nessuna | pagina N | foglio N | voce "nome"`) con un
solo parser e un solo formatter, passato ai plugin come campo separato invece che
dentro la stringa. Oggi il taglio al `#` è ripetuto in `decoder.zig`, `gui_state.zig`,
`nav.zig`, `input.zig`, `layout.zig`, `video.zig`, `print.zig`, `info_popup.zig`,
`pdf.zig`, `office.zig`, `archive.zig`, `tar.zig`.

**A3 · Un solo punto di installazione del contenuto** (passo 2; chiude alla radice
#41, #42, #46, e rende #40 e #44 impossibili per costruzione).
Una `install(state, contenuto, generazione)` con una fase fallibile fuori dal lock e
un commit che non può fallire. La usano il loader, la cache di prefetch, YouTube e la
riapertura del video. `current_file_path` torna a essere solo un percorso: il titolo
di uno stream va in un `display_name`, la sorgente in una `union(enum){ file, youtube }`.

## Fase B — Riordino

Da aprire come issue quando ci si arriva. Nessuno di questi punti corregge un difetto
da solo, ma ognuno ne ha prodotti.

- **`renderWorker`** (`gui.zig:394-1139`, 745 righe): la sequenza etichetta →
  esploratore → YouTube → popup è copiata tre volte con differenze, l'allocazione del
  framebuffer tre volte. Estrarre `ensureFramebuffer()` e `drawOverlays()`, un ramo
  per funzione. Si incrocia con #16 (GUI sul bus di zicro) e #13 (overlay come
  `zrame.Panel`): decidere prima quale delle due strade.
- **`decoder.zig`** fa cinque mestieri ed è compilato dentro ogni plugin: separare i
  tipi dell'ABI (`decoder_abi.zig`) dall'host (registro, dispatch, estrazione). Le due
  `cache_evict.zig` identiche diventano una.
- **Tabella unica delle estensioni**: oggi copiata in sei posti (`plugin_manifest`, le
  `extensions` di ogni decoder, `isArchiveExt`, `layout.zig`, `android_decode.zig`,
  `android_ui.zig`) e già divergente. Una tabella comptime e un test che le leghi.
- **Colla dei plugin**: un `decoder.exportPlugin(comptime Impl)` che genera gli export,
  possiede `content` e valida l'UTF-8 dei `.text` una volta sola (#32).
- **Cache su disco**: cinque implementazioni (mesh, texture, VT, estrazione, pagine
  PDF e miniature) con politiche diverse. Un `diskcache.zig` con cartella per sistema,
  scrittura atomica con pulizia, tetto LRU (#60, #61).
- **Processi esterni**: tre modi di lanciarli con garanzie diverse. Un `proc.zig` con
  timeout, tetto sullo stdout, gruppo di processi e lancio staccato (#35, #56).
- **Media**: un'interfaccia `Engine` con due implementazioni (mpv, FFmpeg), ciascuna
  con il proprio clock; via il modo ibrido «mpv muto con audio esterno»; il disegno
  (oscilloscopio, controlli, sottotitoli) fuori da `video.zig`. Togliere cvp9 o
  spegnerlo di default: serve solo quando manca mpv.
- **Android**: far passare il decode da `decoder.decode` con una tabella statica dei
  decoder linkati, invece del terzo dispatch di `android_decode.zig` (origine di #58).
- **Markdown**: `md_layout.layout` riceve i blocchi già analizzati invece del sorgente
  (oggi si riparsa a ogni zoom e in stampa); l'evidenziatore in un file suo per
  rompere il ciclo `md_layout` ↔ `text_render`.
- **Testo**: tre motori (layout ritenuto, testo GPU a richiesta, bitmap intera usata
  solo da `raster_debug`). Tenere il primo.
- **Pulizia**: `decoder-wip.patch` (superato), `Doc` con undo nella TUI senza azioni di
  undo, `app_state` di Android mai letto, `vt_tiles_x/y`, `MpvVideo.hasAudio`.
- **Documentazione**: `architettura.md` non nomina `nav.zig`, `input.zig`,
  `gui_state.zig`, `video_decoder.zig`, `mpv_video.zig`, e presenta `loader.zig` come
  piano dati della GUI (lo è della TUI). Serve una sezione «Media».
- **CI**: i test girano solo nel workflow di release. Un workflow su push con
  `zig build test` ed `edge-check.sh` avrebbe fermato #26 e #31.
- **Test dei percorsi d'errore**: `std.testing.FailingAllocator` sui convertitori
  dell'ABI e sui decoder (#63).

## Già in programma

Issue aperte prima della revisione, nell'ordine in cui si incastrano con il resto.

| Tema | Issue | Nota |
|---|---|---|
| Crash report | #17 | il deploy del receiver viene **dopo** #36 |
| Prestazioni del render worker | #20 | i punti sul lock si fanno insieme ad A3 |
| GUI su zicro ([milestone «Audit architettura 2026-07»](https://github.com/postadelmaga/Zuer/milestone/1)) | #16, #13, #14 | da decidere prima del riordino di `renderWorker` |
| Colore | #21, #22, #23, #24, #25 | indipendenti dal resto |
| TUI su Windows | #5 | — |
| Android | M2 core e decoder statici + Storage Access Framework → M3 griglia di anteprime → M4 media e intent-filter | prima #58 e #59 |
| Icona | icona dentro `zuer-gui.exe`, icona adattiva Android | i derivati stanno in `icons/` |

## Da non toccare

Parti verificate nella revisione, da prendere a modello: `scheduler.zig`; la coda
SPSC con `wake.zig`; `icc.zig` (letture opzionali, somme in `u64`, tetti prima di
allocare); `thumbs.zig`; l'impronta ABI a comptime e il caricamento dei plugin; la
costruzione degli argomenti dei processi esterni (sempre argv, mai shell, prefissi
fissi).

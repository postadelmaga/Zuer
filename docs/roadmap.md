# Roadmap di Zuer

Stato al 25 novembre 2026, versione 0.4.0. Nasce dalla revisione completa del codice
del 24 novembre (commit `205bc6a`): 39 difetti aperti come issue (#26–#64), più le
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
| 1 | [File ostili e robustezza dei decoder](https://github.com/postadelmaga/Zuer/milestone/2) + budget di memoria (A1) | #26–#36 | **issue fatte** il 24 novembre 2026; di A1 resta il tetto generale (sotto) |
| 2 | [Navigazione, apertura e GUI](https://github.com/postadelmaga/Zuer/milestone/3) + riferimento a documento (A2) + punto unico di installazione (A3) | #37–#50 | **issue fatte** il 25 novembre 2026; restano A2 e A3 (sotto): i frammenti non passano ancora da un solo parser, lo stato non ha ancora un solo commit |
| 3 | [Media e YouTube](https://github.com/postadelmaga/Zuer/milestone/4) | #51–#57 | **issue fatte** il 25 novembre 2026: `scripts/video-check.sh` copre seek a fine file e TS con partenza ≠ 0, `scripts/net-check.sh` lo stream che cade |
| 4 | [Cache, plugin e piattaforme](https://github.com/postadelmaga/Zuer/milestone/5) | #58–#64 | **issue fatte** il 25 novembre 2026; le voci d'archivio su Windows sono provate sotto wine, Android resta da provare su un dispositivo (sotto) |
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

## Passo 1 — File ostili e robustezza dei decoder

**Issue fatte il 24 novembre 2026** (#26, #29 e #31 erano già nel passo 0). Ogni
difetto è stato riprodotto sul binario precedente e riprovato su quello nuovo; i file
li scrive `scripts/hostile-gen.py` e li verifica `scripts/hostile-check.sh` (esito
atteso entro 60 s e 4 GB, senza crash).

| Issue | Correzione |
|---|---|
| #27 | a ImageMagick vanno solo i formati riconosciuti dai byte magici, con il coder scritto nell'argomento (`tiff:/percorso[0]`): un PostScript chiamato `.png` non arriva più a Ghostscript |
| #28 | glTF: stride minimo, ogni nodo visitato una volta sola, tetto a vertici e facce della scena (il doppio di ciò che sta nel BIN, mai meno di 16 milioni di vertici), tetto ai pixel di una texture letto dall'header, budget sulle texture di tutto il modello, texture oltre 4096² decodificate una alla volta |
| #30 | office: un budget per documento su byte decompressi, celle e testo delle celle; esaurito, il documento si tronca lì (senza avviso, come già i tetti di righe e slide) |
| #32 | il testo dei plugin è validato dall'host una volta sola; stampa, layout e disegno del testo decodificano con `src/utf8_lossy.zig` (una sequenza tagliata a fine cella faceva cadere la GUI anche con un `.csv`) |
| #33 | Markdown: la sequenza di righe vuote di una lista si misura una volta, tetto a colonne e a celle di tabella su tutto il documento, autolink senza `<` dentro |
| #34 | coordinate e UV non finite a 0 in OBJ, STL e glTF; nella TUI e nel voxelizzatore la conversione a intero non può più fallire |
| #35 | id dei video validati anche dalla ricerca e dalla coda; tetto di 512 MiB allo stdout catturato; `xdg-open` lanciato senza pipe |
| #36 | il receiver accetta solo righe `panic <epoch>s @ 0x…: …` in ASCII e senza link, le pubblica in un blocco di codice che non si può chiudere, tiene dedup e contatori sotto lock e ha un tetto per indirizzo (per /64 con IPv6) |

Cosa resta, e non è in nessuna issue aperta:

- **il tetto generale di A1**: le correzioni qui sopra sono limiti mirati, uno per
  formato. Un formato nuovo, o un caso non previsto, non ne è coperto;
- **avviso di troncamento**: un foglio o un modello tagliato da un budget si apre
  senza dire che manca qualcosa;
- **`policy.xml` per ImageMagick**: i coder ammessi sono scelti da noi, ma dentro
  ImageMagick valgono ancora i limiti della macchina;
- **il receiver non distingue un panic vero da uno inventato** (vedi l'intestazione
  di `server/zuer-crash.php`): serve un segreto nel client, da decidere con #17;
- **non provato**: i RAW attraverso il coder `dng:` (nessun campione), il
  `threadlocal` del plugin office su Windows e Android (compila, non eseguito).

## Passo 2 — Navigazione, apertura e GUI

**Issue fatte il 25 novembre 2026** (#37–#40, #44, #47 e #48 erano già nel passo 0).
Provate in una sessione sway senza schermo, con schermate e appunti letti dal
compositor; dove la prova non c'è, è scritto.

| Issue | Correzione | Prova |
|---|---|---|
| #41 | l'apertura di uno stream prende una generazione di navigazione (`nav.claimGeneration`) e rinuncia se nel frattempo si è aperto altro; il suo errore non riapre l'overlay sopra il file nuovo | apertura normale provata; il caso «superato» solo letto sul codice |
| #42 | il titolo dello stream sta in `display_name`, `current_file_path` torna a essere solo un percorso (vuoto durante uno stream), la cartella delle frecce è quella della lista (`list_dir`) | etichetta, scheda `i`, Ctrl+C (copia il link) e frecce dopo uno stream |
| #43 | le miniature già tentate si ereditano solo insieme alla miniatura | solo codice |
| #45 | esploratore e ricerca si disegnano anche sopra lo spinner di caricamento | solo codice (la finestra di tempo è troppo breve da colpire a mano) |
| #46 | video, audio e MIDI non passano dalla cache dei vicini: li apre sempre il loader, fuori dal lock, e se lì falliscono non si riprova sotto il lock | navigazione avanti e indietro fra immagini, video, audio e testo |
| #49 | la catena mip segue un contatore (`static_serial`) e non il solo puntatore dei pixel | solo codice |
| #50 | lo scadere dei 2 s su una fence non è più un errore: si aspetta il device (`vk.waitFence`); dopo un errore di `render` la sincronizzazione dei due slot riparte da capo | **non riprodotto**: era un sospetto, e resta provato solo che Vulkan continua a funzionare |

Trovato strada facendo, e corretto: aprendo uno stream con un'immagine a schermo la
finestra a volte spariva (3 aperture su 8 nella sessione di prova). `yt_search`
chiedeva la taglia nuova senza prima dare alla finestra le proporzioni del video: la
taglia veniva piegata su quelle dell'immagine, e subito dopo il render la rimappava
una seconda volta. Ora le proporzioni arrivano prima, come già in
`nav.resizeToContent` (7 aperture su 7). La causa di fondo era in Zicro ed è
corretta lì (commit `02088eb`): `setContentSize` smontava la finestra anche quando
non aveva ancora un buffer, cioè fra il `configure` appena confermato e il primo
disegno; per il compositor non era uno smontaggio, nessun `configure` ripartiva e la
finestra restava senza buffer. Riprodotto con un client minimo (bloccata prima, a
schermo dopo), insieme al caso gemello di `setVisible`.

Cosa resta del passo:

- **A2 e A3** non sono fatti. Di A3 c'è il primo pezzo (`display_name`, la
  generazione per gli stream); l'installazione di uno stream resta una strada a
  parte e non tocca `shared.decoded`.
- la selezione dell'esploratore parte dal primo file e non da quello aperto: era
  così anche prima, non è in nessuna issue.

## Passo 3 — Media e YouTube

**Issue fatte il 25 novembre 2026.** Ogni difetto del motore FFmpeg e dell'audio è
stato misurato sul commit precedente e sul nuovo con lo stesso banco
(`zuer-video-bench`, `feature-probe`).

| Issue | Correzione | Prova (prima → dopo) |
|---|---|---|
| #51 | a fine file il decoder si svuota fino in fondo; un seek che finisce senza un frame fa ripartire la riproduzione invece di fermarla | seek a 0,01 s dalla fine di un MP4: 0 frame e video fermo → riparte (fase `seek-end` del banco) |
| #52 | i tempi del motore FFmpeg e dell'`AudioPlayer` sono riportati all'inizio del container, il seek lo rimette | MPEG-TS che parte da 5000 s: 0 frame e orologio audio a 5001 s → 30 fps e orologio da zero |
| #53 | un errore di lettura aspetta 50 ms (al massimo 5 s), un file senza audio decodificabile non gira a vuoto | WAV di sola intestazione: 100% di una CPU → 2% |
| #54 | a regime la fine o l'errore del file segnano la sessione come caduta; una sorgente di rete che ricomincia da capo lontano dalla fine è caduta (mpv non chiude il file: rifà in loop ciò che ha in cache); la GUI riapre lo stream YouTube da quel punto con indirizzi nuovi, o ricarica il file, una volta ogni 30 s; un `loadfile` rifiutato fa ripiegare subito, e si riprova nella forma precedente a mpv 0.38 | server spento a metà: loop infinito su 1,5 s → riconosciuto 3 volte su 3. **Non provati**: la riapertura da YouTube da capo a fondo e una libmpv più vecchia della 0.38 |
| #55 | video, audio, MIDI e stream si aprono in pausa e partono quando sono installati; uno stream si apre già alla posizione chiesta | riproduzione e cambio di file provati; che non suoni «sopra» non è misurabile senza casse |
| #56 | Ctrl+C copia su un thread, con un limite di 3 s e `pbcopy` su macOS; con uno stream copia il link | appunti letti con `wl-paste` |
| #57 | ogni `loadfile` ha un gettone e l'id della voce di playlist: la fine di un file precedente non vale per quello nuovo; il motore si preavvia quando l'overlay si apre o la selezione cambia, non a ogni disegno | 100 aperture a caldo e 30 a freddo senza fd o thread in più. **Non riprodotto** lo stop più lento di 1 s che faceva scattare il difetto |

Cosa resta, e non è in nessuna issue aperta:

- **`shutdownEngines` all'uscita non serve**: la GUI esce con `_exit` proprio per
  non eseguire i distruttori di mesa e libmpv mentre i loro thread lavorano;
- **MPEG-TS, seek**: il motore FFmpeg atterra sul keyframe dopo il punto chiesto
  (fino a un GOP più avanti). Era così anche prima; ora almeno la posizione è giusta;
- **errore di lettura = fine file** nel `Player` video: una caduta di rete durante
  un seek, col motore FFmpeg, fa ripartire da capo invece di restare sul punto;
- **audio e video in container diversi** (ripiego FFmpeg sugli stream): l'audio usa
  l'origine dei tempi del video; se la sua traccia comincia prima, quei millisecondi
  si perdono;
- **le prove video in sway senza schermo** falliscono su CPU in pausa, clip troncati
  e passaggio hardware→software allo stesso modo sul commit precedente: lì non c'è
  GPU né scheda audio, vanno rifatte su una sessione vera.

## Passo 4 — Cache, plugin e piattaforme

**Issue fatte il 25 novembre 2026** (#58 era già nel passo 0). Windows è provato
sotto wine con il binario compilato da Linux, non su una macchina vera; Android solo
compilato.

| Issue | Correzione | Prova (prima → dopo) |
|---|---|---|
| #59 | ogni funzione di `android_jni.zig` apre e chiude un frame di riferimenti locali (`enter`/`leave`), che ripulisce anche un'eccezione rimasta pendente; `android_main` stacca il thread prima di uscire | **solo compilato** (`zig build android`): nessun dispositivo collegato |
| #60 | la cache d'estrazione sta in `src/extract_cache.zig`: cartella per sistema (`%LOCALAPPDATA%\zuer\extract` su Windows), tetto di 2 GiB con pulizia delle cartelle d'archivio usate meno di recente (l'uso si segna su un file `<chiave>.used`, la data delle voci non si tocca), temporanei con PID e sequenza e un nome che non dipende dalla voce, chiave calcolata su byte definiti; su Windows si rifiutano i nomi con `:`, i nomi di dispositivo e quelli che finiscono con punto o spazio | wine, `prova.zip#a.txt`: `NoHomeDir` → il testo della voce; `C:evil.txt`, `nul.txt`, `coda.txt.` rifiutati. Su Linux un PDF dentro un archivio riaperto quattro volte: una sola pagina in cache. La pulizia è provata da un test su una cartella temporanea, non su una cache vera da 2 GiB |
| #61 | scrittura a metà o rename fallito: il temporaneo si toglie subito (mesh, texture, tile VT, pagine PDF, coda di YouTube) | scritture limitate a 100 KiB (`ulimit -f`), cache mesh: un `.tmp` da 100 KiB lasciato → nessuno. Texture, tile e pagine PDF: stessa correzione, solo letta sul codice |
| #62 | un plugin assente, con ABI diversa o senza `zuer_decode` non si ritenta più nel processo (`failed_plugins`); uno che c'è ma non si carica si riprova tre volte; la memoria esaurita non conta come verdetto | plugin `csv` finto con ABI 0 e sei file: 13 tentativi di caricamento → 1 |
| #63 | i convertitori fra `Decoded` e `DecodedC` sono tutto o niente: se manca la memoria l'ingresso resta intero e lo libera chi ha chiamato (`Decoded.intoC` nei plugin, `DecodedC.deinit` nell'host); niente più letterali in `.err` e nei nomi delle mesh; glb non libera due volte le liste e non perde le slice già prese; OBJ e STL non ritornano più una mesh con i conteggi pieni e le slice vuote; office libera la cella ODS oltre il tetto di colonne e le righe rimaste a metà; la TUI copia lo stato prima di liberare il vecchio | test con un allocatore che fallisce a ogni allocazione, una alla volta, su tutte le forme di `Decoded` (tolto un `errdefer`, il test segnala il leak); test sul foglio ODS più largo del tetto. glb, mesh e TUI: solo codice |
| #64 | i plugin si caricano con `LoadLibraryExW` e la ricerca limitata a cartella del plugin, cartella dell'eseguibile e System32; così anche FFmpeg quando si carica a runtime (`player.zig`) | wine, una `avutil-61.dll` finta accanto al documento: caricata da lì → non caricata |

Trovato strada facendo, e corretto:

- **la coda di YouTube non si salvava mai** (dal 9 novembre): `saveQueue` creava una
  cartella col nome del file, il rename finale falliva sempre e la coda restava nel
  `.tmp`, mai riletto. Ora si crea solo la cartella che lo contiene, e al primo
  caricamento la cartella sbagliata si toglie e il `.tmp` rimasto diventa il file
  (provato nella sessione sway: la coda ricompare);
- **`Dir.setTimestamps` su Windows va in panic** (non è implementata nella libreria
  standard di Zig 0.17): la prima stesura la usava per segnare il riuso di una voce.
  L'ha trovato la prova sotto wine; su Linux non si vedeva;
- **segnare il riuso sulla voce stessa** ne cambiava la data, che a valle fa da chiave
  alla cache delle pagine PDF e a quella delle mesh: ogni riapertura rifaceva tutto.
  L'ha trovato la revisione indipendente; da qui il file `.used`.

Cosa resta, e non è in nessuna issue aperta:

- **Android su un dispositivo**: #58 e #59 sono corretti sul codice e compilano, ma
  l'APK non è mai stato eseguito dopo queste modifiche;
- **Windows vero**: wine carica le DLL con le stesse regole, ma l'installer e
  `zuer-gui.exe` non sono stati provati su Windows;
- **le altre cache non hanno ancora la cartella per sistema**: mesh, texture e pagine
  PDF usano solo `HOME` e sono spente fuori da Linux. Si sistemano insieme, con il
  `diskcache.zig` della fase B;
- **un plugin installato a programma aperto** si vede al prossimo avvio: è il prezzo
  di non ritentare;
- **la pulizia può ancora buttare una cartella che qualcuno sta per aprire**: la
  rimisura subito prima di cancellarla, ma fra le due c'è un istante. Chi perde vede
  un errore di apertura e riapre;
- **la prima estrazione di ogni processo cammina tutta la cache** prima di ritornare:
  con una cache piena può ritardare la prima anteprima (non misurato);
- **su Windows si rifiutano anche nomi legittimi**: qualunque voce con `:` nel nome e
  `aux.c`, `con.h`, `nul.txt`. È la scelta prudente; l'alternativa è estrarle con un
  nome diverso su disco;
- **`texture_tante.glb` di `hostile-check.sh` è al limite**: in Debug prende 54 s dei
  60 concessi, e con la macchina carica li supera (64 s; il commit precedente, nello
  stesso momento, 70 s);
- **overlay di YouTube in una finestra stretta**: il pulsante «Coda» si sovrappone ai
  pulsanti di qualità (visto in prova, c'era già);
- **Android, `pdfPage`**: se il PDF è cifrato il descrittore del file resta aperto
  finché non passa il garbage collector (c'era già).

## Fase A — Tre cambi che tolgono la causa

**A1 · Budget di memoria per decode** (passo 1; chiude alla radice #28, #29, #30, #33).
L'host conosce già `max_size` (`decoder.zig:1891`) ma non lo passa ai plugin.
- Avvolgere l'allocatore passato via ABI in un allocatore con tetto (k × `max_size`),
  uno per decode: i casi da decine di GB diventano `OutOfMemory` gestiti invece
  dell'OOM killer.
- Mettere `max_size` in `HostServices`, per i plugin che devono decidere prima di
  allocare (pixel di una texture, celle di un foglio).
- La raccolta di file ostili c'è (`scripts/hostile-check.sh`): è il banco di prova
  per questo cambio, i casi di #28 e #30 devono restare verdi anche col solo tetto
  generale.

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

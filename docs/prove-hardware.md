# Prove manuali su hardware fisico

La CI prova Windows e macOS su **macchine virtuali**: niente GPU fisica sul runner
Windows, GPU paravirtuale sul Mac, scheda audio virtuale (VB-CABLE) su Windows, nessun
utente. Queste prove coprono quello che solo una macchina vera può dire. Ognuna ha un
esito atteso preciso: se l'esito è diverso, annotare cosa si è visto e il log.

Per ogni giro registrare: modello della macchina, CPU, GPU e versione del driver,
versione del sistema, commit di Zuer (`zuer-gui --version`), data.

## Materiale

- Il pacchetto (`zuer-<versione>-windows-x64-setup.exe` o `…-macos-arm64.tar.gz`) e il
  **kit di prova** dallo stesso run della CI (artefatto `prove-windows-x64` o
  `prove-macos-arm64`): `feature-probe`, gli script `*-check.sh`, i corpus
  `images/` e `office/`, `make-test-docs.py`.
- Windows: Git Bash (per gli script), Python 3, FFmpeg da riga di comando (solo per
  generare i clip). macOS: Python 3, FFmpeg (`brew install ffmpeg`).
- Clip di prova, generati in locale (nessun file con diritti):

  ```bash
  mkdir -p clip && cd clip
  # 4K H.264 e HEVC 10 bit, AV1, VP9: 30 s, audio MUTO
  for c in "libx264 -pix_fmt yuv420p h264.mp4" "libx265 -pix_fmt yuv420p10le -tag:v hvc1 hevc10.mp4" \
           "libsvtav1 -preset 8 av1.mp4" "libvpx-vp9 -b:v 8M vp9.webm"; do
    set -- $c; out=${!#}
    ffmpeg -loglevel error -f lavfi -i testsrc2=size=3840x2160:rate=60 -f lavfi -i anullsrc=r=48000:cl=stereo \
      -t 30 -c:v $1 "${@:2:$#-2}" -c:a aac -shortest "$out"
  done
  # Sincronia A/V: lampo bianco e bip a 1 kHz insieme, ogni secondo
  ffmpeg -loglevel error -f lavfi -i "color=black:s=1280x720:r=60,drawbox=enable='lt(mod(t,1),0.05)':c=white:t=fill" \
    -f lavfi -i "sine=f=1000:r=48000,volume=enable='gte(mod(t,1),0.05)':volume=0" \
    -t 60 -c:v libx264 -pix_fmt yuv420p -c:a aac av-sync.mp4
  ```

  `av-sync.mp4` è **udibile**: va riprodotto solo nella prova A/V, a volume basso.

Windows: installare il pacchetto, poi copiare `feature-probe.exe` in
`%LOCALAPPDATA%\Programs\Zuer` (accanto a `zuer-gui.exe`: usa gli stessi plugin e le
stesse DLL). Disinstallando, la cartella va pulita a mano di quel file.
macOS: copiare `Zuer.app` in una cartella di lavoro (non in Applicazioni) e
`feature-probe` in `Zuer.app/Contents/MacOS/` della copia.
Negli esempi `P` è il percorso di `feature-probe`.

## 1. Decodifica video hardware

| # | Prova | Esito atteso |
|---|---|---|
| 1.1 | `P video clip/h264.mp4` | `decodifica hardware: sì`; log `decodifica D3D11VA attiva` (Windows) o `VideoToolbox attiva` (macOS) |
| 1.2 | stessa cosa con `hevc10.mp4`, `av1.mp4`, `vp9.webm` | hardware sì dove la GPU ha il codec (vedi la tabella del produttore); dove non ce l'ha, `decodifica software` e la prova passa lo stesso |
| 1.3 | `ZUER_TEST_HWFAIL_AFTER=30 P video clip/h264.mp4` | ripiego al software a metà, `pts continui`, nessun buco |
| 1.4 | GUI: aprire `h264.mp4`, riprodurre 30 s a schermo intero | nessun frame strappato o fermo; CPU di `zuer-gui` (Gestione attività / Monitoraggio Attività) annotata. Con hardware attivo deve stare molto sotto a un core |
| 1.5 | GUI: 20 seek con le frecce durante la riproduzione | ogni seek mostra l'immagine nuova entro ~0,5 s, audio e video ripartono insieme |
| 1.6 | Solo Windows, portatile con due GPU: ripetere 1.1 con Zuer assegnato alla GPU integrata e poi alla dedicata (Impostazioni → Schermo → Grafica) | hardware sì in entrambi i casi |

## 2. Audio

| # | Prova | Esito atteso |
|---|---|---|
| 2.1 | `P audio-devices` (Windows) | elenco dei dispositivi veri, `*` sul predefinito |
| 2.2 | `P audio clip/h264.mp4` (traccia muta) | orologio che avanza; latenza stampata fra 10 e 200 ms |
| 2.3 | GUI, `av-sync.mp4`, volume basso: guardare e ascoltare 60 s | lampo e bip percepiti insieme. Per una misura: filmare schermo e altoparlante con il telefono a 240 fps e contare i fotogrammi fra lampo e inizio del bip (accettabile: entro ±45 ms, la soglia ITU-R BT.1359) |
| 2.4 | durante la riproduzione, cambiare il dispositivo predefinito (cuffie USB/Bluetooth ↔ altoparlanti) | l'audio passa al nuovo dispositivo entro ~1 s, il video non si ferma |
| 2.5 | staccare le cuffie USB durante la riproduzione | nessun crash; l'audio riprende sul dispositivo rimasto |
| 2.6 | Windows: `set ZICRO_AUDIO=waveout` e ripetere 2.2 | funziona (uscita di riserva) |
| 2.7 | sospendere la macchina durante la riproduzione, riprendere | l'app risponde, la riproduzione riprende o resta in pausa, nessun crash |

## 3. 3D (Vulkan; MoltenVK su macOS)

| # | Prova | Esito atteso |
|---|---|---|
| 3.1 | `P gpu` | `renderer` col nome della GPU vera (non `llvmpipe`/`lavapipe`/`Paravirtual`), cubo reso |
| 3.2 | GUI: aprire un `.obj`/`.glb`/`.stl` vero (qualche MB), ruotare e zoomare 30 s | fluido, nessun artefatto |
| 3.3 | Windows senza driver Vulkan (macchina virtuale o driver base Microsoft): aprire un modello | messaggio con il motivo al posto del modello; il resto dell'app funziona |
| 3.4 | portatile: staccare l'alimentazione / cambiare GPU con un modello aperto | nessun crash; al massimo il modello si ricarica |

## 4. PDF, immagini, office

Dalla cartella del kit (Git Bash su Windows):

```sh
python3 make-test-docs.py docs
bash pdf-check.sh "$P" docs        # PDFium (Windows) / CoreGraphics (macOS)
bash image-check.sh "$P" images    # WIC / ImageIO per HEIC e AVIF
bash office-check.sh "$P" office
```

Tutti devono finire con `tutto ok`. Su Windows senza le estensioni HEIF/AV1 dello
Store, HEIC e AVIF danno un **avviso** col nome dell'estensione da installare:
installarla e ripetere, poi devono passare. Annotare anche le righe dei tempi.

A mano, nella GUI: un PDF vero lungo (centinaia di pagine) sfogliato veloce con
PagSu/PagGiù; una foto HEIC dell'iPhone (macOS e Windows con estensione); una cartella
di foto del telefono con frecce rapide.

## 5. Uso e integrazione col sistema

| # | Prova | Esito atteso |
|---|---|---|
| 5.1 | doppio clic su `.pdf`, `.docx`, `.mp4`, `.heic` (Windows: "Apri con" → Zuer) | si apre in Zuer |
| 5.2 | schermo HiDPI (200%) e un secondo monitor a 100%: spostare la finestra fra i due | testo nitido su entrambi, nessun salto di dimensione |
| 5.3 | navigazione rapida: cartella mista (foto, PDF, office, video), freccia giù tenuta premuta 60 s | nessun blocco, memoria stabile (Gestione attività: annotare all'inizio e alla fine) |
| 5.4 | macOS: download vero del `.tar.gz` col browser, estrazione, primo avvio | Gatekeeper chiede conferma (pacchetto non notarizzato); dopo "Apri" parte |
| 5.5 | Windows: installer scaricato col browser | SmartScreen avvisa (non firmato); installazione e disinstallazione pulite |

## Esito

Riportare le prove in una issue con l'etichetta `prove-hardware`: tabella `# / esito /
note`, la riga d'intestazione (macchina, driver, versione) e i log dei casi falliti
(`ZUER_TRACE=1` per la GUI). Una funzione passa a "testato su hardware fisico" nelle
note di rilascio solo con un giro completo della sua sezione.

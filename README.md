# Zuer

Un visualizzatore di file veloce, scritto in Zig. Apri un file, o una cartella, e lo vedi
subito: documenti, tabelle, immagini, video, audio, modelli 3D e archivi.

Funziona su **Linux**, **Windows** e **macOS** (Apple Silicon e Intel). Versione **0.1.1**:
le novità sono in [RELEASE.md](RELEASE.md).

## Cosa apre

- **Testo e codice**, anche Markdown
- **Tabelle**: CSV, Excel (`.xlsx`), OpenDocument (`.ods`)
- **Documenti**: PDF, Word (`.docx`), PowerPoint (`.pptx`), OpenDocument (`.odt`, `.odp`)
- **Immagini**: PNG, JPEG, WebP, GIF, SVG, HEIC, AVIF, TIFF, RAW delle fotocamere e altre
- **Video e audio**: MP4, MKV, WebM, MOV, AVI, MP3, FLAC, WAV, Ogg, MIDI e molti altri
- **Modelli 3D**: OBJ, STL, glTF/GLB, PLY, FBX
- **Archivi**: ZIP, TAR (anche compressi), 7z, RAR, ISO e altri: ne mostra il contenuto

Il formato si riconosce dal contenuto, anche se l'estensione manca o è sbagliata.
L'elenco completo, con i dettagli per sistema, è in [docs/formati.md](docs/formati.md).

## Scaricare

I pacchetti pronti sono nelle [Release su GitHub](https://github.com/postadelmaga/Zuer/releases):

| Sistema | File |
|---|---|
| macOS con chip Apple (M1, M2…) | `zuer-<versione>-macos-arm64.tar.gz` |
| macOS con processore Intel | `zuer-<versione>-macos-x86_64.tar.gz` |
| Windows 10/11 | `zuer-<versione>-windows-x64-setup.exe` |
| Ubuntu 26.04 LTS | `zuer-<versione>-ubuntu26.04-amd64.deb` (`sudo apt install ./zuer-…deb`) |
| Altre distribuzioni Linux | dai sorgenti (vedi sotto) |

I pacchetti non sono firmati da Apple o Microsoft, quindi al primo avvio il sistema
avvisa. Come aprirli comunque: [RELEASE.md, sezione "Distribuzione"](RELEASE.md#distribuzione).

## Usare

```sh
zuer-gui foto.jpg        # apre un file in una finestra
zuer-gui ~/Immagini/     # apre una cartella: si passa da un file all'altro
zuer tabella.csv         # nel terminale (solo Linux)
```

| Tasto | Cosa fa |
|---|---|
| `↑` `↓` | file precedente o successivo della cartella |
| `←` `→` | pagina nei PDF, ±5 secondi nei video, altrove cambia file |
| rotellina, PagSu/PagGiù | scorre il testo |
| tasto destro tenuto premuto | sposta la finestra |

Su Windows e macOS Zuer compare in "Apri con" senza cambiare le app predefinite. Su
Linux `install.sh` lo rende l'app predefinita per immagini, testo, CSV, Markdown,
modelli 3D e ZIP.

## Compilare su Linux

Servono **Zig 0.17**, `glslc` (shaderc) e il framework [Zicro](../Zicro) nella cartella
accanto (`../Zicro`).

```sh
zig build -Doptimize=ReleaseFast   # compila
./install.sh                       # installa in ~/.local/bin, con le associazioni dei file
./install.sh --uninstall           # disinstalla
```

Dipendenze di sistema, build per Windows e macOS, opzioni e strumenti:
[docs/sviluppo.md](docs/sviluppo.md). Come è fatto dentro: [docs/architettura.md](docs/architettura.md).

## Licenza

Copyright © 2026 Francesco Magazzù. Zuer è software libero sotto **GNU Affero General
Public License v3.0 o successiva** ([LICENSE](LICENSE)). I componenti di terze parti e
le loro licenze: [docs/sviluppo.md](docs/sviluppo.md#componenti-di-terze-parti) per i
sorgenti, [RELEASE.md](RELEASE.md) per i pacchetti.

`SPDX-License-Identifier: AGPL-3.0-or-later`

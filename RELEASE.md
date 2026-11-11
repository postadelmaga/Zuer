# Zuer 1.1.4 — note di rilascio

Versione di correzione, tag `v1.1.4`. Zicro al commit di `.github/zicro.ref` (`main`
di Zicro). Le funzioni, la matrice di parità, le verifiche e i limiti sono quelli della
1.1.0, in [RELEASE-1.1.0.md](RELEASE-1.1.0.md); cosa è cambiato nelle versioni 1.1.1,
1.1.2 e 1.1.3 in [RELEASE-1.1.1.md](RELEASE-1.1.1.md), [RELEASE-1.1.2.md](RELEASE-1.1.2.md)
e [RELEASE-1.1.3.md](RELEASE-1.1.3.md); qui solo cosa cambia. Stesse parole per come è
stato verificato: **verificato** (questa macchina Linux), **CI** (runner GitHub
virtuale), **non verificato**. Su macOS c'è un livello in più: **sotto Darling** (la
build x86_64 eseguita su Linux da Darling, con il suo AppKit Cocotron sopra X11), che
prova il codice di Zuer e Zicro ma non l'AppKit di Apple.

## Cosa cambia rispetto a 1.1.3

### macOS: pacchetto per i Mac Intel

Oltre a quello per Apple Silicon c'è `zuer-1.1.4-macos-x86_64.tar.gz` per i Mac Intel,
con lo stesso contenuto (FFmpeg con VideoToolbox e dav1d, MoltenVK). È compilato e
provato su un runner Intel, con le stesse verifiche del pacchetto arm64. (CI; sotto
Darling, che esegue proprio la build x86_64: PDF, immagini e documenti office)

### macOS: istruzioni per il primo avvio

Da macOS 15 il clic destro → Apri non scavalca più il blocco di Gatekeeper sulle app non
notarizzate: le istruzioni qui sotto ("Distribuzione") ora dicono come aprire Zuer da
Impostazioni di Sistema → Privacy e sicurezza → Apri comunque.

### macOS: più formati, con i componenti del sistema

- **Immagini** con ImageIO: HEIC, JPEG 2000, JPEG XL, OpenEXR, DDS, ICNS, PICT e i RAW
  delle fotocamere (DNG, CR2/CR3, NEF, ARW, ORF, RW2, RAF e altri). Le foto escono
  dritte: ImageIO ne applica l'orientamento EXIF, e decodifica un RAW già ridotto al
  lato che serve. (HEIC e JPEG 2000: CI; gli altri dipendono dalla versione di macOS:
  CI quando il runner li sa generare; orientamento TIFF: sotto Darling)
- **Archivi** col `tar` di sistema (bsdtar): 7z, RAR, ISO, CPIO, XAR/PKG, CAB, RPM, LHA.
  Un archivio danneggiato dà un errore leggibile. (7z, ISO, CPIO, XAR e l'archivio
  danneggiato: CI; 7z, ISO e CPIO anche sotto Darling; RAR, CAB, RPM e LHA: non
  verificato)
- **Documenti** Word `.doc`, RTF e `.webarchive` come testo, con `textutil` di sistema.
  (CI)

### Video e audio: più formati su macOS e Windows

La FFmpeg compilata per i pacchetti apre ora anche WMV/ASF (WMV 1-3, VC-1), FLV, MPEG
program stream (`.mpg`, `.vob`), DV, ProRes, DNxHD, VP6, Cinepak, Indeo, HuffYUV, FFV1,
e in audio WMA, AIFF, CAF, W64, AC-3/E-AC-3, DTS, TrueHD, AMR, WavPack, Monkey's Audio,
Musepack e TTA. (verificato con la stessa configurazione su Linux: 53 casi di
`scripts/ffmpeg-check.sh`; CI su macOS e Windows)

### Archivi `.tar.zst` e `.tar.xz` su tutti i sistemi

zstd e xz si decomprimono dentro Zuer; gli altri formati d'archivio passano dal `tar`
di sistema quando è bsdtar (macOS, Windows 10+; su Linux il pacchetto
`libarchive-tools`). (verificato; test unitario)

### Spostare la finestra col tasto destro

Tenendo premuto il tasto destro in qualunque punto del contenuto la finestra si sposta:
senza bordi né barra del titolo era scomodo su macOS e Windows. Il destro sulle card
della ricerca YouTube e nell'esploratore file fa ancora quello che faceva. (macOS: sotto
Darling; Linux e Windows: non verificato)

### YouTube: qualità Auto e coda "guarda dopo"

- Qualità **Auto** (predefinita): l'altezza segue la finestra, almeno 720p; sale dopo
  1,5 s a una vista più grande (schermo intero) e non scende mai.
- **Coda**: tasto destro o Ctrl+Invio su una card la mette in coda (chip "Coda (N)",
  badge "in coda #n"); a fine video parte il prossimo, `n` lo salta. Si salva fra una
  sessione e l'altra.

(non verificato per questa nota)

### Guida dei tasti

Tenendo premuto `h` compare l'elenco dei tasti sopra qualunque contenuto, su due colonne
se c'è posto; si chiude al rilascio. (non verificato per questa nota)

## Distribuzione

I pacchetti sono costruiti da GitHub Actions (`.github/workflows/release.yml`) al push
del tag e allegati alla release con `SHA256SUMS` e `manifest.json` (versione, commit di
Zuer e Zicro, architettura, sha256).

| Sistema | Architettura | Artefatto |
|---|---|---|
| macOS 13 o successivo | Apple Silicon (arm64) | `zuer-1.1.4-macos-arm64.tar.gz` (`Zuer.app`, con FFmpeg e MoltenVK in `Contents/Frameworks`) |
| macOS 13 o successivo | Intel (x86_64) | `zuer-1.1.4-macos-x86_64.tar.gz` (stesso contenuto, compilato e provato su un Mac Intel) |
| Windows 10/11 | x64 | `zuer-1.1.4-windows-x64-setup.exe` |
| Linux | x64 | dai sorgenti: `zig build` + `install.sh` |

Quale pacchetto macOS: menu Apple → Informazioni su questo Mac. "Chip Apple M…" →
arm64; "Processore Intel…" → x86_64. Il pacchetto Intel non gira sui Mac Apple Silicon
con prestazioni piene (Rosetta) e quello arm64 non gira affatto sui Mac Intel. Non ci
sono pacchetti universali né Windows ARM.

**Verifica del download**: nella cartella dei file scaricati,
`sha256sum -c SHA256SUMS --ignore-missing` (Linux/Git Bash) oppure
`shasum -a 256 -c SHA256SUMS` (macOS); su Windows
`Get-FileHash .\zuer-1.1.4-windows-x64-setup.exe -Algorithm SHA256` e confronto a mano.

**macOS**: estrarre l'archivio e trascinare `Zuer.app` in Applicazioni. Il pacchetto
**non è firmato con un Developer ID né notarizzato** (la firma è solo ad-hoc): al primo
avvio macOS lo blocca dicendo che non può verificarlo. Per aprirlo, una volta sola:

- **macOS 15 Sequoia e successivi**: aprire Zuer, chiudere l'avviso con **Fine**, poi
  Impostazioni di Sistema → **Privacy e sicurezza** → in fondo alla pagina, accanto al
  messaggio su Zuer, **Apri comunque**; confermare con **Apri comunque** e la password
  (o Touch ID). Il clic destro → Apri non basta più da macOS 15.
- **macOS 13 e 14**: clic destro (o Ctrl-clic) su `Zuer.app` → **Apri** → **Apri**.
- Da Terminale, su qualsiasi versione: `xattr -dr com.apple.quarantine /Applications/Zuer.app`.

Dalla seconda volta si apre normalmente, e così i file associati ("Apri con").

PDF con CoreGraphics; immagini (HEIC, AVIF, TIFF, JPEG 2000, RAW…) con ImageIO; archivi
con il `tar` di sistema; `.doc` e `.rtf` con `textutil`; video con FFmpeg LGPL compilata
dal sorgente (VideoToolbox, AV1 software con dav1d); 3D con MoltenVK. Disinstallazione:
cancellare `Zuer.app` (cache in `~/.cache/zuer`).

**Windows**: eseguire l'installer. Installa per l'utente corrente (nessun permesso di
amministratore) in `%LOCALAPPDATA%\Programs\Zuer`, aggiunge il menu Start e "Apri con"
senza cambiare le app predefinite. L'installer **non è firmato**: SmartScreen avvisa
("Ulteriori informazioni" → "Esegui comunque"). Disinstallazione da Impostazioni → App
installate, o `uninstall.exe /S`. PDF con PDFium (`pdfium.dll` inclusa); video con le
DLL FFmpeg incluse (LGPL, compilate dal sorgente, D3D11VA dove la GPU lo consente, AV1 software con dav1d); audio WASAPI. HEIC e AVIF
richiedono le estensioni dello Store "HEIF Image Extensions" + "HEVC Video Extensions"
(HEIC) e "AV1 Video Extension" (AVIF): senza, Zuer dice quale installare. Vulkan non è un requisito: senza driver solo
i modelli 3D non si vedono, con il motivo a schermo.

**Licenze nei pacchetti**: `LICENSE` (AGPL-3.0-or-later); FFmpeg (LGPL) con
`FFmpeg-LICENSE.txt` (comprende dav1d, BSD-2-Clause) e `FFmpeg-SOURCE.txt`
(commit e opzioni di configure: la build si ripete con `scripts/build-ffmpeg.sh`);
`THIRD-PARTY-NOTICES.txt` (libwebp, nanosvg, TinySoundFont, stb);
su Windows PDFium con `PDFium-LICENSE.txt`; su macOS MoltenVK (Apache-2.0) con
`MoltenVK-LICENSE.txt`. Il sorgente di Zuer è il tag `v1.1.4`, quello di Zicro il commit
in `.github/zicro.ref`. La procedura per una nuova versione è in RELEASE-1.0.0.md,
"Fare una nuova versione".

## Licenze dei componenti compilati nei binari

```
Zuer — componenti di terze parti compilati nei binari
=====================================================

Zuer è distribuito sotto AGPL-3.0-or-later (file LICENSE). I binari contengono anche
il codice seguente, con le sue licenze. Le librerie distribuite come file separati
hanno la loro licenza accanto: FFmpeg (FFmpeg-LICENSE.txt, comprende dav1d su macOS),
PDFium su Windows (PDFium-LICENSE.txt), MoltenVK su macOS (MoltenVK-LICENSE.txt).

-------------------------------------------------------------------------------
libwebp 1.5.0 — https://chromium.googlesource.com/webm/libwebp (plugin immagini)
-------------------------------------------------------------------------------
Copyright (c) 2010, Google Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


-------------------------------------------------------------------------------
nanosvg — https://github.com/memononen/nanosvg (plugin immagini)
-------------------------------------------------------------------------------
Copyright (c) 2013-14 Mikko Mononen memon@inside.org

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
claim that you wrote the original software. If you use this software
in a product, an acknowledgment in the product documentation would be
appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.


Il parser SVG di nanosvg è basato sull'esempio SVG di Anti-Grain Geometry 2.4,
Copyright (C) 2002-2004 Maxim Shemanarev (McSeem) (http://www.antigrain.com/).

-------------------------------------------------------------------------------
TinySoundFont e TinyMidiLoader — https://github.com/schellingb/TinySoundFont (MIDI)
-------------------------------------------------------------------------------
Copyright (C) 2017-2025 Bernhard Schelling
Based on SFZero, Copyright (C) 2012 Steve Folta (https://github.com/stevefolta/SFZero)

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
USE OR OTHER DEALINGS IN THE SOFTWARE.

-------------------------------------------------------------------------------
stb_image, stb_truetype — https://github.com/nothings/stb
-------------------------------------------------------------------------------
Usati sotto l'alternativa B della loro doppia licenza (pubblico dominio, Unlicense).
```

# Zuer 0.1.1 — note di rilascio

Tag `v0.1.1`, dopo la 0.1.0 ([RELEASE-0.1.0.md](RELEASE-0.1.0.md)). Zicro al commit di
`.github/zicro.ref`. Stesse parole per come è stato verificato: **verificato** (questa
macchina Linux), **CI** (runner GitHub virtuale), **non verificato**, e **sotto Darling**
(la build macOS x86_64 eseguita su Linux da Darling).

## Cosa cambia rispetto a 0.1.0

### Linux: pacchetto .deb per Ubuntu 26.04 LTS

`zuer-0.1.1-ubuntu26.04-amd64.deb`, costruito su Ubuntu 26.04: le dipendenze sono
quelle della distribuzione (FFmpeg, PipeWire, Vulkan, Wayland…) e `apt` le installa da
sé. Binari e plugin in `/usr/lib/zuer`, `zuer` e `zuer-gui` in `/usr/bin`, Zuer nel
menu delle applicazioni. Non cambia le app predefinite. Senza il decoder VP9 su GPU
(compute_vp9 non è nei repository di Ubuntu): il VP9 passa da FFmpeg, come su macOS e
Windows. Serve una sessione Wayland (quella predefinita di Ubuntu). (CI: costruito,
installato con `apt`, `--version` di entrambi i programmi, nessuna libreria mancante,
rimosso; verificato: costruito e installato in un container Ubuntu 26.04)

### macOS: file con gli accenti aperti dal Finder

Un file con lettere accentate aperto dal Finder ("Apri con", doppio clic, `open -a`)
arrivava con il nome in un'altra forma Unicode (decomposta, `è` = `e` + accento) e
Zuer rispondeva che il file non esisteva. Ora lo ritrova confrontando i nomi della
cartella in forma canonica; se due file diversi sono equivalenti non sceglie e lo dice.
Vale anche per cartelle con accenti, giapponese e coreano. (sotto Darling: 21 casi,
apertura a freddo e con Zuer già aperto)

### Un errore non resta in memoria al posto del file

Se un file non si apriva (per esempio perché non c'era ancora), il messaggio d'errore
restava nella cache delle anteprime e tornava anche dopo, a file presente. Ora gli
errori non entrano mai nella cache. (verificato, sotto Darling)

### Esploratore: i collegamenti si vedono

Nell'esploratore (`e`) e nella navigazione con le frecce i collegamenti simbolici
sparivano. Ora valgono per ciò a cui puntano: una cartella collegata si apre come una
cartella. Un collegamento rotto resta escluso. (verificato; sotto Darling la home di
macOS mostra Download, Desktop e Documenti)

### macOS: video senza decodifica hardware

Su un sistema dove VideoToolbox non decodifica il codec, Zuer passa subito alla
decodifica software invece di provarci. Prima, sotto Darling, aprire un mp4 chiudeva
Zuer. (sotto Darling: un mp4 H.264 si riproduce; non verificato su un Mac, dove H.264 e
HEVC restano in hardware)

## Distribuzione

I pacchetti sono costruiti da GitHub Actions (`.github/workflows/release.yml`) al push
del tag e allegati alla release con `SHA256SUMS` e `manifest.json` (versione, commit di
Zuer e Zicro, architettura, sha256).

| Sistema | Architettura | Artefatto |
|---|---|---|
| macOS 13 o successivo | Apple Silicon (arm64) | `zuer-0.1.1-macos-arm64.tar.gz` (`Zuer.app`, con FFmpeg e MoltenVK in `Contents/Frameworks`) |
| macOS 13 o successivo | Intel (x86_64) | `zuer-0.1.1-macos-x86_64.tar.gz` (stesso contenuto, compilato e provato su un Mac Intel) |
| Windows 10/11 | x64 | `zuer-0.1.1-windows-x64-setup.exe` |
| Ubuntu 26.04 LTS | x64 | `zuer-0.1.1-ubuntu26.04-amd64.deb` |
| Altre distribuzioni Linux | x64 | dai sorgenti: `zig build` + `install.sh` |

Quale pacchetto macOS: menu Apple → Informazioni su questo Mac. "Chip Apple M…" →
arm64; "Processore Intel…" → x86_64. Il pacchetto Intel non gira sui Mac Apple Silicon
con prestazioni piene (Rosetta) e quello arm64 non gira affatto sui Mac Intel. Non ci
sono pacchetti universali né Windows ARM.

**Verifica del download**: nella cartella dei file scaricati,
`sha256sum -c SHA256SUMS --ignore-missing` (Linux/Git Bash) oppure
`shasum -a 256 -c SHA256SUMS` (macOS); su Windows
`Get-FileHash .\zuer-0.1.1-windows-x64-setup.exe -Algorithm SHA256` e confronto a mano.

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

**Ubuntu**: `sudo apt install ./zuer-0.1.1-ubuntu26.04-amd64.deb` (con `./`: apt
installa anche le dipendenze). Il pacchetto non è firmato né in un repository: gli
aggiornamenti si installano allo stesso modo. Disinstallazione: `sudo apt remove zuer`
(cache in `~/.cache/zuer`). Solo Ubuntu 26.04: sulle versioni precedenti le librerie
hanno altri nomi e il pacchetto non si installa.

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
`MoltenVK-LICENSE.txt`. Il sorgente di Zuer è il tag `v0.1.1`, quello di Zicro il commit
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

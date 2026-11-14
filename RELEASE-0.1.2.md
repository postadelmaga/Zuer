# Zuer 0.1.2 — note di rilascio

Tag `v0.1.2`, dopo la 0.1.1 ([RELEASE-0.1.1.md](RELEASE-0.1.1.md)). Zicro al commit di
`.github/zicro.ref`. Stesse parole per come è stato verificato: **verificato** (questa
macchina Linux), **CI** (runner GitHub: per macOS sono Mac veri), **non verificato**, e
**sotto Darling** (la build macOS x86_64 eseguita su Linux da Darling).

## Cosa cambia rispetto a 0.1.1

### Apertura senza salti

Zuer apriva prima una finestra grande e poi la adattava al file. Ora prepara il file
prima di creare la finestra, che compare già della forma giusta e col contenuto pronto.
Se un file richiede più di 0,6 s, la finestra parte su una stima e si adatta dopo,
come prima. Su macOS, aprendo dal Finder, Zuer non mostra più la finestra della
ricerca YouTube che poi diventava quella del file. (verificato su Linux con immagini,
video e PDF; sotto Darling: 21 casi di apertura dal Finder; CI: `open -a` su macOS
arm64 e Intel, finestra nata sul file)

### Informazioni sul file: `i`

Un popup con nome, tipo, risoluzione (dei video quella vera), pagina, durata, righe e
colonne o vertici a seconda del file, peso, data di modifica, cartella e posizione nella
cartella. Si aggiorna mentre si naviga con le frecce; `i` o Esc lo chiudono.
(verificato su immagini, video, PDF e testo)

### Tasti rivisti

- Tolti: `1`…`5` (stile della finestra) e `Ctrl+D`. `h` ora apre e chiude la guida
  (prima andava tenuto premuto).
- Nuovi: `Home`/`Fine` (primo e ultimo file; inizio e fine nei testi; prima e ultima
  pagina nei PDF; nei video `Home` riparte dall'inizio), `Maiusc+←/→` (±30 secondi),
  `1` (pixel reali), `Ctrl+C` fuori dai testi (copia il percorso), `Ctrl+W`/`Ctrl+Q`
  per chiudere (Cmd su macOS).
- `+`, `-` e `?` seguono la tastiera in uso: sulla tastiera italiana lo zoom ora
  funziona.
- Esc chiude prima il popup aperto, poi esce dallo schermo intero, poi chiude Zuer.
  Prima su Linux e Windows ogni Esc chiudeva Zuer, anche dalla ricerca YouTube o
  dentro un archivio.

(verificato su Linux con una tastiera virtuale; non verificato a mano su Windows e macOS)

## Distribuzione

I pacchetti sono costruiti da GitHub Actions (`.github/workflows/release.yml`) al push
del tag e allegati alla release con `SHA256SUMS` e `manifest.json` (versione, commit di
Zuer e Zicro, architettura, sha256).

| Sistema | Architettura | Artefatto |
|---|---|---|
| macOS 13 o successivo | Apple Silicon (arm64) | `zuer-0.1.2-macos-arm64.tar.gz` (`Zuer.app`, con FFmpeg e MoltenVK in `Contents/Frameworks`) |
| macOS 13 o successivo | Intel (x86_64) | `zuer-0.1.2-macos-x86_64.tar.gz` (stesso contenuto, compilato e provato su un Mac Intel) |
| Windows 10/11 | x64 | `zuer-0.1.2-windows-x64-setup.exe` |
| Ubuntu 26.04 LTS | x64 | `zuer-0.1.2-ubuntu26.04-amd64.deb` |
| Altre distribuzioni Linux | x64 | dai sorgenti: `zig build` + `install.sh` |

Quale pacchetto macOS: menu Apple → Informazioni su questo Mac. "Chip Apple M…" →
arm64; "Processore Intel…" → x86_64. Il pacchetto Intel non gira sui Mac Apple Silicon
con prestazioni piene (Rosetta) e quello arm64 non gira affatto sui Mac Intel. Non ci
sono pacchetti universali né Windows ARM.

**Verifica del download**: nella cartella dei file scaricati,
`sha256sum -c SHA256SUMS --ignore-missing` (Linux/Git Bash) oppure
`shasum -a 256 -c SHA256SUMS` (macOS); su Windows
`Get-FileHash .\zuer-0.1.2-windows-x64-setup.exe -Algorithm SHA256` e confronto a mano.

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

**Ubuntu**: `sudo apt install ./zuer-0.1.2-ubuntu26.04-amd64.deb` (con `./`: apt
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
`MoltenVK-LICENSE.txt`. Il sorgente di Zuer è il tag `v0.1.2`, quello di Zicro il commit
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

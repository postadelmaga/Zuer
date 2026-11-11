# Zuer 1.1.3 — note di rilascio

Versione di correzione, tag `v1.1.3`. Zicro al commit di `.github/zicro.ref` (`main`
di Zicro). Le funzioni, la matrice di parità, le verifiche e i limiti sono quelli della
1.1.0, in [RELEASE-1.1.0.md](RELEASE-1.1.0.md); cosa è cambiato nella 1.1.1 e nella
1.1.2 in [RELEASE-1.1.1.md](RELEASE-1.1.1.md) e [RELEASE-1.1.2.md](RELEASE-1.1.2.md);
qui solo cosa cambia. Stesse parole per come è stato verificato: **verificato** (questa
macchina Linux), **CI** (runner GitHub virtuale), **non verificato**. Su macOS c'è un
livello in più: **sotto Darling** (la build x86_64 eseguita su Linux da Darling, con il
suo AppKit Cocotron sopra X11), che prova il codice di Zuer e Zicro ma non l'AppKit di
Apple.

## Cosa cambia rispetto a 1.1.2

### yt-dlp: trovato anche fuori dal PATH, link per scaricarlo

Su macOS un'app aperta dal Finder non vede il PATH della shell, quindi yt-dlp installato
con Homebrew o MacPorts non veniva trovato. Ora si cerca, in ordine: `ZUER_YTDLP`, la
cartella dell'eseguibile (anche col nome `yt-dlp_macos` del binario delle release), il
PATH, poi `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` e `~/.local/bin` (su
Windows i link di WinGet). Si cerca a ogni uso: installandolo con Zuer aperto non serve
riavviare. Se manca, la ricerca YouTube dice come installarlo su quel sistema e mostra
il link alle release di yt-dlp; un clic sulla riga lo apre nel browser. (cartelle e
nomi: test unitario, verificato; macOS: sotto Darling con il `yt-dlp_macos` ufficiale)

### Ricerca YouTube che restava bloccata

Modificare il testo mentre una ricerca era in corso lasciava lo spinner acceso per
sempre e ogni ricerca successiva veniva ignorata. Riguarda tutti i sistemi; si vedeva
dove yt-dlp è lento. (sotto Darling)

### macOS: video YouTube in H.264/HEVC

Su macOS yt-dlp sceglieva AV1 o VP9, che sui Mac Intel e M1/M2 si decodificano in
software (CPU piena). Ora preferisce, a parità di risoluzione, H.264 e HEVC, che
VideoToolbox decodifica in hardware su ogni Mac; `ZUER_HWDEC_CAPS` vale anche su macOS
e Windows. (test unitario; apertura di un video YouTube sotto Darling)

YouTube richiede sempre più spesso a yt-dlp un runtime JavaScript (deno): senza, alcuni
video risultano "non riproducibili". Zuer non lo include.

## Distribuzione

I pacchetti sono costruiti da GitHub Actions (`.github/workflows/release.yml`) al push
del tag e allegati alla release con `SHA256SUMS` e `manifest.json` (versione, commit di
Zuer e Zicro, architettura, sha256).

| Sistema | Architettura | Artefatto |
|---|---|---|
| macOS 13 o successivo | Apple Silicon (arm64) | `zuer-1.1.3-macos-arm64.tar.gz` (`Zuer.app`, con FFmpeg e MoltenVK in `Contents/Frameworks`) |
| Windows 10/11 | x64 | `zuer-1.1.3-windows-x64-setup.exe` |
| Linux | x64 | dai sorgenti: `zig build` + `install.sh` |

Non ci sono pacchetti macOS Intel, universali o Windows ARM.

**Verifica del download**: nella cartella dei file scaricati,
`sha256sum -c SHA256SUMS --ignore-missing` (Linux/Git Bash) oppure
`shasum -a 256 -c SHA256SUMS` (macOS); su Windows
`Get-FileHash .\zuer-1.1.3-windows-x64-setup.exe -Algorithm SHA256` e confronto a mano.

**macOS**: estrarre l'archivio e trascinare `Zuer.app` in Applicazioni. Il pacchetto
**non è firmato con un Developer ID né notarizzato**: al primo avvio Gatekeeper lo
blocca; tasto destro → Apri, oppure `xattr -dr com.apple.quarantine /Applications/Zuer.app`.
La firma è solo ad-hoc. PDF con CoreGraphics; HEIC, AVIF e TIFF con ImageIO; video con
FFmpeg LGPL compilata dal sorgente (VideoToolbox, AV1 software con dav1d); 3D con MoltenVK. Disinstallazione:
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
`MoltenVK-LICENSE.txt`. Il sorgente di Zuer è il tag `v1.1.3`, quello di Zicro il commit
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

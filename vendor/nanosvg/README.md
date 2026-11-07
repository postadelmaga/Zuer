# nanosvg

Parser e rasterizzatore SVG in due header C, compilati nel plugin immagini da
`src/c/image_codecs.c`: il ripiego in processo quando `rsvg-convert` manca (sempre
su Windows e macOS).

- Origine: https://github.com/memononen/nanosvg, commit
  `5cefd9847949af6df13f65027fd43af5a7513633` (2025-11-21)
- Archivio: `https://github.com/memononen/nanosvg/archive/5cefd9847949af6df13f65027fd43af5a7513633.tar.gz`,
  sha256 `01f0892f15c12e364063c07ef643f566372593f60e7010b33707a3804bf74aa1`
- File: `src/nanosvg.h`, `src/nanosvgrast.h`, `LICENSE.txt` (zlib), non modificati.
- Limiti noti di nanosvg: niente testo (`<text>`), filtri, maschere né CSS esterno.

# FFmpeg dev files (Windows cross-compile)

`src/decoders/player.zig` `@cImport`s the libav headers and links libav to decode
video natively. Cross-compiling for Windows needs FFmpeg's headers + import libs.

Committed here (the small build-time deps, ~2.3 MB):
- `include/` — libav{format,codec,util,swscale,swresample} headers.
- `lib/*.lib`  — import libraries (unversioned, so `-lavformat` resolves them to the
  versioned runtime DLLs, e.g. `avformat-63.dll`).

From BtbN FFmpeg-Builds win64 shared, build `N-125444-g6d72600a30` (avformat 63).

The **runtime DLLs are NOT committed** (~130 MB). Like VLC, they ship with the app,
not the source. Fetch them next to the exe with:

    scripts/fetch-ffmpeg-dlls.sh            # → zig-out/bin/

Linux/macOS link the system FFmpeg (pkg-config) and ignore this directory.

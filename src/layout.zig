//! Classificazione del contenuto e geometria iniziale della finestra per zuer-gui:
//! dal percorso/decodifica al `WinKind`, e da lì allo zoom iniziale e alla dimensione
//! della finestra. Sono (quasi) tutte funzioni pure — nessuno stato del viewer — così
//! la logica "che forma dare alla finestra per questo file" sta in un posto solo.

const std = @import("std");
const decoder_mod = @import("decoder.zig");

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Categoria di contenuto che guida proporzioni finestra, zoom e presentazione.
pub const WinKind = enum { image, mesh, document, table, video, generic };

fn extLowerEql(ext: []const u8, comptime lit: []const u8) bool {
    if (ext.len != lit.len) return false;
    for (ext, lit) |c, l| if (std.ascii.toLower(c) != l) return false;
    return true;
}

extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern fn fread(ptr: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern fn fclose(f: *anyopaque) c_int;

pub const ImageDims = struct { w: u32, h: u32 };

/// Dimensioni di un'immagine lette dal solo header (PNG, GIF, BMP, JPEG, WebP
/// VP8X), senza decodificare: bastano per dare alla finestra la forma giusta
/// PRIMA del decode, che così può girare in background anche sui file piccoli.
/// `null` se il formato non è riconosciuto o l'header è incompleto.
pub fn imageDimsFromHeader(bytes: []const u8) ?ImageDims {
    if (bytes.len < 26) return null;
    const rd16be = struct {
        fn f(b: []const u8, i: usize) u32 {
            return (@as(u32, b[i]) << 8) | b[i + 1];
        }
    }.f;
    const rd32be = struct {
        fn f(b: []const u8, i: usize) u32 {
            return std.mem.readInt(u32, b[i..][0..4], .big);
        }
    }.f;
    // PNG: firma 8 byte, poi IHDR con width/height big-endian a 16 e 20.
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        const w = rd32be(bytes, 16);
        const h = rd32be(bytes, 20);
        if (w == 0 or h == 0 or w > 1 << 16 or h > 1 << 16) return null;
        return .{ .w = w, .h = h };
    }
    // GIF: "GIF87a"/"GIF89a" + width/height little-endian u16.
    if (std.mem.startsWith(u8, bytes, "GIF8")) {
        const w = std.mem.readInt(u16, bytes[6..8], .little);
        const h = std.mem.readInt(u16, bytes[8..10], .little);
        if (w == 0 or h == 0) return null;
        return .{ .w = w, .h = h };
    }
    // BMP: "BM", width/height i32 little-endian a 18/22 (altezza negativa = top-down).
    if (std.mem.startsWith(u8, bytes, "BM")) {
        const w = std.mem.readInt(i32, bytes[18..22], .little);
        const h = std.mem.readInt(i32, bytes[22..26], .little);
        if (w <= 0 or h == 0) return null;
        return .{ .w = @intCast(w), .h = @intCast(@abs(h)) };
    }
    // WebP: RIFF....WEBP; solo il container esteso VP8X (24-bit LE - 1).
    if (bytes.len >= 30 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        if (std.mem.eql(u8, bytes[12..16], "VP8X")) {
            const w = 1 + (@as(u32, bytes[24]) | (@as(u32, bytes[25]) << 8) | (@as(u32, bytes[26]) << 16));
            const h = 1 + (@as(u32, bytes[27]) | (@as(u32, bytes[28]) << 8) | (@as(u32, bytes[29]) << 16));
            return .{ .w = w, .h = h };
        }
        return null;
    }
    // JPEG: SOI, poi segmenti marker; le dimensioni stanno nel primo SOFn
    // (0xC0-0xCF esclusi C4/C8/CC) a +5 (altezza) e +7 (larghezza), big-endian.
    if (bytes[0] == 0xFF and bytes[1] == 0xD8) {
        var i: usize = 2;
        while (i + 9 < bytes.len) {
            if (bytes[i] != 0xFF) {
                i += 1;
                continue;
            }
            const m = bytes[i + 1];
            if (m == 0xFF) {
                i += 1;
                continue;
            }
            if (m == 0xD8 or (m >= 0xD0 and m <= 0xD7) or m == 0x01) {
                i += 2;
                continue;
            }
            if (m == 0xD9 or m == 0xDA) return null; // EOI / inizio scansione senza SOF
            const seg_len = rd16be(bytes, i + 2);
            if (m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC) {
                const h = rd16be(bytes, i + 5);
                const w = rd16be(bytes, i + 7);
                if (w == 0 or h == 0) return null;
                return .{ .w = w, .h = h };
            }
            if (seg_len < 2) return null;
            i += 2 + seg_len;
        }
        return null;
    }
    return null;
}

/// Legge i primi `buf.len` byte del file (libc, come i decoder) e ne estrae
/// le dimensioni con `imageDimsFromHeader`. 256 KB bastano anche ai JPEG con
/// blocchi EXIF grandi prima del SOF.
pub fn imageDimsFromFile(gpa: std.mem.Allocator, path: []const u8) ?ImageDims {
    const pz = gpa.dupeSentinel(u8, path, 0) catch return null;
    defer gpa.free(pz);
    const f = fopen(pz.ptr, "rb") orelse return null;
    defer _ = fclose(f);
    const buf = gpa.alloc(u8, 256 * 1024) catch return null;
    defer gpa.free(buf);
    const n = fread(buf.ptr, 1, buf.len, f);
    return imageDimsFromHeader(buf[0..n]);
}

/// Riconoscimento del tipo dall'estensione (percorso async: prima del decode).
pub fn winKindFromExt(path: []const u8) WinKind {
    var clean = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |h| clean = path[0..h];
    const base = std.fs.path.basename(clean);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return .generic;
    const ext = base[dot + 1 ..];
    inline for (.{ "png", "jpg", "jpeg", "gif", "bmp", "webp", "tif", "tiff", "avif", "heic", "ico" }) |e| {
        if (extLowerEql(ext, e)) return .image;
    }
    inline for (.{ "obj", "stl", "glb", "gltf", "ply", "fbx", "dae", "3ds" }) |e| {
        if (extLowerEql(ext, e)) return .mesh;
    }
    inline for (.{ "mp4", "mkv", "webm", "mov", "avi", "m4v", "wmv", "flv", "mpg", "mpeg", "ts" }) |e| {
        if (extLowerEql(ext, e)) return .video;
    }
    // Audio comune: stesso percorso del player nativo (`.video`), ma senza stream
    // video `setupVideo` fallisce e `startVideo` ripiega su `setupAudio` →
    // oscilloscopio. mid/midi restano al loro synth dedicato, fuori da qui.
    inline for (.{ "mp3", "wav", "flac", "ogg", "oga", "opus", "m4a", "aac", "wma", "aiff", "aif" }) |e| {
        if (extLowerEql(ext, e)) return .video;
    }
    inline for (.{ "csv", "tsv", "xlsx", "xls", "ods", "zip", "jar", "apk", "cbz", "epub", "xpi", "whl" }) |e| {
        if (extLowerEql(ext, e)) return .table;
    }
    // I PDF vengono resi come immagine di pagina, ma con proporzioni ritratto.
    if (extLowerEql(ext, "pdf")) return .document;
    return .document; // testo/markdown/codice e sconosciuti: documento (ritratto)
}

pub fn winKindFromDecoded(d: *const decoder_mod.Decoded) WinKind {
    return switch (d.*) {
        .image => .image,
        .mesh => .mesh,
        .csv, .workbook => .table,
        .text, .markdown => .document,
        .err => .generic,
    };
}

/// Zoom iniziale del contenuto per evitare finestre minuscole: se la dimensione
/// naturale del contenuto (tabella/immagine) sarebbe piccola in ENTRAMBE le
/// dimensioni, lo si ingrandisce "un pochino" finché la dimensione vincolante
/// raggiunge una taglia comoda, con un tetto per non sgranare. Ritorna 1.0 dove non
/// ha senso (documento a formato fisso, mesh) o se il contenuto è già abbastanza
/// grande. Il chiamante applica questo zoom al contenuto E dimensiona la finestra
/// sul contenuto già ingrandito, così la finestra resta aderente (nessun vuoto).
pub fn autoZoomForContent(kind: WinKind, nat_w: u32, nat_h: u32) f32 {
    switch (kind) {
        .table, .image, .video => {},
        else => return 1.0,
    }
    if (nat_w == 0 or nat_h == 0) return 1.0;
    const comfort_w: f32 = 680.0;
    const comfort_h: f32 = 480.0;
    const max_zoom: f32 = 1.8;
    const fw: f32 = @floatFromInt(nat_w);
    const fh: f32 = @floatFromInt(nat_h);
    // Solo finestre davvero piccole: se una dimensione è già comoda, non toccare.
    if (fw >= comfort_w or fh >= comfort_h) return 1.0;
    const z = @min(comfort_w / fw, comfort_h / fh);
    return std.math.clamp(z, 1.0, max_zoom);
}

/// Scala una dimensione naturale per un fattore di zoom (arrotonda).
pub fn scaleDim(v: u32, z: f32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * z));
}

/// Dimensione iniziale della finestra, con proporzioni intelligenti per tipo di
/// contenuto. Per le immagini si adatta all'aspetto reale (l'immagine riempie il
/// frame) con un tetto ZUER_MAX_WIN ("LxA", default 1600x900); per gli altri tipi
/// usa proporzioni fisse sensate (ritratto per documenti, largo per tabelle,
/// quadro per mesh).
pub fn initialWindowSize(kind: WinKind, img_w: u32, img_h: u32) struct { w: u32, h: u32 } {
    var max_w: u32 = 1600;
    var max_h: u32 = 900;
    if (getenv("ZUER_MAX_WIN")) |val| {
        const s = std.mem.span(val);
        if (std.mem.indexOfScalar(u8, s, 'x')) |sep| {
            max_w = std.fmt.parseInt(u32, s[0..sep], 10) catch max_w;
            max_h = std.fmt.parseInt(u32, s[sep + 1 ..], 10) catch max_h;
        }
    }

    switch (kind) {
        // Immagini e video: si adattano all'aspetto reale del frame.
        .image, .video => {
            // Aspetto reale noto (percorso sincrono): adatta con tetto.
            if (img_w != 0 and img_h != 0) {
                const fw: f32 = @floatFromInt(img_w);
                const fh: f32 = @floatFromInt(img_h);
                const scale = @min(1.0, @min(@as(f32, @floatFromInt(max_w)) / fw, @as(f32, @floatFromInt(max_h)) / fh));
                const w: u32 = @intFromFloat(@round(fw * scale));
                const h: u32 = @intFromFloat(@round(fh * scale));
                return .{ .w = @max(w, 320), .h = @max(h, 200) };
            }
            // Immagine async (dimensioni ignote finché non è decodificata): landscape.
            return .{ .w = @min(max_w, 1280), .h = @min(max_h, 800) };
        },
        // Documento: al massimo una pagina A4 (ritratto 210:297), capata allo schermo.
        // L'altezza guida; la larghezza segue il rapporto A4, senza sbordare da max_w.
        .document => {
            const a4_h: u32 = @min(max_h, 1123);
            const a4_w: u32 = @min(max_w, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(a4_h)) * 210.0 / 297.0))));
            return .{ .w = a4_w, .h = a4_h };
        },
        // Tabella (csv/xls/zip): dimensiona sulla larghezza reale delle colonne
        // (img_w/img_h = dimensione naturale della griglia), con tetto sullo
        // schermo. Oltre max_w la finestra si ferma e scatta lo scroll orizzontale.
        .table => {
            if (img_w != 0) {
                // Floor bassi: la finestra ADERISCE al contenuto (niente vuoto sotto).
                // Il contenuto minuscolo è già stato ingrandito da `autoZoomForContent`,
                // quindi qui non serve gonfiare la finestra.
                const w = std.math.clamp(img_w, 320, max_w);
                const h = std.math.clamp(img_h, 200, max_h);
                return .{ .w = w, .h = h };
            }
            return .{ .w = @min(max_w, 1280), .h = @min(max_h, 820) };
        },
        // Mesh 3D: viewport quasi quadrato.
        .mesh => return .{ .w = @min(max_w, 1000), .h = @min(max_h, 900) },
        .generic => return .{ .w = 1280, .h = 720 },
    }
}

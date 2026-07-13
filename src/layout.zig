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

//! Guida dei tasti: popup aperto e chiuso da `h` (o F1, `?`), chiuso anche da Esc
//! (`Shared.help`). L'elenco è scritto a mano: va aggiornato insieme a `input.zig`,
//! `yt_search.zig` e `file_explorer.zig` quando cambia un tasto.

const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const paint = zicro.paint;
const glyph = @import("glyph.zig");
const yt_search = @import("yt_search.zig");

const Entry = struct { k: []const u8, d: []const u8 };
const Section = struct { title: []const u8, entries: []const Entry };

/// Il modificatore delle scorciatoie come lo chiama il sistema: Cmd su macOS.
const mod = if (builtin.os.tag == .macos) "⌘" else "Ctrl+";

pub const sections = [_]Section{
    .{ .title = "Generale", .entries = &.{
        .{ .k = "↑ ↓", .d = "file precedente / successivo" },
        .{ .k = "Home  Fine", .d = "primo / ultimo file" },
        .{ .k = "+ -  rotella", .d = "zoom" },
        .{ .k = "0   1", .d = "adatta / pixel reali" },
        .{ .k = "R  Maiusc+R", .d = "ruota" },
        .{ .k = "F", .d = "schermo intero" },
        .{ .k = "i", .d = "informazioni sul file" },
        .{ .k = mod ++ "C", .d = "copia il percorso" },
        .{ .k = mod ++ "P", .d = "stampa (o l'icona in alto)" },
        .{ .k = "e", .d = "esplora file" },
        .{ .k = "y", .d = "cerca su YouTube" },
        .{ .k = "h  ?", .d = "questa guida" },
        .{ .k = "Esc", .d = "chiudi" },
    } },
    .{ .title = "Video e audio", .entries = &.{
        .{ .k = "Spazio", .d = "play / pausa" },
        .{ .k = "← →", .d = "indietro / avanti 5 s" },
        .{ .k = "Maiusc+← →", .d = "indietro / avanti 30 s" },
        .{ .k = "Home", .d = "dall'inizio" },
        .{ .k = "v", .d = "solo audio / video" },
        .{ .k = "c  n  o", .d = "YouTube: sottotitoli, coda, web" },
    } },
    .{ .title = "Testo, PDF, 3D", .entries = &.{
        .{ .k = "PagSu PagGiù", .d = "scorri / pagina" },
        .{ .k = "← →", .d = "pagina (PDF)" },
        .{ .k = "Home  Fine", .d = "inizio / fine" },
        .{ .k = mod ++ "A  " ++ mod ++ "C", .d = "seleziona tutto / copia" },
        .{ .k = "v", .d = "voxel (modelli 3D)" },
        .{ .k = "Invio  Esc", .d = "archivi: apri voce / elenco" },
    } },
    .{ .title = "Ricerca YouTube", .entries = &.{
        .{ .k = "frecce  PagSu PagGiù", .d = "scegli il video" },
        .{ .k = "Invio", .d = "cerca / apri" },
        .{ .k = mod ++ "Invio  destro", .d = "aggiungi / togli dalla coda" },
        .{ .k = mod ++ "A C V", .d = "seleziona / copia / incolla" },
        .{ .k = mod ++ "O", .d = "apri nel browser" },
        .{ .k = "Esc", .d = "chiudi" },
    } },
    .{ .title = "Esplora file", .entries = &.{
        .{ .k = "frecce  Invio", .d = "scegli / apri" },
        .{ .k = "Backspace", .d = "cartella superiore" },
        .{ .k = "e  Esc", .d = "chiudi" },
    } },
};

const panel_bg = paint.Color.rgba(13, 15, 22, 0.97);
const title_fg = [3]u8{ 120, 160, 255 };
const key_fg = [3]u8{ 235, 238, 245 };
const desc_fg = [3]u8{ 150, 158, 175 };

const key_cols = 21; // larghezza della colonna tasti, in caratteri
const desc_cols = 31;

/// Righe di una sezione: titolo, voci e una riga vuota dopo.
fn sectionRows(s: Section) usize {
    return s.entries.len + 2;
}

/// Disegna il popup al centro del frame `W`×`H` (due colonne se c'è posto).
/// Con `shared.mutex` acquisito o comunque fuori da altre scritture del buffer.
pub fn draw(buf: []u8, W: u32, H: u32, raster: *glyph.Raster) void {
    if (W < 200 or H < 160) return;
    const adv = raster.advance;
    const line_h = raster.ascent - raster.descent + 4;
    const pad: i32 = 18;
    const col_w = (key_cols + desc_cols) * adv;
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);

    var total: usize = 0;
    for (sections) |s| total += sectionRows(s);
    const two = 2 * col_w + 3 * pad <= wi - 32;
    // Divisione in due colonne a sezione intera, la prima la più lunga.
    var split: usize = sections.len;
    var rows_a: usize = total;
    if (two) {
        var acc: usize = 0;
        for (sections, 0..) |s, i| {
            if (acc >= (total + 1) / 2) {
                split = i;
                break;
            }
            acc += sectionRows(s);
        }
        rows_a = acc;
    }
    const rows: i32 = @intCast(if (two) @max(rows_a, total - rows_a) else total);
    const pw = @min(wi - 32, if (two) 2 * col_w + 3 * pad else col_w + 2 * pad);
    const ph = @min(hi - 32, rows * line_h + 2 * pad - line_h);
    const px = @divTrunc(wi - pw, 2);
    const py = @divTrunc(hi - ph, 2);

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    canvas.fillRoundedRect(@floatFromInt(px), @floatFromInt(py), @floatFromInt(pw), @floatFromInt(ph), 14.0, panel_bg);

    const y_end = py + ph - pad + line_h;
    var col: i32 = 0;
    var y = py + pad;
    for (sections, 0..) |s, si| {
        if (two and si == split) {
            col = 1;
            y = py + pad;
        }
        const x = px + pad + col * (col_w + pad);
        const max_w = px + pw - pad - x;
        if (y + line_h <= y_end) _ = yt_search.drawText(buf, W, H, raster, x, y + raster.ascent, s.title, title_fg, max_w);
        y += line_h;
        for (s.entries) |e| {
            if (y + line_h > y_end) break;
            _ = yt_search.drawText(buf, W, H, raster, x, y + raster.ascent, e.k, key_fg, @min(max_w, (key_cols - 1) * adv));
            _ = yt_search.drawText(buf, W, H, raster, x + key_cols * adv, y + raster.ascent, e.d, desc_fg, max_w - key_cols * adv);
            y += line_h;
        }
        y += line_h;
    }
}

// Ogni voce sta nelle sue colonne (controllato in compilazione).
comptime {
    @setEvalBranchQuota(100_000);
    for (sections) |s| for (s.entries) |e| {
        if ((std.unicode.utf8CountCodepoints(e.k) catch unreachable) >= key_cols) @compileError("tasto troppo lungo: " ++ e.k);
        if ((std.unicode.utf8CountCodepoints(e.d) catch unreachable) > desc_cols) @compileError("descrizione troppo lunga: " ++ e.d);
    };
}

//! Compositing CPU dei frame di zuer-gui: dalla sorgente rasterizzata (testo,
//! immagine, tabella, frame mesh/video) al buffer RGBA della finestra. Immagini in
//! aspect-fit con zoom/pan (`composeFrame`), testo blittato 1:1 con scroll e header
//! ancorato (`composeTextFrame`), più la selezione testo, la barra linguette e la
//! geometria del blit condivisa (`textBlitGeom`) che tiene allineati compose,
//! selezione e hit-test. Tutte funzioni pure su buffer + parametri: nessuno stato
//! del viewer, così la matematica del compositing sta in un modulo solo.

const std = @import("std");
const text_render = @import("text_render.zig");

/// Numero massimo di linguette di cui teniamo i confini per l'hit-test. Fogli
/// oltre questo limite si disegnano ma non sono cliccabili (workbook enormi).
pub const max_tabs: usize = 64;

/// Barra delle linguette dei fogli (solo workbook): immagine RGBA pronta al blit
/// in fondo alla finestra + confini X di ogni linguetta per l'hit-test dei click.
/// Rigenerata da `rasterizeTabBar` a ogni cambio foglio/larghezza.
pub const TabBarState = struct {
    rgba: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    bounds: [max_tabs]u32 = [_]u32{0} ** max_tabs,
    count: usize = 0,
};

/// Alpha-blend src-over di un colore sul pixel RGBA in `buf[idx..]`.
fn blendPixel(buf: []u8, idx: usize, r: u8, g: u8, b: u8, a: u8) void {
    const af: u32 = a;
    const inv: u32 = 255 - af;
    buf[idx + 0] = @intCast((@as(u32, r) * af + @as(u32, buf[idx + 0]) * inv) / 255);
    buf[idx + 1] = @intCast((@as(u32, g) * af + @as(u32, buf[idx + 1]) * inv) / 255);
    buf[idx + 2] = @intCast((@as(u32, b) * af + @as(u32, buf[idx + 2]) * inv) / 255);
    buf[idx + 3] = @max(buf[idx + 3], a);
}

/// Blitta la barra delle linguette (RGBA opaca) in fondo alla finestra, sopra il
/// contenuto, per i workbook multi-foglio. Ritagliata a W×tb.h.
pub fn blitTabBar(buf: []u8, W: u32, H: u32, tb: *const TabBarState) void {
    if (tb.count == 0 or tb.h == 0 or tb.h > H or tb.w == 0) return;
    const y0 = H - tb.h;
    const copy_w = @min(tb.w, W);
    var ty: u32 = 0;
    while (ty < tb.h) : (ty += 1) {
        const dst_row = (y0 + ty) * W * 4;
        const src_row = ty * tb.w * 4;
        @memcpy(buf[dst_row .. dst_row + copy_w * 4], tb.rgba[src_row .. src_row + copy_w * 4]);
        // Larghezza finestra > barra (transitorio in resize): riempi a nero il resto.
        if (copy_w < W) @memset(buf[dst_row + copy_w * 4 .. dst_row + W * 4], 0);
    }
}

/// Geometria del blit del testo nella finestra: offset di scroll (clampato) e
/// centratura orizzontale. Condivisa da compose, selezione e hit-test per non
/// divergere.
pub const BlitGeom = struct { off_y: u32, x_dst: u32, x_src: u32, copy_w: u32 };
pub fn textBlitGeom(W: u32, H: u32, src_w: u32, src_h: u32, scroll_y: f32, scroll_x: f32) BlitGeom {
    const max_scroll: u32 = if (src_h > H) src_h - H else 0;
    const max_scroll_x: u32 = if (src_w > W) src_w - W else 0;
    return .{
        .off_y = @min(@as(u32, @intFromFloat(@max(scroll_y, 0))), max_scroll),
        // Più stretta della finestra → centrata. Più larga → si scorre in
        // orizzontale (x_src = offset di scroll, partendo da sinistra).
        .x_dst = if (src_w < W) (W - src_w) / 2 else 0,
        .x_src = if (src_w > W) @min(@as(u32, @intFromFloat(@max(scroll_x, 0))), max_scroll_x) else 0,
        .copy_w = @min(src_w, W),
    };
}

/// Modalità documento per i contenuti testuali: l'immagine è già rasterizzata alla
/// larghezza della finestra, quindi si blitta 1:1 (nessun ricampionamento che
/// sfocherebbe il testo), ancorata in alto, con scorrimento verticale. `header_h` è
/// l'altezza (px) della banda d'intestazione da tenere ANCORATA in cima mentre il
/// corpo scorre (header tabella); 0 = nessun ancoraggio. L'header scorre comunque in
/// ORIZZONTALE col corpo, così le colonne restano allineate.
pub fn composeTextFrame(
    composited_rgba: []u8,
    W: u32,
    H: u32,
    src_rgba: []const u8,
    src_w: u32,
    src_h: u32,
    scroll_y: f32,
    scroll_x: f32,
    header_h: u32,
) void {
    const geom = textBlitGeom(W, H, src_w, src_h, scroll_y, scroll_x);
    const off_y = geom.off_y;
    const x_dst = geom.x_dst;
    const x_src = geom.x_src;
    const copy_w = geom.copy_w;

    var py: u32 = 0;
    while (py < H) : (py += 1) {
        const idx_row = py * W * 4;
        // Banda header ancorata: campiona la riga sorgente 1:1 (senza off_y); il
        // corpo sotto scorre normalmente. `off_y` è già clampato a src_h - H, e
        // l'altezza scrollabile utile resta invariata, quindi il clamp è corretto
        // anche con l'ancoraggio (l'ultima riga dati resta raggiungibile).
        const sy = if (py < header_h) py else py + off_y;

        if (sy >= src_h or copy_w == 0) {
            @memset(composited_rgba[idx_row .. idx_row + W * 4], 0);
            continue;
        }

        // Clear left margin
        if (x_dst > 0) {
            @memset(composited_rgba[idx_row .. idx_row + x_dst * 4], 0);
        }

        // Copia + color-key a word: ogni pixel è una word u32 (byte order R,G,B,A,
        // entrambi i buffer allineati a 4). Se RGB == la key (8,8,16) l'alpha va a
        // 0 (resta vetro), altrimenti la word passa invariata — un confronto e una
        // scrittura per pixel invece di 4 letture + 4 scritture byte.
        const key_rgb: u32 = 8 | (8 << 8) | (16 << 16); // R,G,B della key; alpha ignorato
        const dst_words: [*]u32 = @ptrCast(@alignCast(composited_rgba.ptr + idx_row + x_dst * 4));
        const src_words: [*]const u32 = @ptrCast(@alignCast(src_rgba.ptr + (sy * src_w + x_src) * 4));
        var px: u32 = 0;
        while (px < copy_w) : (px += 1) {
            const w = src_words[px];
            dst_words[px] = if ((w & 0x00FF_FFFF) == key_rgb) (w & 0x00FF_FFFF) else w;
        }

        // Clear right margin
        if (x_dst + copy_w < W) {
            @memset(composited_rgba[idx_row + (x_dst + copy_w) * 4 .. idx_row + W * 4], 0);
        }
    }
}

const sel_color = [3]u8{ 70, 110, 190 };
const sel_alpha: u8 = 96;

/// Numero di codepoint (= colonne monospazio) in una riga UTF-8.
pub fn cpLen(s: []const u8) i32 {
    var n: i32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(@as(usize, seq), s.len - i);
        n += 1;
    }
    return n;
}

/// Evidenzia la selezione (stream: dalla colonna d'ancora, righe intere in
/// mezzo, fino all'estremo) con rettangoli translucidi sulla griglia monospazio.
pub fn drawTextSelection(buf: []u8, W: u32, H: u32, src_w: u32, src_h: u32, scroll_y: f32, scroll_x: f32, m: text_render.Metrics, lines: []const []const u8, a_in: [2]i32, b_in: [2]i32) void {
    if (lines.len == 0 or m.advance <= 0 or m.line_h <= 0) return;
    const geom = textBlitGeom(W, H, src_w, src_h, scroll_y, scroll_x);
    var a = a_in;
    var b = b_in;
    if (a[0] > b[0] or (a[0] == b[0] and a[1] > b[1])) {
        const t = a;
        a = b;
        b = t;
    }
    const nrows: i32 = @intCast(lines.len);
    const Wi: i32 = @intCast(W);
    const Hi: i32 = @intCast(H);
    const dx: i32 = @as(i32, @intCast(geom.x_dst)) - @as(i32, @intCast(geom.x_src));
    var row: i32 = @max(a[0], 0);
    while (row <= b[0] and row < nrows) : (row += 1) {
        const llen = cpLen(lines[@intCast(row)]);
        var c0: i32 = if (row == a[0]) a[1] else 0;
        var c1: i32 = if (row == b[0]) b[1] else llen;
        c0 = std.math.clamp(c0, 0, llen);
        c1 = std.math.clamp(c1, 0, llen);
        if (c1 <= c0) continue;
        const x0 = m.pad_x + c0 * m.advance + dx;
        const x1 = m.pad_x + c1 * m.advance + dx;
        const y0 = m.pad_y + row * m.line_h - @as(i32, @intCast(geom.off_y));
        const xa: u32 = @intCast(std.math.clamp(x0, 0, Wi));
        const xb: u32 = @intCast(std.math.clamp(x1, 0, Wi));
        const ya: u32 = @intCast(std.math.clamp(y0, 0, Hi));
        const yb: u32 = @intCast(std.math.clamp(y0 + m.line_h, 0, Hi));
        var py = ya;
        while (py < yb) : (py += 1) {
            var px = xa;
            while (px < xb) : (px += 1) {
                blendPixel(buf, (py * W + px) * 4, sel_color[0], sel_color[1], sel_color[2], sel_alpha);
            }
        }
    }
}

const row_hl_color = [3]u8{ 70, 110, 190 };
const row_hl_alpha: u8 = 80;

/// Evidenzia a tutta larghezza la riga selezionata di una tabella-archivio.
/// Stessa geometria di `drawTextSelection`: la riga dati `sel_row` è la linea
/// `1 + sel_row` (la linea 0 è l'header). Non dipinge sotto la banda header
/// pinnata (`header_band`). Overlay economico: nessuna ri-rasterizzazione.
pub fn drawTableRowHighlight(buf: []u8, W: u32, H: u32, src_w: u32, src_h: u32, scroll_y: f32, scroll_x: f32, m: text_render.Metrics, sel_row: i32, header_band: u32) void {
    if (m.line_h <= 0 or sel_row < 0) return;
    const geom = textBlitGeom(W, H, src_w, src_h, scroll_y, scroll_x);
    const Hi: i32 = @intCast(H);
    const line_idx: i32 = 1 + sel_row; // riga 0 = header
    const y0 = m.pad_y + line_idx * m.line_h - @as(i32, @intCast(geom.off_y));
    const top: i32 = @max(y0, @as(i32, @intCast(header_band)));
    const ya: u32 = @intCast(std.math.clamp(top, 0, Hi));
    const yb: u32 = @intCast(std.math.clamp(y0 + m.line_h, 0, Hi));
    var py = ya;
    while (py < yb) : (py += 1) {
        var px: u32 = 0;
        while (px < W) : (px += 1) {
            blendPixel(buf, (py * W + px) * 4, row_hl_color[0], row_hl_color[1], row_hl_color[2], row_hl_alpha);
        }
    }
}

/// Compositing di un'immagine (o frame mesh/video) in aspect-fit a tutto schermo con
/// zoom e pan, campionamento nearest a virgola fissa. `is_text` tratta il colore di
/// fondo del testo (8,8,16) come trasparente.
pub fn composeFrame(
    composited_rgba: []u8,
    W: u32,
    H: u32,
    src_rgba: []const u8,
    src_w: u32,
    src_h: u32,
    is_text: bool,
    zoom: f32,
    pan_x: f32,
    pan_y: f32,
) void {
    // Sorgente vuota (es. video non apribile → dims 0): riempi lo sfondo e
    // basta — l'aspect 0/0 darebbe NaN e il panic di @intFromFloat qui sotto.
    if (src_w == 0 or src_h == 0) {
        @memset(composited_rgba[0 .. @as(usize, H) * W * 4], 0);
        return;
    }

    // Calcolo dell'aspect ratio per l'adattamento (aspect-fit) a tutto schermo
    const src_aspect = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(src_h));
    const win_aspect = @as(f32, @floatFromInt(W)) / @as(f32, @floatFromInt(H));

    var fit_w: u32 = 0;
    var fit_h: u32 = 0;
    if (src_aspect > win_aspect) {
        fit_w = W;
        fit_h = @intFromFloat(@round(@as(f32, @floatFromInt(W)) / src_aspect));
    } else {
        fit_h = H;
        fit_w = @intFromFloat(@round(@as(f32, @floatFromInt(H)) * src_aspect));
    }
    fit_w = @max(fit_w, 1);
    fit_h = @max(fit_h, 1);

    const zoomed_w = @as(f32, @floatFromInt(fit_w)) * zoom;
    const zoomed_h = @as(f32, @floatFromInt(fit_h)) * zoom;

    const fit_w_zoomed = @max(@as(u32, @intFromFloat(zoomed_w)), 1);
    const fit_h_zoomed = @max(@as(u32, @intFromFloat(zoomed_h)), 1);

    const fit_x = @divFloor(@as(i32, @intCast(W)) - @as(i32, @intCast(fit_w_zoomed)), 2) + @as(i32, @intFromFloat(pan_x));
    const fit_y = @divFloor(@as(i32, @intCast(H)) - @as(i32, @intCast(fit_h_zoomed)), 2) + @as(i32, @intFromFloat(pan_y));

    const start_x: u32 = @intCast(@max(@as(i32, 0), fit_x));
    const end_x: u32 = @intCast(@max(@as(i32, 0), @min(@as(i32, @intCast(W)), fit_x + @as(i32, @intCast(fit_w_zoomed)))));
    const start_y: u32 = @intCast(@max(@as(i32, 0), fit_y));
    const end_y: u32 = @intCast(@max(@as(i32, 0), @min(@as(i32, @intCast(H)), fit_y + @as(i32, @intCast(fit_h_zoomed)))));

    // Clear top rows
    if (start_y > 0) {
        @memset(composited_rgba[0 .. start_y * W * 4], 0);
    }

    // Clear bottom rows
    if (end_y < H) {
        @memset(composited_rgba[end_y * W * 4 .. H * W * 4], 0);
    }

    if (start_x >= end_x or start_y >= end_y) {
        var py = start_y;
        while (py < end_y) : (py += 1) {
            @memset(composited_rgba[py * W * 4 .. (py + 1) * W * 4], 0);
        }
        return;
    }

    const inv_w = (@as(u64, src_w) << 32) / fit_w_zoomed;
    const inv_h = (@as(u64, src_h) << 32) / fit_h_zoomed;

    // Loop caldo per-pixel (ricampionamento del frame ogni present): gli indici sono
    // già clampati (`@min` con src_w-1/src_h-1), quindi disattiviamo i controlli di
    // sicurezza runtime così anche la build ReleaseSafe scala alla velocità di
    // ReleaseFast — determinante per reggere i 30/60 fps del video senza scatti.
    @setRuntimeSafety(false);

    // Color-key del percorso testo (rgb 8,8,16 → alpha 0), come word LE:
    // low-24 = r | g<<8 | b<<16.
    const key_low24: u32 = 8 | (8 << 8) | (16 << 16);

    var py = start_y;
    while (py < end_y) : (py += 1) {
        const idx_row = py * W * 4;

        // Clear left margin of the row
        if (start_x > 0) {
            @memset(composited_rgba[idx_row .. idx_row + start_x * 4], 0);
        }

        // Clear right margin of the row
        if (end_x < W) {
            @memset(composited_rgba[idx_row + end_x * 4 .. idx_row + W * 4], 0);
        }

        const ry = @as(u64, @intCast(@as(i32, @intCast(py)) - fit_y));
        const sy = @min(@as(u32, @intCast((ry * inv_h) >> 32)), src_h - 1);
        const s_row_offset = sy * src_w;

        const start_rx = @as(u64, @intCast(@as(i32, @intCast(start_x)) - fit_x));
        var rx_fp = start_rx * inv_w;

        // Ricampionamento a WORD u32 (un load/store per pixel, non 4 byte) col
        // branch color-key issato FUORI dal loop; scala orizzontale 1:1 → la
        // riga sorgente è contigua e diventa un solo memcpy (è il caso mesh:
        // il frame GPU ha già le dimensioni della finestra).
        const row_px = end_x - start_x;
        const dst_bytes = composited_rgba[idx_row + start_x * 4 ..][0 .. row_px * 4];
        if (!is_text and inv_w == (@as(u64, 1) << 32)) {
            const sx0 = @min(@as(u32, @intCast(rx_fp >> 32)), src_w - 1);
            if (sx0 + row_px <= src_w) {
                const s_off = (@as(usize, s_row_offset) + sx0) * 4;
                @memcpy(dst_bytes, src_rgba[s_off..][0 .. row_px * 4]);
                continue;
            }
        }
        if (is_text) {
            var i: usize = 0;
            while (i < row_px) : (i += 1) {
                const sx = @min(@as(u32, @intCast(rx_fp >> 32)), src_w - 1);
                rx_fp += inv_w;
                var w32 = std.mem.readInt(u32, src_rgba[(@as(usize, s_row_offset) + sx) * 4 ..][0..4], .little);
                if (w32 & 0x00FF_FFFF == key_low24) w32 &= 0x00FF_FFFF; // alpha 0, rgb intatti
                std.mem.writeInt(u32, dst_bytes[i * 4 ..][0..4], w32, .little);
            }
        } else {
            var i: usize = 0;
            while (i < row_px) : (i += 1) {
                const sx = @min(@as(u32, @intCast(rx_fp >> 32)), src_w - 1);
                rx_fp += inv_w;
                const w32 = std.mem.readInt(u32, src_rgba[(@as(usize, s_row_offset) + sx) * 4 ..][0..4], .little);
                std.mem.writeInt(u32, dst_bytes[i * 4 ..][0..4], w32, .little);
            }
        }
    }
}

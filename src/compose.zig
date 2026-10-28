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
    rgba: []align(4) u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    bounds: [max_tabs]u32 = @splat(0),
    count: usize = 0,
};

/// Alpha-blend src-over di un colore sul pixel RGBA in `buf[idx..]` (alpha
/// straight; il canale alpha resta il massimo tra esistente e copertura).
/// Condiviso da selezione/evidenziazione, etichette (gui.zig) e controlli video.
pub fn blendPixel(buf: []u8, idx: usize, r: u8, g: u8, b: u8, a: u8) void {
    if (a == 0) return;
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
    composited_rgba: []align(4) u8,
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
    // Solo le righe che intersecano DAVVERO il viewport: fuori da qui i
    // rettangoli sarebbero clampati a zero, ma `cpLen` scandirebbe comunque la
    // riga — su un "seleziona tutto" di 12k righe è il costo dominante.
    const off_i: i32 = @intCast(geom.off_y);
    const first_vis: i32 = @divFloor(off_i - m.pad_y, m.line_h);
    const last_vis: i32 = @divFloor(off_i + Hi - m.pad_y, m.line_h);
    var row: i32 = @max(a[0], @max(first_vis, 0));
    const row_last: i32 = @min(b[0], @min(last_vis, nrows - 1));
    while (row <= row_last) : (row += 1) {
        const llen = cpLen(lines[@intCast(row)]);
        var c0: i32 = if (row == a[0]) a[1] else 0;
        var c1: i32 = if (row == b[0]) b[1] else llen;
        c0 = std.math.clamp(c0, 0, llen);
        c1 = std.math.clamp(c1, 0, llen);
        if (c1 <= c0) continue;
        const content_pad_x = m.pad_x + m.gutter_cols * m.advance;
        const x0 = content_pad_x + c0 * m.advance + dx;
        const x1 = content_pad_x + c1 * m.advance + dx;
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

/// Ruota un buffer RGBA di `quarter_turns` quarti di giro in senso orario e
/// ritorna un NUOVO buffer (dimensioni scambiate per 1 e 3 quarti). Lossless:
/// ogni pixel di destinazione legge esattamente un pixel sorgente. Usato dal
/// tasto R su immagini e pagine PDF (`static_rgba`).
pub fn rotateRgba(gpa: std.mem.Allocator, src: []const u8, w: u32, h: u32, quarter_turns: u2) ![]align(4) u8 {
    const dst = try gpa.alignedAlloc(u8, .@"4", @as(usize, w) * h * 4);
    errdefer gpa.free(dst);
    if (quarter_turns == 0) {
        @memcpy(dst, src[0..dst.len]);
        return dst;
    }
    const dw: u32 = if (quarter_turns == 2) w else h;
    const dh: u32 = if (quarter_turns == 2) h else w;
    const src_px: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, src[0 .. @as(usize, w) * h * 4]));
    const dst_px: []u32 = @alignCast(std.mem.bytesAsSlice(u32, dst));
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const drow = dst_px[@as(usize, dy) * dw ..][0..dw];
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            // Mappa (dx,dy) della destinazione ruotata sul pixel sorgente.
            const sx: u32, const sy: u32 = switch (quarter_turns) {
                1 => .{ dy, h - 1 - dx }, // 90° orario
                2 => .{ w - 1 - dx, h - 1 - dy }, // 180°
                3 => .{ w - 1 - dy, dx }, // 270° orario (= 90° antiorario)
                0 => unreachable,
            };
            drow[dx] = src_px[@as(usize, sy) * w + sx];
        }
    }
    return dst;
}

/// Catena mip dell'immagine statica: livello 0 = il buffer sorgente (NON
/// posseduto), i successivi sono riduzioni box-filter 2× possedute. `composeFrame`
/// campiona bilineare dal livello più vicino alla scala di presentazione, così le
/// foto ridotte nella finestra non mostrano aliasing/shimmer (nearest solo oltre
/// 4× di ingrandimento, dove i pixel sono l'informazione). Ricostruita pigramente
/// quando il buffer sorgente cambia (`ensure`); ~1/3 della memoria dell'immagine.
pub const MipChain = struct {
    const max_levels = 8;
    levels: [max_levels][]const u8 = @splat(&[_]u8{}),
    ws: [max_levels]u32 = @splat(0),
    hs: [max_levels]u32 = @splat(0),
    n: u8 = 0,
    src_ptr: ?[*]const u8 = null,

    /// (Ri)costruisce la catena se `src` (puntatore/dimensioni) è cambiato.
    pub fn ensure(self: *MipChain, gpa: std.mem.Allocator, src: []const u8, w: u32, h: u32) void {
        if (self.src_ptr) |p| {
            if (p == src.ptr and self.ws[0] == w and self.hs[0] == h) return;
        }
        self.release(gpa);
        if (w == 0 or h == 0 or src.len < @as(usize, w) * h * 4) return;
        self.levels[0] = src;
        self.ws[0] = w;
        self.hs[0] = h;
        self.n = 1;
        self.src_ptr = src.ptr;
        while (self.n < max_levels) {
            const pw = self.ws[self.n - 1];
            const ph = self.hs[self.n - 1];
            // Sotto i 512 px un ulteriore livello non serve a nessuna finestra reale.
            if (pw < 512 and ph < 512) break;
            const nw = pw / 2;
            const nh = ph / 2;
            if (nw == 0 or nh == 0) break;
            const buf = gpa.alloc(u8, @as(usize, nw) * nh * 4) catch break;
            downsample2x(self.levels[self.n - 1], pw, buf, nw, nh);
            self.levels[self.n] = buf;
            self.ws[self.n] = nw;
            self.hs[self.n] = nh;
            self.n += 1;
        }
    }

    /// Libera i livelli posseduti (≥ 1); il livello 0 appartiene al chiamante.
    pub fn release(self: *MipChain, gpa: std.mem.Allocator) void {
        var i: usize = 1;
        while (i < self.n) : (i += 1) gpa.free(self.levels[i]);
        self.n = 0;
        self.src_ptr = null;
    }

    pub fn deinit(self: *MipChain, gpa: std.mem.Allocator) void {
        self.release(gpa);
    }
};

/// Riduzione 2× a media di blocchi 2×2 (box filter), RGBA8.
fn downsample2x(src: []const u8, sw: u32, dst: []u8, dw: u32, dh: u32) void {
    @setRuntimeSafety(false);
    const stride: usize = @as(usize, sw) * 4;
    var y: u32 = 0;
    while (y < dh) : (y += 1) {
        const r0 = @as(usize, y) * 2 * stride;
        const r1 = r0 + stride;
        var x: u32 = 0;
        while (x < dw) : (x += 1) {
            const c0 = r0 + @as(usize, x) * 8;
            const c1 = r1 + @as(usize, x) * 8;
            const o = (@as(usize, y) * dw + x) * 4;
            inline for (0..4) |k| {
                dst[o + k] = @intCast((@as(u32, src[c0 + k]) + src[c0 + 4 + k] + src[c1 + k] + src[c1 + 4 + k] + 2) >> 2);
            }
        }
    }
}

/// Compositing di un'immagine (o frame mesh/video) in aspect-fit a tutto schermo con
/// zoom e pan. Copre SEMPRE l'intero buffer W×H (margini azzerati riga per riga): il
/// chiamante non deve pulirlo prima. Con `mips` (catena costruita su `src_rgba`)
/// campiona bilineare dal livello mip più vicino alla scala; senza, bilineare sul
/// sorgente; nearest a scala 1:1 esatta (memcpy) e oltre 4× di ingrandimento.
pub fn composeFrame(
    composited_rgba: []align(4) u8,
    W: u32,
    H: u32,
    src_rgba: []const u8,
    src_w: u32,
    src_h: u32,
    zoom: f32,
    pan_x: f32,
    pan_y: f32,
    mips: ?*const MipChain,
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

    // Inizio e fine clampati a [0, W/H]: con un pan che porta l'immagine del
    // tutto fuori dal viewport (il pan è normalmente clampato a monte, ma qui
    // non ci si fida) il frame resta un rettangolo vuoto, mai un OOB.
    const start_x: u32 = @intCast(std.math.clamp(fit_x, 0, @as(i32, @intCast(W))));
    const end_x: u32 = @intCast(std.math.clamp(fit_x + @as(i32, @intCast(fit_w_zoomed)), 0, @as(i32, @intCast(W))));
    const start_y: u32 = @intCast(std.math.clamp(fit_y, 0, @as(i32, @intCast(H))));
    const end_y: u32 = @intCast(std.math.clamp(fit_y + @as(i32, @intCast(fit_h_zoomed)), 0, @as(i32, @intCast(H))));

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

    // Livello mip: il più piccolo che sia ancora ≥ della taglia di presentazione
    // (così il bilineare lavora tra scala 0.5 e 1, dove è un vero filtro).
    var src = src_rgba;
    var sw = src_w;
    var sh = src_h;
    if (mips) |mc| {
        if (mc.n > 0 and mc.src_ptr == src_rgba.ptr) {
            var li: usize = 0;
            while (li + 1 < mc.n and mc.ws[li + 1] >= fit_w_zoomed and mc.hs[li + 1] >= fit_h_zoomed) : (li += 1) {}
            src = mc.levels[li];
            sw = mc.ws[li];
            sh = mc.hs[li];
        }
    }

    const inv_w = (@as(u64, sw) << 32) / fit_w_zoomed;
    const inv_h = (@as(u64, sh) << 32) / fit_h_zoomed;
    const exact = inv_w == (@as(u64, 1) << 32) and inv_h == (@as(u64, 1) << 32);
    const scale = @as(f32, @floatFromInt(fit_w_zoomed)) / @as(f32, @floatFromInt(sw));
    const bilinear = !exact and scale < 4.0;

    // Loop caldo per-pixel (ricampionamento del frame ogni present): gli indici sono
    // già clampati (`@min` con sw-1/sh-1), quindi disattiviamo i controlli di
    // sicurezza runtime così anche la build ReleaseSafe scala alla velocità di
    // ReleaseFast — determinante per reggere i 30/60 fps del video senza scatti.
    @setRuntimeSafety(false);

    const row_px = end_x - start_x;
    const start_rx = @as(u64, @intCast(@as(i32, @intCast(start_x)) - fit_x));

    if (bilinear) {
        // Bilineare a virgola fissa 32.32: centro del pixel destinazione → coordinate
        // sorgente continue (−0.5 per allineare i centri), 4 texel pesati con frazioni
        // a 8 bit. Clamp ai bordi (niente wrap).
        const half: i64 = 1 << 31;
        var py = start_y;
        while (py < end_y) : (py += 1) {
            const idx_row = py * W * 4;
            if (start_x > 0) @memset(composited_rgba[idx_row .. idx_row + start_x * 4], 0);
            if (end_x < W) @memset(composited_rgba[idx_row + end_x * 4 .. idx_row + W * 4], 0);

            const ry = @as(u64, @intCast(@as(i32, @intCast(py)) - fit_y));
            var sy_fp: i64 = @as(i64, @intCast((ry * 2 + 1) * inv_h / 2)) - half;
            if (sy_fp < 0) sy_fp = 0;
            const y0: u32 = @min(@as(u32, @intCast(sy_fp >> 32)), sh - 1);
            const y1: u32 = @min(y0 + 1, sh - 1);
            const wy: u32 = @intCast((sy_fp >> 24) & 0xFF);
            const row0 = src[@as(usize, y0) * sw * 4 ..];
            const row1 = src[@as(usize, y1) * sw * 4 ..];
            const dst_bytes = composited_rgba[idx_row + start_x * 4 ..][0 .. row_px * 4];

            var sx_fp: i64 = @as(i64, @intCast((start_rx * 2 + 1) * inv_w / 2)) - half;
            const step: i64 = @intCast(inv_w);
            var i: usize = 0;
            while (i < row_px) : (i += 1) {
                const sxc: i64 = if (sx_fp < 0) 0 else sx_fp;
                const x0: u32 = @min(@as(u32, @intCast(sxc >> 32)), sw - 1);
                const x1: u32 = @min(x0 + 1, sw - 1);
                const wx: u32 = @intCast((sxc >> 24) & 0xFF);
                const a = row0[@as(usize, x0) * 4 ..][0..4];
                const b = row0[@as(usize, x1) * 4 ..][0..4];
                const c = row1[@as(usize, x0) * 4 ..][0..4];
                const d = row1[@as(usize, x1) * 4 ..][0..4];
                inline for (0..4) |k| {
                    const top = @as(u32, a[k]) * (256 - wx) + @as(u32, b[k]) * wx;
                    const bot = @as(u32, c[k]) * (256 - wx) + @as(u32, d[k]) * wx;
                    dst_bytes[i * 4 + k] = @intCast((top * (256 - wy) + bot * wy) >> 16);
                }
                sx_fp += step;
            }
        }
        return;
    }

    // Nearest: 1:1 esatto (memcpy di riga) o ingrandimento ≥ 4× (pixel-art).
    // Righe di destinazione consecutive che mappano sulla stessa riga sorgente
    // producono byte identici: si copia la riga precedente invece di ricampionarla.
    var prev_sy: u32 = std.math.maxInt(u32);
    var prev_row_off: usize = 0;

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
        const sy = @min(@as(u32, @intCast((ry * inv_h) >> 32)), sh - 1);
        const s_row_offset = sy * sw;

        const dst_off = idx_row + start_x * 4;
        const dst_bytes = composited_rgba[dst_off..][0 .. row_px * 4];
        if (sy == prev_sy) {
            @memcpy(dst_bytes, composited_rgba[prev_row_off..][0 .. row_px * 4]);
            continue;
        }
        prev_sy = sy;
        prev_row_off = dst_off;

        var rx_fp = start_rx * inv_w;

        // Scala orizzontale 1:1 → la riga sorgente è contigua e diventa un solo
        // memcpy (è il caso mesh/video: il frame ha già le dimensioni del fit-rect).
        if (inv_w == (@as(u64, 1) << 32)) {
            const sx0 = @min(@as(u32, @intCast(rx_fp >> 32)), sw - 1);
            if (sx0 + row_px <= sw) {
                const s_off = (@as(usize, s_row_offset) + sx0) * 4;
                @memcpy(dst_bytes, src[s_off..][0 .. row_px * 4]);
                continue;
            }
        }
        var i: usize = 0;
        while (i < row_px) : (i += 1) {
            const sx = @min(@as(u32, @intCast(rx_fp >> 32)), sw - 1);
            rx_fp += inv_w;
            const w32 = std.mem.readInt(u32, src[(@as(usize, s_row_offset) + sx) * 4 ..][0..4], .little);
            std.mem.writeInt(u32, dst_bytes[i * 4 ..][0..4], w32, .little);
        }
    }
}

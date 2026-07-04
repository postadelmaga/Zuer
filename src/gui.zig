//! zuer-gui — viewer GPU a finestra basato su zrame.
//!
//! Decodifica il file con gli stessi plugin di zuer, poi presenta in una
//! finestra Wayland zrame: le mesh sono rasterizzate dal renderer Vulkan
//! offscreen condiviso (`gpu_renderer.zig`), le immagini e testi sono
//! compositati a CPU; il frame finale RGBA viene inviato a zrame per la presentazione.

const std = @import("std");
const gpu = @import("gpu_renderer.zig");
const voxel = @import("voxel.zig");
const decoder_mod = @import("decoder.zig");
const loader_mod = @import("loader.zig");
const text_render = @import("text_render.zig");
const zrame = @import("zrame");
const zicro = @import("zicro");

// evdev key codes standard per Linux
const KEY_ESC: u32 = 1;
const KEY_UP: u32 = 103;
const KEY_DOWN: u32 = 108;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_PGUP: u32 = 104;
const KEY_PGDOWN: u32 = 109;
const KEY_MINUS: u32 = 12;
const KEY_EQUAL: u32 = 13;
const KEY_1: u32 = 2;
const KEY_2: u32 = 3;
const KEY_3: u32 = 4;
const KEY_4: u32 = 5;
const KEY_5: u32 = 6;
const KEY_C: u32 = 46;
const KEY_V: u32 = 47;
const KEY_F: u32 = 33;
const KEY_LEFTCTRL: u32 = 29;
const KEY_RIGHTCTRL: u32 = 97;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_RIGHTSHIFT: u32 = 54;

// Il testo viene ri-rasterizzato al pointsize scalato: oltre questi limiti la
// resa degrada (corpo minuscolo) o esplode in memoria (immagini enormi).
const text_zoom_min: f32 = 0.4;
const text_zoom_max: f32 = 6.0;
const scroll_step: f32 = 60.0;
const scrollbar_w: u32 = 14; // larghezza della scrollbar del testo (px)
const scroll_ease: f32 = 0.35; // frazione di avvicinamento a scroll_target per frame

/// Numero massimo di linguette di cui teniamo i confini per l'hit-test. Fogli
/// oltre questo limite si disegnano ma non sono cliccabili (workbook enormi).
const max_tabs: usize = 64;

/// Barra delle linguette dei fogli (solo workbook): immagine RGBA pronta al blit
/// in fondo alla finestra + confini X di ogni linguetta per l'hit-test dei click.
/// Rigenerata da `rasterizeText` a ogni cambio foglio/larghezza.
const TabBarState = struct {
    rgba: []u8 = &.{},
    w: u32 = 0,
    h: u32 = 0,
    bounds: [max_tabs]u32 = [_]u32{0} ** max_tabs,
    count: usize = 0,
};

/// Geometria del cursore (thumb) della scrollbar verticale: altezza ∝ frazione
/// visibile, posizione ∝ scorrimento. `off_y` è l'offset di scroll già clampato.
fn scrollbarThumb(H: u32, src_h: u32, off_y: u32) struct { y: u32, h: u32 } {
    if (src_h <= H) return .{ .y = 0, .h = H };
    const max_scroll = src_h - H;
    const min_h: u32 = 32;
    const prop: u64 = @as(u64, H) * H / src_h;
    const th: u32 = @min(H, @as(u32, @intCast(@max(@as(u64, min_h), prop))));
    const travel = H - th;
    const y: u32 = if (max_scroll > 0) @intCast(@as(u64, off_y) * travel / max_scroll) else 0;
    return .{ .y = y, .h = th };
}

/// Alpha-blend src-over di un colore sul pixel RGBA in `buf[idx..]`.
fn blendPixel(buf: []u8, idx: usize, r: u8, g: u8, b: u8, a: u8) void {
    const af: u32 = a;
    const inv: u32 = 255 - af;
    buf[idx + 0] = @intCast((@as(u32, r) * af + @as(u32, buf[idx + 0]) * inv) / 255);
    buf[idx + 1] = @intCast((@as(u32, g) * af + @as(u32, buf[idx + 1]) * inv) / 255);
    buf[idx + 2] = @intCast((@as(u32, b) * af + @as(u32, buf[idx + 2]) * inv) / 255);
    buf[idx + 3] = @max(buf[idx + 3], a);
}

/// Disegna la scrollbar verticale (traccia + cursore) sul bordo destro. Appare
/// solo quando il contenuto è più alto della viewport.
fn drawScrollbar(buf: []u8, W: u32, H: u32, src_h: u32, off_y: u32) void {
    if (src_h <= H or W < scrollbar_w) return;
    const x0 = W - scrollbar_w;
    const t = scrollbarThumb(H, src_h, off_y);
    var py: u32 = 0;
    while (py < H) : (py += 1) {
        const on_thumb = py >= t.y and py < t.y + t.h;
        var px: u32 = x0;
        while (px < W) : (px += 1) {
            const idx = (py * W + px) * 4;
            if (px == x0) {
                blendPixel(buf, idx, 90, 96, 112, 60); // sottile bordo interno
            } else if (on_thumb) {
                blendPixel(buf, idx, 150, 158, 178, 240);
            } else {
                blendPixel(buf, idx, 32, 34, 44, 90);
            }
        }
    }
}

/// Geometria del cursore orizzontale (specchio di scrollbarThumb sull'asse X).
fn hscrollThumb(W: u32, src_w: u32, off_x: u32) struct { x: u32, w: u32 } {
    if (src_w <= W) return .{ .x = 0, .w = W };
    const max_scroll = src_w - W;
    const min_w: u32 = 32;
    const prop: u64 = @as(u64, W) * W / src_w;
    const tw: u32 = @min(W, @as(u32, @intCast(@max(@as(u64, min_w), prop))));
    const travel = W - tw;
    const x: u32 = if (max_scroll > 0) @intCast(@as(u64, off_x) * travel / max_scroll) else 0;
    return .{ .x = x, .w = tw };
}

/// Scrollbar orizzontale sul bordo inferiore: appare solo quando il contenuto è
/// più largo della viewport (es. tabella con molte colonne).
fn drawHScrollbar(buf: []u8, W: u32, H: u32, src_w: u32, off_x: u32) void {
    if (src_w <= W or H < scrollbar_w) return;
    const y0 = H - scrollbar_w;
    const t = hscrollThumb(W, src_w, off_x);
    var py: u32 = y0;
    while (py < H) : (py += 1) {
        var px: u32 = 0;
        while (px < W) : (px += 1) {
            const on_thumb = px >= t.x and px < t.x + t.w;
            const idx = (py * W + px) * 4;
            if (py == y0) {
                blendPixel(buf, idx, 90, 96, 112, 60);
            } else if (on_thumb) {
                blendPixel(buf, idx, 150, 158, 178, 240);
            } else {
                blendPixel(buf, idx, 32, 34, 44, 90);
            }
        }
    }
}

/// Blitta la barra delle linguette (RGBA opaca) in fondo alla finestra, sopra il
/// contenuto, per i workbook multi-foglio. Ritagliata a W×tb.h.
fn blitTabBar(buf: []u8, W: u32, H: u32, tb: *const TabBarState) void {
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

/// Modalità documento per i contenuti testuali: l'immagine è già rasterizzata
/// alla larghezza della finestra, quindi si blitta 1:1 (nessun ricampionamento
/// che sfocherebbe il testo), ancorata in alto, con scorrimento verticale.
/// Geometria del blit del testo nella finestra: offset di scroll (clampato) e
/// centratura orizzontale. Condivisa da compose, selezione e scrollbar per non
/// divergere.
const BlitGeom = struct { off_y: u32, x_dst: u32, x_src: u32, copy_w: u32 };
fn textBlitGeom(W: u32, H: u32, src_w: u32, src_h: u32, scroll_y: f32, scroll_x: f32) BlitGeom {
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

fn composeTextFrame(
    composited_rgba: []u8,
    W: u32,
    H: u32,
    src_rgba: []const u8,
    src_w: u32,
    src_h: u32,
    scroll_y: f32,
    scroll_x: f32,
    // Altezza (px) della banda d'intestazione da tenere ANCORATA in cima mentre
    // il corpo scorre: le righe [0, header_h) mostrano sempre le righe sorgente
    // [0, header_h) (l'header della tabella), non scrollate. 0 = nessun ancoraggio
    // (testo/codice/markdown). L'header scorre comunque in ORIZZONTALE col corpo,
    // così le colonne restano allineate.
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

        // Copy and process middle part
        var px: u32 = 0;
        const s_row_offset = sy * src_w;
        while (px < copy_w) : (px += 1) {
            const dest_idx = idx_row + (x_dst + px) * 4;
            const src_idx = (s_row_offset + x_src + px) * 4;

            const sr = src_rgba[src_idx + 0];
            const sg = src_rgba[src_idx + 1];
            const sb = src_rgba[src_idx + 2];
            var sa = src_rgba[src_idx + 3];

            if (sr == 8 and sg == 8 and sb == 16) {
                sa = 0;
            }

            composited_rgba[dest_idx + 0] = sr;
            composited_rgba[dest_idx + 1] = sg;
            composited_rgba[dest_idx + 2] = sb;
            composited_rgba[dest_idx + 3] = sa;
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
fn cpLen(s: []const u8) i32 {
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
fn drawTextSelection(buf: []u8, W: u32, H: u32, src_w: u32, src_h: u32, scroll_y: f32, scroll_x: f32, m: text_render.Metrics, lines: []const []const u8, a_in: [2]i32, b_in: [2]i32) void {
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

/// Mappa una coordinata finestra in (riga, colonna) sulla griglia del testo,
/// clampata al documento. Da chiamare con `state.mutex` acquisito.
fn textHit(state: *GuiAppState, W: u32, H: u32, mx: f32, my: f32) [2]i32 {
    const m = state.text_metrics.*;
    const geom = textBlitGeom(W, H, state.static_w.*, state.static_h.*, state.scroll_y.*, state.scroll_x.*);
    const sx = @as(i32, @intFromFloat(mx)) - @as(i32, @intCast(geom.x_dst)) + @as(i32, @intCast(geom.x_src));
    const sy = @as(i32, @intFromFloat(my)) + @as(i32, @intCast(geom.off_y));
    const nrows: i32 = @intCast(state.text_lines.items.len);
    var row: i32 = if (m.line_h > 0) @divFloor(sy - m.pad_y, m.line_h) else 0;
    row = std.math.clamp(row, 0, @max(nrows - 1, 0));
    const llen: i32 = if (nrows > 0) cpLen(state.text_lines.items[@intCast(row)]) else 0;
    // Arrotonda alla colonna più vicina (mezza cella) per un aggancio naturale.
    var col: i32 = if (m.advance > 0) @divFloor(sx - m.pad_x + @divTrunc(m.advance, 2), m.advance) else 0;
    col = std.math.clamp(col, 0, llen);
    return .{ row, col };
}

fn composeFrame(
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

        var px = start_x;
        while (px < end_x) : (px += 1) {
            const idx = idx_row + px * 4;
            const sx = @min(@as(u32, @intCast(rx_fp >> 32)), src_w - 1);
            rx_fp += inv_w;

            const s_idx = (s_row_offset + sx) * 4;

            const sr = src_rgba[s_idx + 0];
            const sg = src_rgba[s_idx + 1];
            const sb = src_rgba[s_idx + 2];
            var sa = src_rgba[s_idx + 3];

            if (is_text and sr == 8 and sg == 8 and sb == 16) {
                sa = 0;
            }

            composited_rgba[idx + 0] = sr;
            composited_rgba[idx + 1] = sg;
            composited_rgba[idx + 2] = sb;
            composited_rgba[idx + 3] = sa;
        }
    }
}

/// Un file già decodificato (e, se mesh, già "staged" su memfd) tenuto in cache
/// dal thread di prefetch, pronto per uno swap istantaneo alla navigazione.
/// Lo staging è pura CPU/memfd (`stageToGpu`), NON tocca il renderer Vulkan.
const Prefetched = struct {
    decoded: decoder_mod.Decoded,
    stage: ?loader_mod.GpuStage = null,

    fn deinit(self: *Prefetched, gpa: std.mem.Allocator) void {
        self.decoded.deinit(gpa);
        if (self.stage) |*s| s.buffer.deinit(gpa);
    }
};

const GuiAppState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    // Finestra zrame, impostata dopo la sua creazione. Serve alla navigazione per
    // ridimensionare (con animazione) la finestra sulla dimensione del contenuto.
    win: ?*zrame.Window = null,

    // Protegge lo stato condiviso tra thread finestra (callback input,
    // loadFile) e thread di rendering (rasterizzazione testo, compose).
    mutex: *std.Io.Mutex,

    // Stato file
    current_file_path: []const u8,
    file_list: std.ArrayList([]const u8),
    current_file_index: ?usize,

    // Variabili Zicro/Loader
    decoded: *decoder_mod.Decoded,
    stage_opt: *?loader_mod.GpuStage,
    renderer: *gpu.Renderer,
    // Motore di resa testo: false = CPU (composizione diretta), true = atlante
    // GPU (ZUER_TEXT_ENGINE=gpu). Stessa resa, percorso diverso.
    text_gpu: bool,

    // Variabili di stato rendering
    is_mesh: *bool,
    is_text: *bool,
    // Vero per le tabelle (csv/xls/ods...): abilita l'ancoraggio dell'header di
    // colonna durante lo scroll verticale (vedi `composeTextFrame`).
    is_table: *bool,
    // Barra delle linguette dei fogli (solo workbook multi-foglio).
    tab_bar: *TabBarState,
    file_changed: *bool,
    // Vero mentre il decoder del file iniziale gira su un thread di background:
    // il worker mostra lo spinner di caricamento invece del contenuto.
    loading: *bool,
    // Incrementato a ogni load: il worker ri-rasterizza il testo solo quando
    // cambiano file, larghezza o zoom — mai per un semplice scroll.
    load_seq: *u32,
    zoom: *f32,
    static_rgba: *[]u8,
    static_w: *u32,
    static_h: *u32,
    mesh_center: *[3]f32,
    mesh_max_size: *f32,
    mesh_material: *gpu.Material,
    // Modalità voxel (tasto V): ray-march della griglia voxel invece della mesh.
    voxel_mode: *bool,
    voxel_bbox_min: *[3]f32,
    voxel_bbox_size: *[3]f32,
    voxel_dim: *u32,

    // Stato di trascinamento, scroll documento e rotazione 3D
    dragging: *bool,
    yaw: *f32,
    pitch: *f32,
    pan_x: *f32,
    pan_y: *f32,
    scroll_y: *f32,
    // Posizione di scroll desiderata: la rotella/i tasti la muovono, il worker
    // fa scorrere scroll_y verso di essa con easing (scroll fluido).
    scroll_target: *f32,
    // Scroll orizzontale (tabelle più larghe della finestra): posizione corrente
    // + meta, con lo stesso easing dell'asse Y.
    scroll_x: *f32,
    scroll_target_x: *f32,
    // Trascinamento del cursore della scrollbar (mappa mouse.y → posizione).
    scrollbar_drag: *bool,
    last_x: *f32,
    last_y: *f32,

    // Selezione testo (solo percorso CPU): testo semplice per riga visiva e
    // metriche della griglia monospazio per l'hit-testing; ancora/estremo della
    // selezione in coordinate (riga, colonna).
    text_lines: *std.ArrayList([]const u8),
    text_metrics: *text_render.Metrics,
    sel_active: *bool,
    sel_selecting: *bool,
    sel_a: *[2]i32,
    sel_b: *[2]i32,
    // Stato del tasto Ctrl (per Ctrl+C = copia negli appunti).
    ctrl_down: *bool,
    // Stato del tasto Shift (Shift+rotella = scroll orizzontale).
    shift_down: *bool,

    // --- Prefetch dei file adiacenti (navigazione istantanea) -----------------
    // Un thread di background decodifica (e stage-a, se mesh) i vicini del file
    // corrente in `pf_cache`. Alla freccia lo swap è immediato se già in cache;
    // altrimenti si ricade sul decode sincrono. Il thread NON tocca mai il
    // renderer (solo decode+stage: CPU/memfd) → nessun accesso Vulkan da più
    // thread. `applyDecoded` (unico a toccare il renderer) resta sul thread main.
    pf_mutex: *std.Io.Mutex,
    pf_cond: *std.Io.Condition,
    pf_cache: *std.StringHashMapUnmanaged(Prefetched),
    pf_want: *[2]?[]u8, // percorsi (posseduti) dei vicini da tenere in cache
    pf_stop: *bool, // protetto da pf_mutex

    /// Estrae dalla cache il file già decodificato per `path` (e lo rimuove),
    /// oppure `null` se non pronto. Chiamato dal thread main alla navigazione.
    fn cacheTake(self: *GuiAppState, path: []const u8) ?Prefetched {
        self.pf_mutex.lockUncancelable(self.io);
        defer self.pf_mutex.unlock(self.io);
        if (self.pf_cache.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
            return kv.value;
        }
        return null;
    }

    /// Imposta i due vicini da tenere in cache (duplica i percorsi) e sveglia il
    /// thread di prefetch. `null` = nessun vicino su quel lato.
    fn requestPrefetch(self: *GuiAppState, a: ?[]const u8, b: ?[]const u8) void {
        self.pf_mutex.lockUncancelable(self.io);
        for (self.pf_want, [2]?[]const u8{ a, b }) |*slot, want| {
            if (slot.*) |old| self.gpa.free(old);
            slot.* = if (want) |w| (self.gpa.dupe(u8, w) catch null) else null;
        }
        self.pf_mutex.unlock(self.io);
        self.pf_cond.signal(self.io);
    }

    /// Programma il prefetch dei file immediatamente prima/dopo quello corrente
    /// nella lista della cartella. No-op per liste ≤1 o indice ignoto.
    fn schedulePrefetchAround(self: *GuiAppState) void {
        const idx = self.current_file_index orelse return;
        const n = self.file_list.items.len;
        if (n <= 1) return;
        const dir_path = std.fs.path.dirname(self.current_file_path);
        const prev_i = if (idx == 0) n - 1 else idx - 1;
        const next_i = (idx + 1) % n;
        var buf: [2]?[]u8 = .{ null, null };
        for (&buf, [2]usize{ prev_i, next_i }) |*out, i| {
            if (i == idx) continue; // liste di 2: prev==next==self va evitato
            const filename = self.file_list.items[i];
            out.* = if (dir_path) |dp|
                std.fs.path.join(self.gpa, &.{ dp, filename }) catch null
            else
                self.gpa.dupe(u8, filename) catch null;
        }
        defer for (buf) |p| if (p) |x| self.gpa.free(x);
        self.requestPrefetch(buf[0], buf[1]);
    }

    fn loadFile(self: *GuiAppState, new_path: []const u8) !void {
        // 1. Decodifica il nuovo file (fuori dal lock: non tocca stato condiviso)
        var new_decoded = decoder_mod.decode(new_path, self.io, self.gpa);
        if (new_decoded == .err) {
            std.debug.print("Errore nel caricamento del file {s}: {s}\n", .{ new_path, new_decoded.err });
            new_decoded.deinit(self.gpa);
            return;
        }
        try self.applyDecoded(new_decoded, null, new_path);
    }

    /// Installa un contenuto già decodificato nello stato condiviso (swap sotto
    /// lock). Prende possesso di `new_decoded` e, se presente, di `stage_override`
    /// (staging GPU già calcolato dal prefetch: evita di ricalcolarlo qui).
    /// Condiviso da `loadFile`, dal thread di decodifica iniziale (spinner) e dal
    /// percorso di navigazione con cache-hit. DEVE girare sul thread main:
    /// `setMesh` tocca il renderer Vulkan (serializzato con il render worker).
    fn applyDecoded(self: *GuiAppState, new_decoded: decoder_mod.Decoded, stage_override: ?loader_mod.GpuStage, new_path: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Ferma lo spinner: da qui in poi la finestra mostra il contenuto (o
        // l'errore) invece del caricamento. Prima dello staging che può fallire,
        // così lo spinner si ferma comunque.
        self.loading.* = false;

        // 2. Libera le vecchie risorse decodificate
        self.decoded.deinit(self.gpa);
        if (self.stage_opt.*) |*s| {
            s.buffer.deinit(self.gpa);
            self.stage_opt.* = null;
        }

        // 3. Aggiorna decoded
        self.decoded.* = new_decoded;

        // 4. Aggiorna percorso file corrente
        self.gpa.free(self.current_file_path);
        self.current_file_path = try self.gpa.dupe(u8, new_path);

        // 5. Aggiorna flag tipo
        self.is_mesh.* = self.decoded.* == .mesh;
        self.is_text.* = (self.decoded.* != .mesh and self.decoded.* != .image);
        self.is_table.* = self.decoded.* == .csv or self.decoded.* == .workbook;

        // Il prefetch prepara lo staging solo per le mesh: se per qualsiasi motivo
        // arriva uno stage per un non-mesh, liberalo qui (solo il ramo mesh lo usa).
        if (!self.is_mesh.*) {
            if (stage_override) |s| {
                var st = s;
                st.buffer.deinit(self.gpa);
            }
        }

        // 6. Aggiorna i dati per GPU/CPU. I contenuti testuali non vengono
        // rasterizzati qui: lo fa il thread di rendering alla larghezza
        // corrente della finestra, per una resa 1:1 nitida.
        if (self.is_mesh.*) {
            const m = self.decoded.mesh;
            // Se il prefetch ha già preparato il buffer, riusalo (niente ricalcolo
            // di normali/tangenti qui, sul thread main): swap istantaneo.
            self.stage_opt.* = if (stage_override) |s| s else (loader_mod.stageToGpu(self.gpa, self.decoded) orelse return error.StageFailed);
            const stage = &self.stage_opt.*.?;
            try self.renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
            try self.renderer.setMeshMaterials(&m);
            self.mesh_center.* = m.center;
            self.mesh_max_size.* = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
            self.mesh_material.* = .{ .base_color = m.base_color, .metallic = m.metallic, .roughness = m.roughness };
            // Nuova mesh: invalida la griglia voxel (verrà rigenerata al tasto V).
            self.voxel_mode.* = false;
            self.voxel_dim.* = 0;
        } else if (self.decoded.* == .image) {
            const img = self.decoded.image;
            self.gpa.free(self.static_rgba.*);
            self.static_rgba.* = &.{};
            self.static_w.* = @intCast(img.width);
            self.static_h.* = @intCast(img.height);
            self.static_rgba.* = try self.gpa.alloc(u8, self.static_w.* * self.static_h.* * 4);
            for (0..self.static_w.* * self.static_h.*) |i| {
                self.static_rgba.*[i * 4 + 0] = img.pixels[i * 3 + 0];
                self.static_rgba.*[i * 4 + 1] = img.pixels[i * 3 + 1];
                self.static_rgba.*[i * 4 + 2] = img.pixels[i * 3 + 2];
                self.static_rgba.*[i * 4 + 3] = 255;
            }
        } else {
            self.gpa.free(self.static_rgba.*);
            self.static_rgba.* = &.{};
            self.static_w.* = 0;
            self.static_h.* = 0;
        }

        self.zoom.* = 1.0;
        self.yaw.* = 0.0;
        self.pitch.* = 0.0;
        self.pan_x.* = 0.0;
        self.pan_y.* = 0.0;
        self.scroll_y.* = 0.0;
        self.scroll_target.* = 0.0;
        self.scroll_x.* = 0.0;
        self.scroll_target_x.* = 0.0;
        freeTextLines(self);
        self.sel_active.* = false;
        self.sel_selecting.* = false;
        self.load_seq.* +%= 1;
        self.file_changed.* = true;
    }

    fn initFileList(self: *GuiAppState) !void {
        const dir_path = std.fs.path.dirname(self.current_file_path) orelse ".";
        var dir = try std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true });
        defer dir.close(self.io);

        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind == .file) {
                try self.file_list.append(self.gpa, try self.gpa.dupe(u8, entry.name));
            }
        }

        std.mem.sort([]const u8, self.file_list.items, {}, struct {
            fn compare(context: void, a: []const u8, b: []const u8) bool {
                _ = context;
                return std.mem.order(u8, a, b) == .lt;
            }
        }.compare);

        const cur_filename = std.fs.path.basename(self.current_file_path);
        self.current_file_index = null;
        for (self.file_list.items, 0..) |f, idx| {
            if (std.mem.eql(u8, f, cur_filename)) {
                self.current_file_index = idx;
                break;
            }
        }
    }

    fn navigate(self: *GuiAppState, direction: i2) void {
        if (self.file_list.items.len <= 1) return;
        const current_idx = self.current_file_index orelse return;

        var next_idx: usize = 0;
        if (direction > 0) {
            next_idx = (current_idx + 1) % self.file_list.items.len;
        } else {
            if (current_idx == 0) {
                next_idx = self.file_list.items.len - 1;
            } else {
                next_idx = current_idx - 1;
            }
        }

        const dir_path = std.fs.path.dirname(self.current_file_path);
        const filename = self.file_list.items[next_idx];
        const new_path = if (dir_path) |dp|
            std.fs.path.join(self.gpa, &.{ dp, filename }) catch return
        else
            self.gpa.dupe(u8, filename) catch return;
        defer self.gpa.free(new_path);

        self.current_file_index = next_idx;

        // Cache-hit: il vicino è già decodificato (e staged) → swap istantaneo.
        // Cache-miss (scroll più veloce del prefetch): fallback al decode sincrono.
        if (self.cacheTake(new_path)) |pf| {
            self.applyDecoded(pf.decoded, pf.stage, new_path) catch |err|
                std.debug.print("Impossibile applicare il file (cache): {s}\n", .{@errorName(err)});
        } else {
            self.loadFile(new_path) catch |err| {
                std.debug.print("Impossibile caricare il file: {s}\n", .{@errorName(err)});
                return;
            };
        }

        // Contenuto nuovo installato: ridimensiona la finestra sulla forma del
        // contenuto (stessa euristica del sizing iniziale) con un'animazione.
        self.resizeToContent();

        // Precarica i nuovi vicini per rendere istantanea la prossima freccia.
        self.schedulePrefetchAround();
    }

    /// Ridimensiona (con animazione) la finestra sulla forma del contenuto
    /// appena caricato, usando la stessa euristica del sizing iniziale
    /// (`initialWindowSize`): immagini adattate all'aspetto reale con tetto,
    /// tabelle sulla larghezza naturale delle colonne, documenti/mesh con
    /// proporzioni fisse sensate. No-op finché la finestra non esiste.
    fn resizeToContent(self: *GuiAppState) void {
        const win = self.win orelse return;
        // Snapshot delle dimensioni naturali sotto lock (il render worker legge
        // `decoded`/`static_*` concorrentemente): le immagini hanno static_w/h
        // note, le tabelle richiedono la misura naturale della griglia.
        self.mutex.lockUncancelable(self.io);
        const kind = winKindFromDecoded(self.decoded);
        var nat_w: u32 = 0;
        var nat_h: u32 = 0;
        switch (kind) {
            .image => {
                nat_w = self.static_w.*;
                nat_h = self.static_h.*;
            },
            .table => {
                const opts0 = text_render.RenderOpts{ .width = 1280, .pointsize = 15 };
                const csv0: ?decoder_mod.CsvData = switch (self.decoded.*) {
                    .csv => |c| c,
                    .workbook => |w| w.activeCsv(),
                    else => null,
                };
                if (csv0) |c| {
                    if (text_render.tableNaturalSize(self.gpa, c, opts0)) |ns| {
                        nat_w = @intCast(ns.w);
                        nat_h = @intCast(ns.h);
                    } else |_| {}
                }
            },
            // Documenti/mesh/generic: proporzioni fisse (nat_w/h = 0 → default).
            else => {},
        }
        self.mutex.unlock(self.io);

        const size = initialWindowSize(kind, nat_w, nat_h);
        win.animateResize(size.w, size.h);
    }
};

fn applyZoom(app_state: *GuiAppState, factor: f32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    app_state.zoom.* = std.math.clamp(app_state.zoom.* * factor, 0.1, 20.0);
    app_state.file_changed.* = true;
}

fn scrollText(app_state: *GuiAppState, delta: f32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    // Muove la meta di scroll: il worker vi fa scorrere scroll_y con easing
    // (scroll fluido). Il limite superiore dipende dall'altezza rasterizzata,
    // nota al worker; qui basta impedire i valori negativi.
    app_state.scroll_target.* = @max(app_state.scroll_target.* + delta, 0);
    app_state.file_changed.* = true;
}

/// Scroll immediato (senza easing) a una posizione assoluta: per il
/// trascinamento del documento e della scrollbar, dove serve reattività 1:1.
fn scrollTo(app_state: *GuiAppState, y: f32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    const yy = @max(y, 0);
    app_state.scroll_y.* = yy;
    app_state.scroll_target.* = yy;
    app_state.file_changed.* = true;
}

fn isPdfPath(path: []const u8) bool {
    var clean_path = path;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
    }
    return std.mem.endsWith(u8, clean_path, ".pdf") or std.mem.endsWith(u8, clean_path, ".PDF");
}

fn changePdfPage(app_state: *GuiAppState, direction: i32) void {
    app_state.mutex.lockUncancelable(app_state.io);
    const path = app_state.gpa.dupe(u8, app_state.current_file_path) catch {
        app_state.mutex.unlock(app_state.io);
        return;
    };
    const is_image = (app_state.decoded.* == .image);
    var name_dup: ?[]const u8 = null;
    if (is_image) {
        name_dup = app_state.gpa.dupe(u8, app_state.decoded.image.name) catch null;
    }
    app_state.mutex.unlock(app_state.io);
    defer app_state.gpa.free(path);
    defer if (name_dup) |n| app_state.gpa.free(n);

    var clean_path = path;
    var current_page: usize = 1;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
        const suffix = path[hash_idx + 1 ..];
        var page_str = suffix;
        if (std.mem.startsWith(u8, suffix, "page=")) {
            page_str = suffix["page=".len..];
        }
        current_page = std.fmt.parseInt(usize, page_str, 10) catch 1;
    }

    var total_pages: usize = 99999;
    if (name_dup) |name| {
        if (std.mem.lastIndexOf(u8, name, " di ")) |di_idx| {
            const after_di = name[di_idx + " di ".len ..];
            if (std.mem.indexOfScalar(u8, after_di, ')')) |paren_idx| {
                const total_str = after_di[0..paren_idx];
                total_pages = std.fmt.parseInt(usize, total_str, 10) catch 99999;
            }
        }
    }

    var new_page = current_page;
    if (direction > 0) {
        if (current_page < total_pages) {
            new_page += 1;
        }
    } else {
        if (current_page > 1) {
            new_page -= 1;
        }
    }

    if (new_page == current_page) return;

    const new_path = std.fmt.allocPrint(app_state.gpa, "{s}#{d}", .{ clean_path, new_page }) catch return;
    defer app_state.gpa.free(new_path);

    app_state.loadFile(new_path) catch |err| {
        std.debug.print("Impossibile caricare pagina PDF: {s}\n", .{@errorName(err)});
    };
}

/// Alterna la modalità voxel. Alla prima attivazione voxelizza la mesh corrente
/// (griglia 96³) e la carica nel renderer; le attivazioni successive riusano la
/// griglia già caricata. Tiene il mutex: il thread di render usa lo stesso renderer.
fn toggleVoxel(app_state: *GuiAppState) void {
    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);

    if (!app_state.voxel_mode.* and app_state.voxel_dim.* == 0 and app_state.decoded.* == .mesh) {
        var grid = voxel.voxelize(app_state.gpa, app_state.decoded.mesh, 96) orelse {
            std.debug.print("[voxel] voxelizzazione fallita\n", .{});
            return;
        };
        defer grid.deinit(app_state.gpa);
        app_state.renderer.setVoxels(grid.dim, grid.data) catch |e| {
            std.debug.print("[voxel] setVoxels: {s}\n", .{@errorName(e)});
            return;
        };
        app_state.voxel_bbox_min.* = grid.bbox_min;
        app_state.voxel_bbox_size.* = grid.bbox_size;
        app_state.voxel_dim.* = grid.dim;
    }
    // Il path mesh `render()` è pipelined (fence ping-pong), il voxel è slot 0
    // sincrono: risincronizza il double-buffer a ogni cambio di modalità.
    app_state.renderer.resetFrameSync();
    app_state.voxel_mode.* = !app_state.voxel_mode.*;
    app_state.file_changed.* = true; // forza un re-render
}

fn keyCallback(win: *zrame.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    const pressed = (state == 1);
    if (key == KEY_LEFTSHIFT or key == KEY_RIGHTSHIFT) {
        app_state.shift_down.* = pressed;
    }
    if (key == KEY_LEFTCTRL or key == KEY_RIGHTCTRL) {
        app_state.ctrl_down.* = pressed;
        return;
    }
    if (pressed) {
        const is_text = app_state.is_text.*;
        // Ctrl+C: copia la selezione negli appunti.
        if (key == KEY_C and app_state.ctrl_down.* and is_text) {
            app_state.mutex.lockUncancelable(app_state.io);
            const sel = buildSelectedText(app_state, app_state.gpa);
            app_state.mutex.unlock(app_state.io);
            if (sel) |txt| {
                clipboardCopy(txt);
                app_state.gpa.free(txt);
            }
            return;
        }
        if (key == KEY_ESC) {
            win.close();
        } else if (is_text and (key == KEY_UP or key == KEY_DOWN)) {
            // Nei documenti le frecce verticali scorrono; ← → restano
            // la navigazione tra i file della cartella (parità con viewer).
            scrollText(app_state, if (key == KEY_DOWN) scroll_step else -scroll_step);
        } else if (is_text and (key == KEY_PGUP or key == KEY_PGDOWN)) {
            scrollText(app_state, if (key == KEY_PGDOWN) scroll_step * 10 else -scroll_step * 10);
        } else if (isPdfPath(app_state.current_file_path) and (key == KEY_UP or key == KEY_DOWN or key == KEY_PGUP or key == KEY_PGDOWN)) {
            const dir: i32 = if (key == KEY_DOWN or key == KEY_PGDOWN) 1 else -1;
            changePdfPage(app_state, dir);
        } else if (key == KEY_RIGHT or key == KEY_DOWN) {
            app_state.navigate(1);
        } else if (key == KEY_LEFT or key == KEY_UP) {
            app_state.navigate(-1);
        } else if (key == KEY_EQUAL) {
            applyZoom(app_state, 1.1);
        } else if (key == KEY_MINUS) {
            applyZoom(app_state, 1.0 / 1.1);
        } else if (key == KEY_F) {
            win.toggleFullscreen();
        } else if (key == KEY_V and app_state.is_mesh.*) {
            toggleVoxel(app_state);
        } else if (key == KEY_1) {
            win.setStyle(zrame.Style.fluent()) catch {};
        } else if (key == KEY_2) {
            win.setStyle(zrame.Style.macos()) catch {};
        } else if (key == KEY_3) {
            win.setStyle(zrame.Style.aurora()) catch {};
        } else if (key == KEY_4) {
            win.setStyle(zrame.Style.material()) catch {};
        } else if (key == KEY_5) {
            win.setStyle(zrame.Style.psy()) catch {};
        }
    }
}

fn scrollCallback(win: *zrame.Window, axis: u32, value: i32, user: ?*anyopaque) void {
    _ = win;
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    if (axis == 1) {
        // Asse orizzontale (trackpad/tilt-wheel): scorre le tabelle larghe.
        if (app_state.is_text.*) {
            const val = @as(f32, @floatFromInt(value)) / 256.0;
            app_state.scroll_target_x.* = @max(app_state.scroll_target_x.* + val * 5.0, 0);
            app_state.file_changed.* = true;
        }
        return;
    }
    if (axis == 0) {
        const val = @as(f32, @floatFromInt(value)) / 256.0;
        if (app_state.is_text.*) {
            // Shift+rotella = scroll orizzontale (per chi non ha rotella orizzontale).
            if (app_state.shift_down.*) {
                app_state.scroll_target_x.* = @max(app_state.scroll_target_x.* + val * 5.0, 0);
                app_state.file_changed.* = true;
                return;
            }
            // Documento: la rotella scorre (lo zoom testo resta su +/-)
            scrollText(app_state, val * 5.0);
            return;
        }
        if (val < 0) {
            applyZoom(app_state, 1.1);
        } else if (val > 0) {
            applyZoom(app_state, 1.0 / 1.1);
        }
    }
}

/// Mappa la coordinata verticale del mouse sulla scrollbar in una posizione di
/// scroll assoluta (cursore centrato sotto il puntatore) e vi salta immediato.
fn scrollFromBar(app_state: *GuiAppState, H: u32, src_h: u32, mouse_y: f32) void {
    if (src_h <= H) return;
    const t = scrollbarThumb(H, src_h, 0);
    const travel: f32 = if (H > t.h) @floatFromInt(H - t.h) else 1;
    const max_scroll: f32 = @floatFromInt(src_h - H);
    var ty = mouse_y - @as(f32, @floatFromInt(t.h)) / 2.0;
    ty = std.math.clamp(ty, 0, travel);
    scrollTo(app_state, ty / travel * max_scroll);
}

fn mouseCallback(win: *zrame.Window, event: zrame.MouseEvent, user: ?*anyopaque) void {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    switch (event) {
        .button => |btn| {
            // 0x110 = BTN_LEFT (click sinistro), 0x111 = BTN_RIGHT (click destro)
            if (btn.button != 0x110 and btn.button != 0x111) return;
            const down = (btn.state == 1);
            if (!down) {
                app_state.mutex.lockUncancelable(app_state.io);
                app_state.scrollbar_drag.* = false;
                app_state.sel_selecting.* = false;
                // Click senza trascinamento (ancora == estremo) → deseleziona.
                if (app_state.sel_a.*[0] == app_state.sel_b.*[0] and app_state.sel_a.*[1] == app_state.sel_b.*[1]) {
                    app_state.sel_active.* = false;
                    app_state.file_changed.* = true;
                }
                app_state.dragging.* = false;
                app_state.mutex.unlock(app_state.io);
                return;
            }
            // Click sinistro sulla barra delle linguette (in fondo): cambia foglio.
            if (btn.button == 0x110 and app_state.is_table.* and app_state.tab_bar.count > 0) {
                const H = win.panel_h;
                const tb = app_state.tab_bar;
                if (tb.h <= H and app_state.last_y.* >= @as(f32, @floatFromInt(H - tb.h))) {
                    const mx: u32 = @intFromFloat(@max(app_state.last_x.*, 0));
                    var idx: usize = 0;
                    while (idx < tb.count and mx >= tb.bounds[idx]) : (idx += 1) {}
                    if (idx < tb.count) {
                        app_state.mutex.lockUncancelable(app_state.io);
                        if (app_state.decoded.* == .workbook and app_state.decoded.workbook.active != idx) {
                            app_state.decoded.workbook.active = idx;
                            // Nuovo foglio: riparti dall'alto/sinistra e ri-rasterizza.
                            app_state.scroll_y.* = 0;
                            app_state.scroll_target.* = 0;
                            app_state.scroll_x.* = 0;
                            app_state.scroll_target_x.* = 0;
                            app_state.load_seq.* +%= 1;
                            app_state.file_changed.* = true;
                        }
                        app_state.mutex.unlock(app_state.io);
                    }
                    return; // click sulla barra consumato (niente selezione)
                }
            }
            // Pressione sinistra sul testo: scrollbar oppure avvio selezione.
            if (btn.button == 0x110 and app_state.is_text.*) {
                const W = win.panel_w;
                const H = win.panel_h;
                const src_h = app_state.static_h.*;
                if (W >= scrollbar_w and src_h > H and
                    app_state.last_x.* >= @as(f32, @floatFromInt(W - scrollbar_w)))
                {
                    app_state.scrollbar_drag.* = true;
                    scrollFromBar(app_state, H, src_h, app_state.last_y.*);
                    return;
                }
                app_state.mutex.lockUncancelable(app_state.io);
                if (app_state.text_lines.items.len > 0) {
                    const hit = textHit(app_state, W, H, app_state.last_x.*, app_state.last_y.*);
                    app_state.sel_a.* = hit;
                    app_state.sel_b.* = hit;
                    app_state.sel_active.* = true;
                    app_state.sel_selecting.* = true;
                    app_state.file_changed.* = true;
                    app_state.mutex.unlock(app_state.io);
                    return;
                }
                app_state.mutex.unlock(app_state.io);
            }
            app_state.dragging.* = down;
        },
        .motion => |mot| {
            if (app_state.scrollbar_drag.*) {
                scrollFromBar(app_state, win.panel_h, app_state.static_h.*, mot.y);
            } else if (app_state.sel_selecting.*) {
                app_state.mutex.lockUncancelable(app_state.io);
                app_state.sel_b.* = textHit(app_state, win.panel_w, win.panel_h, mot.x, mot.y);
                app_state.file_changed.* = true;
                app_state.mutex.unlock(app_state.io);
            } else if (app_state.dragging.*) {
                const dx = mot.x - app_state.last_x.*;
                const dy = mot.y - app_state.last_y.*;
                if (app_state.is_mesh.*) {
                    app_state.yaw.* += dx * 0.01;
                    app_state.pitch.* += dy * 0.01;
                } else if (app_state.is_text.*) {
                    // Fallback (testo senza righe selezionabili, es. percorso GPU):
                    // il trascinamento scorre il documento.
                    scrollTo(app_state, app_state.scroll_y.* - dy);
                } else {
                    app_state.mutex.lockUncancelable(app_state.io);
                    app_state.pan_x.* += dx;
                    app_state.pan_y.* += dy;
                    app_state.file_changed.* = true;
                    app_state.mutex.unlock(app_state.io);
                }
            }
            app_state.last_x.* = mot.x;
            app_state.last_y.* = mot.y;
        },
    }
}

/// Libera il testo per-riga trattenuto per la selezione.
fn freeTextLines(state: *GuiAppState) void {
    for (state.text_lines.items) |l| state.gpa.free(l);
    state.text_lines.clearRetainingCapacity();
}

/// Rasterizza il contenuto testuale corrente alla larghezza richiesta e al
/// corpo scalato dallo zoom, sostituendo il buffer statico RGBA.
/// Da chiamare con `state.mutex` già acquisito.
fn rasterizeText(state: *GuiAppState, width: u32, text_zoom: f32) void {
    const pointsize: usize = @intFromFloat(@round(15.0 * text_zoom));
    const opts = text_render.RenderOpts{ .width = @max(width, 64), .pointsize = @max(pointsize, 6) };
    const name = std.fs.path.basename(state.current_file_path);

    if (state.text_gpu) {
        rasterizeTextGpu(state, name, opts);
        return;
    }

    // La geometria (wrapping) cambia con larghezza/zoom: la vecchia selezione
    // non è più valida.
    freeTextLines(state);
    state.sel_active.* = false;
    state.sel_selecting.* = false;

    var img = text_render.renderDoc(state.gpa, state.decoded, name, opts, state.text_lines, state.text_metrics) catch |err| {
        std.debug.print("Impossibile rasterizzare il testo: {s}\n", .{@errorName(err)});
        return;
    };
    defer img.deinit(state.gpa);

    const w: u32 = @intCast(img.width);
    const h: u32 = @intCast(img.height);
    const rgba = state.gpa.alloc(u8, @as(usize, w) * h * 4) catch return;
    for (0..@as(usize, w) * h) |i| {
        rgba[i * 4 + 0] = img.pixels[i * 3 + 0];
        rgba[i * 4 + 1] = img.pixels[i * 3 + 1];
        rgba[i * 4 + 2] = img.pixels[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }

    state.gpa.free(state.static_rgba.*);
    state.static_rgba.* = rgba;
    state.static_w.* = w;
    state.static_h.* = h;

    rasterizeTabBar(state, width);
}

/// (Ri)genera la barra delle linguette per un workbook, alla larghezza corrente.
/// Non-workbook → azzera la barra (nessuna linguetta). Immagine RGB → RGBA opaca.
/// Da chiamare con `state.mutex` acquisito (come `rasterizeText`).
fn rasterizeTabBar(state: *GuiAppState, width: u32) void {
    const tb = state.tab_bar;
    if (state.decoded.* != .workbook) {
        tb.count = 0;
        return;
    }
    const wb = &state.decoded.workbook;
    var img = text_render.renderTabBar(state.gpa, wb.sheets, wb.active, @max(width, 64), &tb.bounds) catch {
        tb.count = 0;
        return;
    };
    defer img.deinit(state.gpa);

    const tw: u32 = @intCast(img.width);
    const th: u32 = @intCast(img.height);
    const rgba = state.gpa.alloc(u8, @as(usize, tw) * th * 4) catch {
        tb.count = 0;
        return;
    };
    for (0..@as(usize, tw) * th) |i| {
        rgba[i * 4 + 0] = img.pixels[i * 3 + 0];
        rgba[i * 4 + 1] = img.pixels[i * 3 + 1];
        rgba[i * 4 + 2] = img.pixels[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }
    state.gpa.free(tb.rgba);
    tb.rgba = rgba;
    tb.w = tw;
    tb.h = th;
    tb.count = @min(wb.sheets.len, max_tabs);
}

/// Percorso GPU (Soluzione B): costruisce i quad glifo + atlante e li renderizza
/// con la pipeline testo Vulkan, poi copia i pixel RGBA nel buffer statico.
fn rasterizeTextGpu(state: *GuiAppState, name: []const u8, opts: text_render.RenderOpts) void {
    var mesh = text_render.buildTextMesh(state.gpa, state.decoded, name, opts) catch |err| {
        std.debug.print("Impossibile costruire i quad del testo: {s}\n", .{@errorName(err)});
        return;
    };
    defer mesh.deinit(state.gpa);

    const rgba_src = state.renderer.renderText(
        std.mem.sliceAsBytes(mesh.vertices),
        @intCast(mesh.vertices.len),
        mesh.atlas.pixels,
        @intCast(mesh.atlas.w),
        @intCast(mesh.atlas.h),
        @intCast(mesh.width),
        @intCast(mesh.height),
        text_render.clear_bg,
    ) catch |err| {
        std.debug.print("Render testo GPU fallito: {s}\n", .{@errorName(err)});
        return;
    };

    // Il readback è riusato dalla chiamata successiva: copiane una proprietà.
    const rgba = state.gpa.dupe(u8, rgba_src) catch return;
    state.gpa.free(state.static_rgba.*);
    state.static_rgba.* = rgba;
    state.static_w.* = @intCast(mesh.width);
    state.static_h.* = @intCast(mesh.height);
}

/// Riempie un piccolo disco pieno (bordo morbido ~1px) fondendolo sul buffer RGBA.
fn fillDot(buf: []u8, W: u32, H: u32, cx: f32, cy: f32, r: f32, rr: u8, gg: u8, bb: u8, a: u8) void {
    const x0: i32 = @intFromFloat(@floor(cx - r - 1));
    const x1: i32 = @intFromFloat(@ceil(cx + r + 1));
    const y0: i32 = @intFromFloat(@floor(cy - r - 1));
    const y1: i32 = @intFromFloat(@ceil(cy + r + 1));
    const xw: i32 = @min(x1, @as(i32, @intCast(W)));
    const yh: i32 = @min(y1, @as(i32, @intCast(H)));
    var y: i32 = @max(y0, 0);
    while (y < yh) : (y += 1) {
        var x: i32 = @max(x0, 0);
        while (x < xw) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(dx * dx + dy * dy);
            // Copertura piena entro r-1, sfuma fino a r (anti-aliasing del bordo).
            const cov = std.math.clamp(r - d, 0.0, 1.0);
            if (cov <= 0.0) continue;
            const aa: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(a)) * cov));
            blendPixel(buf, (@as(u32, @intCast(y)) * W + @as(u32, @intCast(x))) * 4, rr, gg, bb, aa);
        }
    }
}

/// Schermata di caricamento: sfondo completamente trasparente (si vede il vetro
/// della finestra / blur del compositore) con uno spinner a 12 punti rotante al
/// centro. `frame` avanza a ogni fotogramma per animarlo (la testa fa un giro in
/// ~0.6 s a 60 Hz); la scia sfuma dietro la testa.
fn drawLoader(buf: []u8, W: u32, H: u32, frame: u32) void {
    const n_px: usize = @as(usize, W) * H;
    // Sfondo trasparente: solo lo spinner resta visibile sul pannello di vetro.
    @memset(buf[0 .. n_px * 4], 0);

    const dots: u32 = 12;
    const cx: f32 = @as(f32, @floatFromInt(W)) / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(H)) / 2.0;
    const ring_r: f32 = @max(@as(f32, @floatFromInt(@min(W, H))) / 14.0, 18.0);
    const dot_r: f32 = @max(ring_r / 4.0, 3.0);
    const head: u32 = (frame / 3) % dots;

    var k: u32 = 0;
    while (k < dots) : (k += 1) {
        const ang = (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(dots))) * (2.0 * std.math.pi) - std.math.pi / 2.0;
        const px = cx + ring_r * @cos(ang);
        const py = cy + ring_r * @sin(ang);
        // back = distanza (in punti) dietro la testa: 0 = testa (più luminoso).
        const back: u32 = (head + dots - k) % dots;
        const frac = @as(f32, @floatFromInt(dots - 1 - back)) / @as(f32, @floatFromInt(dots - 1));
        const a: u8 = @intFromFloat(@round(40.0 + frac * 205.0));
        fillDot(buf, W, H, px, py, dot_r, 205, 210, 230, a);
    }
}

fn renderWorker(
    win: *zrame.Window,
    state: *GuiAppState,
    composited_rgba: *[]u8,
    yaw: *const f32,
    pitch: *const f32,
    zoom: *const f32,
) void {
    var last_w: u32 = 0;
    var last_h: u32 = 0;
    var last_text_w: u32 = 0;
    var last_text_zoom: f32 = 0;
    var last_seq: u32 = 0;
    // Ultima camera renderizzata: le mesh si ri-renderizzano SOLO quando cambia
    // (NaN iniziale ⇒ primo frame sempre reso). Senza questo il worker presenta
    // a 60 Hz all'infinito anche a mesh ferma, contendendo il socket Wayland col
    // thread di dispatch input → tasti (ESC) poco reattivi.
    var last_yaw: f32 = std.math.nan(f32);
    var last_pitch: f32 = std.math.nan(f32);
    var last_zoom: f32 = std.math.nan(f32);

    var pacer_60 = zicro.time.Pacer.hz(state.io, 60.0);
    var pacer_20 = zicro.time.Pacer.hz(state.io, 20.0);
    // Fotogramma dello spinner di caricamento (animazione a 60 Hz).
    var spin_frame: u32 = 0;

    while (!win.closed) {
        const cur_w = win.panel_w;
        const cur_h = win.panel_h;
        if (cur_w == 0 or cur_h == 0) {
            _ = pacer_20.tick();
            continue;
        }

        state.mutex.lockUncancelable(state.io);

        // Il file iniziale è ancora in decodifica su un thread di background:
        // anima lo spinner a 60 Hz finché `applyDecoded` non azzera il flag.
        if (state.loading.*) {
            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                composited_rgba.* = state.gpa.alloc(u8, cur_w * cur_h * 4) catch {
                    state.mutex.unlock(state.io);
                    break;
                };
            }
            drawLoader(composited_rgba.*, cur_w, cur_h, spin_frame);
            win.presentRgba(cur_w, cur_h, composited_rgba.*);
            state.mutex.unlock(state.io);
            spin_frame +%= 1;
            _ = pacer_60.tick();
            continue;
        }

        const size_changed = (cur_w != last_w or cur_h != last_h);
        // La mesh va ridisegnata solo se la camera è cambiata (drag/zoom).
        const mesh_moved = state.is_mesh.* and
            (yaw.* != last_yaw or pitch.* != last_pitch or zoom.* != last_zoom);
        var need_render = size_changed or state.file_changed.* or mesh_moved;
        var text_animating = false;

        if (state.is_text.*) {
            // (Ri)compone il testo quando cambiano larghezza finestra, zoom o
            // file: un solo tentativo per cambio di parametri (evita di ripetere
            // il layout a 20 Hz se qualcosa fallisce in modo persistente).
            const tz = std.math.clamp(zoom.*, text_zoom_min, text_zoom_max);
            if (last_text_w != cur_w or last_text_zoom != tz or last_seq != state.load_seq.*) {
                rasterizeText(state, cur_w, tz);
                last_text_w = cur_w;
                last_text_zoom = tz;
                last_seq = state.load_seq.*;
                need_render = true;
            }
            // Clamp della meta di scroll ora che l'altezza del documento è nota,
            // poi easing di scroll_y verso di essa (scroll fluido).
            const max_scroll: f32 = if (state.static_h.* > cur_h)
                @floatFromInt(state.static_h.* - cur_h)
            else
                0;
            state.scroll_target.* = std.math.clamp(state.scroll_target.*, 0, max_scroll);
            const diff = state.scroll_target.* - state.scroll_y.*;
            if (@abs(diff) > 0.5) {
                state.scroll_y.* += diff * scroll_ease;
                need_render = true;
                text_animating = true;
            } else {
                state.scroll_y.* = state.scroll_target.*;
            }
            state.scroll_y.* = std.math.clamp(state.scroll_y.*, 0, max_scroll);

            // Stesso easing sull'asse orizzontale (tabelle più larghe della finestra).
            const max_scroll_x: f32 = if (state.static_w.* > cur_w)
                @floatFromInt(state.static_w.* - cur_w)
            else
                0;
            state.scroll_target_x.* = std.math.clamp(state.scroll_target_x.*, 0, max_scroll_x);
            const diff_x = state.scroll_target_x.* - state.scroll_x.*;
            if (@abs(diff_x) > 0.5) {
                state.scroll_x.* += diff_x * scroll_ease;
                need_render = true;
                text_animating = true;
            } else {
                state.scroll_x.* = state.scroll_target_x.*;
            }
            state.scroll_x.* = std.math.clamp(state.scroll_x.*, 0, max_scroll_x);
        }

        if (need_render) {
            state.file_changed.* = false;
            last_w = cur_w;
            last_h = cur_h;

            if (composited_rgba.len < cur_w * cur_h * 4) {
                state.gpa.free(composited_rgba.*);
                composited_rgba.* = state.gpa.alloc(u8, cur_w * cur_h * 4) catch {
                    state.mutex.unlock(state.io);
                    break;
                };
            }

            if (state.is_mesh.*) {
                // Modalità voxel (tasto V): ray-march della griglia invece della
                // mesh triangolata. Altrimenti pipeline PBR normale.
                const mesh_rgba = if (state.voxel_mode.* and state.renderer.hasVoxels()) rv: {
                    const vpc = gpu.buildVoxelPush(state.mesh_center.*, state.mesh_max_size.* / zoom.*, yaw.*, pitch.*, cur_w, cur_h, state.voxel_bbox_min.*, state.voxel_bbox_size.*, state.voxel_dim.*);
                    break :rv state.renderer.renderVoxel(cur_w, cur_h, &vpc) catch {
                        state.mutex.unlock(state.io);
                        break;
                    };
                } else rm: {
                    const pc = gpu.buildPushConstants(state.mesh_center.*, state.mesh_max_size.* / zoom.*, yaw.*, pitch.*, cur_w, cur_h, state.mesh_material.*);
                    break :rm state.renderer.render(cur_w, cur_h, &pc) catch {
                        state.mutex.unlock(state.io);
                        break;
                    };
                };
                composeFrame(composited_rgba.*, cur_w, cur_h, mesh_rgba, cur_w, cur_h, false, 1.0, 0.0, 0.0);
                last_yaw = yaw.*;
                last_pitch = pitch.*;
                last_zoom = zoom.*;
            } else if (state.is_text.*) {
                // Tabelle: àncora la banda header (top padding + riga intestazione)
                // in cima durante lo scroll verticale. Clampata all'altezza finestra.
                const header_band: u32 = if (state.is_table.*) blk: {
                    const m = state.text_metrics.*;
                    const hb = m.pad_y + m.line_h;
                    break :blk if (hb > 0) @min(@as(u32, @intCast(hb)), cur_h) else 0;
                } else 0;
                composeTextFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, state.scroll_y.*, state.scroll_x.*, header_band);
                if (state.sel_active.*) {
                    drawTextSelection(composited_rgba.*, cur_w, cur_h, state.static_w.*, state.static_h.*, state.scroll_y.*, state.scroll_x.*, state.text_metrics.*, state.text_lines.items, state.sel_a.*, state.sel_b.*);
                }
                const tgeom = textBlitGeom(cur_w, cur_h, state.static_w.*, state.static_h.*, state.scroll_y.*, state.scroll_x.*);
                drawScrollbar(composited_rgba.*, cur_w, cur_h, state.static_h.*, tgeom.off_y);
                drawHScrollbar(composited_rgba.*, cur_w, cur_h, state.static_w.*, tgeom.x_src);
                // Barra delle linguette in fondo (workbook multi-foglio), sopra tutto.
                blitTabBar(composited_rgba.*, cur_w, cur_h, state.tab_bar);
            } else {
                composeFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, false, zoom.*, state.pan_x.*, state.pan_y.*);
            }

            win.presentRgba(cur_w, cur_h, composited_rgba.*);
        }

        state.mutex.unlock(state.io);

        // 60 Hz mentre la mesh si muove (drag/zoom) o durante l'animazione dello
        // scroll testo; 20 Hz a riposo (così il dispatch input resta reattivo).
        if (mesh_moved or text_animating) {
            _ = pacer_60.tick();
        } else {
            _ = pacer_20.tick();
        }
    }
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Copia negli appunti tramite `wl-copy` (wl-clipboard): niente supporto
// clipboard Wayland in zrame da estendere. Il testo va sullo stdin del figlio.
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(fa: *anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(fa: *anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(fa: *anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(fa: *anyopaque, fd: c_int) c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

/// Offset di byte del `col`-esimo codepoint in una riga UTF-8 (o fine stringa).
fn byteAtCol(s: []const u8, col: i32) usize {
    if (col <= 0) return 0;
    var n: i32 = 0;
    var i: usize = 0;
    while (i < s.len and n < col) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(@as(usize, seq), s.len - i);
        n += 1;
    }
    return i;
}

/// Costruisce il testo selezionato (righe unite da '\n'). Con `state.mutex`
/// acquisito. Ritorna null se non c'è selezione; il chiamante libera il buffer.
fn buildSelectedText(state: *GuiAppState, gpa: std.mem.Allocator) ?[]u8 {
    if (!state.sel_active.*) return null;
    const lines = state.text_lines.items;
    if (lines.len == 0) return null;
    var a = state.sel_a.*;
    var b = state.sel_b.*;
    if (a[0] > b[0] or (a[0] == b[0] and a[1] > b[1])) {
        const t = a;
        a = b;
        b = t;
    }
    if (a[0] == b[0] and a[1] == b[1]) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const nrows: i32 = @intCast(lines.len);
    var row: i32 = std.math.clamp(a[0], 0, nrows - 1);
    while (row <= b[0] and row < nrows) : (row += 1) {
        const line = lines[@intCast(row)];
        const llen = cpLen(line);
        const c0 = std.math.clamp(if (row == a[0]) a[1] else 0, 0, llen);
        const c1 = std.math.clamp(if (row == b[0]) b[1] else llen, 0, llen);
        const bs = byteAtCol(line, c0);
        const be = byteAtCol(line, c1);
        if (be > bs) out.appendSlice(gpa, line[bs..be]) catch return null;
        if (row < b[0]) out.append(gpa, '\n') catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Invia `text` a `wl-copy` (stdin) per metterlo negli appunti Wayland.
fn clipboardCopy(text: []const u8) void {
    if (text.len == 0) return;
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return;
    const rfd = fds[0];
    const wfd = fds[1];

    var fa: [256]u8 align(16) = undefined;
    if (posix_spawn_file_actions_init(&fa) != 0) {
        _ = close(rfd);
        _ = close(wfd);
        return;
    }
    defer _ = posix_spawn_file_actions_destroy(&fa);
    _ = posix_spawn_file_actions_adddup2(&fa, rfd, 0); // stdin del figlio ← lettura pipe
    _ = posix_spawn_file_actions_addclose(&fa, wfd);

    const wlcopy: [*:0]const u8 = "wl-copy";
    var argv = [_:null]?[*:0]const u8{wlcopy};
    var pid: c_int = 0;
    const rc = posix_spawnp(&pid, wlcopy, &fa, null, &argv, environ);
    _ = close(rfd);
    if (rc != 0) {
        _ = close(wfd);
        return;
    }
    var off: usize = 0;
    while (off < text.len) {
        const n = write(wfd, text.ptr + off, text.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = close(wfd); // EOF: wl-copy acquisisce la selezione e passa in background
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
}

/// Categoria di contenuto per scegliere proporzioni di finestra sensate: le
/// immagini seguono l'aspetto reale, i documenti sono ritratto (pagina), le
/// tabelle (csv/xls/zip) e le mesh hanno viewport più larghi/quadri.
const WinKind = enum { image, mesh, document, table, generic };

fn extLowerEql(ext: []const u8, comptime lit: []const u8) bool {
    if (ext.len != lit.len) return false;
    for (ext, lit) |c, l| if (std.ascii.toLower(c) != l) return false;
    return true;
}

/// Riconoscimento del tipo dall'estensione (percorso async: prima del decode).
fn winKindFromExt(path: []const u8) WinKind {
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
    inline for (.{ "csv", "tsv", "xlsx", "xls", "ods", "zip", "jar", "apk", "cbz", "epub", "xpi", "whl" }) |e| {
        if (extLowerEql(ext, e)) return .table;
    }
    // I PDF vengono resi come immagine di pagina, ma con proporzioni ritratto.
    if (extLowerEql(ext, "pdf")) return .document;
    return .document; // testo/markdown/codice e sconosciuti: documento (ritratto)
}

fn winKindFromDecoded(d: *const decoder_mod.Decoded) WinKind {
    return switch (d.*) {
        .image => .image,
        .mesh => .mesh,
        .csv, .workbook => .table,
        .text, .markdown => .document,
        .err => .generic,
    };
}

/// Dimensione iniziale della finestra, con proporzioni intelligenti per tipo di
/// contenuto. Per le immagini si adatta all'aspetto reale (l'immagine riempie il
/// frame) con un tetto ZUER_MAX_WIN ("LxA", default 1600x900); per gli altri tipi
/// usa proporzioni fisse sensate (ritratto per documenti, largo per tabelle,
/// quadro per mesh).
fn initialWindowSize(kind: WinKind, img_w: u32, img_h: u32) struct { w: u32, h: u32 } {
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
        .image => {
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
        // Documento: proporzione ritratto tipo pagina.
        .document => return .{ .w = @min(max_w, 860), .h = @min(max_h, 1040) },
        // Tabella (csv/xls/zip): dimensiona sulla larghezza reale delle colonne
        // (img_w/img_h = dimensione naturale della griglia), con tetto sullo
        // schermo. Oltre max_w la finestra si ferma e scatta lo scroll orizzontale.
        .table => {
            if (img_w != 0) {
                const w = std.math.clamp(img_w, 480, max_w);
                const h = std.math.clamp(img_h, 300, max_h);
                return .{ .w = w, .h = h };
            }
            return .{ .w = @min(max_w, 1280), .h = @min(max_h, 820) };
        },
        // Mesh 3D: viewport quasi quadrato.
        .mesh => return .{ .w = @min(max_w, 1000), .h = @min(max_h, 900) },
        .generic => return .{ .w = 1280, .h = 720 },
    }
}

/// Risolve l'argomento iniziale in un percorso di file. Se `arg` è una CARTELLA,
/// restituisce il primo file al suo interno (ordine alfabetico) — così invocando
/// zuer su una cartella si apre una preview navigabile con le frecce (initFileList
/// popola la lista con gli altri file). Se `arg` è già un file, lo duplica. Il
/// chiamante possiede e libera la stringa restituita.
fn resolveInitialFile(io: std.Io, gpa: std.mem.Allocator, arg: []const u8) !?[]u8 {
    // openDir riesce solo sulle cartelle; su un file dà errore → è già un file.
    var dir = std.Io.Dir.cwd().openDir(io, arg, .{ .iterate = true }) catch
        return try gpa.dupe(u8, arg);
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and entry.name.len > 0 and entry.name[0] != '.')
            try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return null; // cartella senza file visibili

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return try std.fs.path.join(gpa, &.{ arg, names.items[0] });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Comunica ai plugin decoder che siamo in modalità GUI (quindi vogliamo la massima risoluzione possibile)
    _ = setenv("ZUER_GUI", "1", 1);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    defer decoder_mod.closePluginCache(gpa);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const arg_path = args.next() orelse {
        std.debug.print("Uso: zuer-gui <file|cartella>\n", .{});
        std.process.exit(1);
    };
    // Se l'argomento è una cartella, apri il primo file: la navigazione con le
    // frecce (e il prefetch) permette di sfogliare tutti i file della cartella.
    const file_path = (resolveInitialFile(io, gpa, arg_path) catch |e| {
        std.debug.print("Impossibile accedere a '{s}': {s}\n", .{ arg_path, @errorName(e) });
        std.process.exit(1);
    }) orelse {
        std.debug.print("La cartella '{s}' non contiene file da mostrare.\n", .{arg_path});
        std.process.exit(1);
    };
    defer gpa.free(file_path);

    // Decodifica differita: la finestra deve apparire SUBITO. I file grandi (o i
    // PDF, che lanciano processi esterni) si decodificano su un thread di
    // background mentre il worker mostra uno spinner; i file piccoli si
    // decodificano qui sotto in modo sincrono, così la finestra può ancora
    // dimensionarsi sull'immagine (nessuna regressione di sizing).
    var clean_path: []const u8 = file_path;
    if (std.mem.indexOfScalar(u8, file_path, '#')) |h| clean_path = file_path[0..h];
    var loader_threshold_mb: u64 = 4;
    if (getenv("ZUER_LOADER_MB")) |v| {
        if (std.fmt.parseInt(u64, std.mem.span(v), 10)) |mb| {
            loader_threshold_mb = mb;
        } else |_| {}
    }
    var loading = isPdfPath(file_path);
    if (std.Io.Dir.cwd().statFile(io, clean_path, .{})) |st| {
        if (st.size >= loader_threshold_mb * 1024 * 1024) loading = true;
    } else |_| {}

    // Contenuto decodificato: parte come testo vuoto (placeholder, deinit no-op)
    // e viene sostituito da `applyDecoded` — sul thread di decodifica o qui sotto.
    var decoded: decoder_mod.Decoded = .{ .text = "" };
    defer decoded.deinit(gpa);
    var is_text = true;
    var is_mesh = false;
    var is_table = false;
    var tab_bar: TabBarState = .{};
    defer gpa.free(tab_bar.rgba);

    var stage_opt: ?loader_mod.GpuStage = null;
    defer if (stage_opt) |*s| s.buffer.deinit(gpa);

    // Renderer Vulkan Offscreen (nessuna estensione swapchain WSI richiesta)
    var renderer = try gpu.Renderer.init(gpa, .{});
    defer renderer.deinit();

    var mesh_center: [3]f32 = .{ 0, 0, 0 };
    var mesh_max_size: f32 = 1;
    var mesh_material: gpu.Material = .{};
    var voxel_mode = false;
    var voxel_bbox_min: [3]f32 = .{ 0, 0, 0 };
    var voxel_bbox_size: [3]f32 = .{ 1, 1, 1 };
    var voxel_dim: u32 = 0;

    var static_rgba: []u8 = &.{};
    defer gpa.free(static_rgba);
    var static_w: u32 = 0;
    var static_h: u32 = 0;

    var state_mutex: std.Io.Mutex = .init;
    var load_seq: u32 = 1;
    var file_changed = false;
    var zoom: f32 = 1.0;
    var yaw: f32 = 0;
    var pitch: f32 = 0;
    var pan_x: f32 = 0;
    var pan_y: f32 = 0;
    var scroll_y: f32 = 0;
    var scroll_target: f32 = 0;
    var scroll_x: f32 = 0;
    var scroll_target_x: f32 = 0;
    var scrollbar_drag = false;
    var dragging = false;
    var last_x: f32 = 0;
    var last_y: f32 = 0;
    var text_lines: std.ArrayList([]const u8) = .empty;
    var text_metrics: text_render.Metrics = .{ .advance = 1, .line_h = 1, .pad_x = 20, .pad_y = 14 };
    var sel_active = false;
    var sel_selecting = false;
    var sel_a: [2]i32 = .{ 0, 0 };
    var sel_b: [2]i32 = .{ 0, 0 };
    var ctrl_down = false;
    var shift_down = false;

    // Stato del prefetch dei file adiacenti (vedi prefetchWorker).
    var pf_mutex: std.Io.Mutex = .init;
    var pf_cond: std.Io.Condition = .init;
    var pf_cache: std.StringHashMapUnmanaged(Prefetched) = .empty;
    var pf_want: [2]?[]u8 = .{ null, null };
    var pf_stop: bool = false;

    var gui_state = GuiAppState{
        .gpa = gpa,
        .io = io,
        .mutex = &state_mutex,
        .current_file_path = try gpa.dupe(u8, file_path),
        .file_list = .empty,
        .current_file_index = null,
        .decoded = &decoded,
        .stage_opt = &stage_opt,
        .renderer = &renderer,
        .text_gpu = text_gpu: {
            if (getenv("ZUER_TEXT_ENGINE")) |v| break :text_gpu std.mem.eql(u8, std.mem.span(v), "gpu");
            break :text_gpu false;
        },
        .is_mesh = &is_mesh,
        .is_text = &is_text,
        .is_table = &is_table,
        .tab_bar = &tab_bar,
        .file_changed = &file_changed,
        .loading = &loading,
        .load_seq = &load_seq,
        .zoom = &zoom,
        .static_rgba = &static_rgba,
        .static_w = &static_w,
        .static_h = &static_h,
        .mesh_center = &mesh_center,
        .mesh_max_size = &mesh_max_size,
        .mesh_material = &mesh_material,
        .voxel_mode = &voxel_mode,
        .voxel_bbox_min = &voxel_bbox_min,
        .voxel_bbox_size = &voxel_bbox_size,
        .voxel_dim = &voxel_dim,
        .dragging = &dragging,
        .yaw = &yaw,
        .pitch = &pitch,
        .pan_x = &pan_x,
        .pan_y = &pan_y,
        .scroll_y = &scroll_y,
        .scroll_target = &scroll_target,
        .scroll_x = &scroll_x,
        .scroll_target_x = &scroll_target_x,
        .scrollbar_drag = &scrollbar_drag,
        .last_x = &last_x,
        .last_y = &last_y,
        .text_lines = &text_lines,
        .text_metrics = &text_metrics,
        .sel_active = &sel_active,
        .sel_selecting = &sel_selecting,
        .sel_a = &sel_a,
        .sel_b = &sel_b,
        .ctrl_down = &ctrl_down,
        .shift_down = &shift_down,
        .pf_mutex = &pf_mutex,
        .pf_cond = &pf_cond,
        .pf_cache = &pf_cache,
        .pf_want = &pf_want,
        .pf_stop = &pf_stop,
    };
    defer {
        gpa.free(gui_state.current_file_path);
        for (gui_state.file_list.items) |f| gpa.free(f);
        gui_state.file_list.deinit(gpa);
        for (text_lines.items) |l| gpa.free(l);
        text_lines.deinit(gpa);
        // Svuota la cache di prefetch e i percorsi desiderati.
        var pit = pf_cache.iterator();
        while (pit.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        pf_cache.deinit(gpa);
        for (pf_want) |w| if (w) |x| gpa.free(x);
    }
    try gui_state.initFileList();

    // File piccolo: decodifica sincrona prima di creare la finestra, così può
    // dimensionarsi sull'immagine. I file grandi restano placeholder (spinner)
    // e vengono decodificati sul thread di background più sotto.
    if (!loading) {
        var d = decoder_mod.decode(file_path, io, gpa);
        if (d == .err) {
            std.debug.print("Errore: {s}\n", .{d.err});
            d.deinit(gpa);
            std.process.exit(1);
        }
        gui_state.applyDecoded(d, null, file_path) catch |e| {
            std.debug.print("Errore inizializzazione file: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
    }

    var composited_rgba: []u8 = &.{};
    defer gpa.free(composited_rgba);

    // Proporzioni intelligenti per tipo di contenuto: nel percorso sincrono il
    // tipo è già noto dal decoded; in quello async (spinner) si stima
    // dall'estensione, così la finestra nasce già con la forma giusta.
    const win_kind: WinKind = if (loading) winKindFromExt(file_path) else winKindFromDecoded(&decoded);
    // Per le tabelle (percorso sincrono) la finestra si dimensiona sulla larghezza
    // reale delle colonne, non su un valore fisso.
    var tbl_w: u32 = 0;
    var tbl_h: u32 = 0;
    if (!loading and (decoded == .csv or decoded == .workbook)) {
        const opts0 = text_render.RenderOpts{ .width = 1280, .pointsize = 15 };
        const csv0 = switch (decoded) {
            .csv => |c| c,
            .workbook => |w| w.activeCsv(),
            else => unreachable,
        };
        if (text_render.tableNaturalSize(gpa, csv0, opts0)) |ns| {
            tbl_w = @intCast(ns.w);
            tbl_h = @intCast(ns.h);
        } else |_| {}
    }
    const size_w = if (win_kind == .table) tbl_w else static_w;
    const size_h = if (win_kind == .table) tbl_h else static_h;
    const win_size = initialWindowSize(win_kind, size_w, size_h);
    const win = try zrame.Window.init(gpa, .{
        .title = "zuer-gui",
        .app_id = "it.zuer.gui",
        .width = win_size.w,
        .height = win_size.h,
        .on_key = keyCallback,
        .on_scroll = scrollCallback,
        .on_mouse = mouseCallback,
        .user = &gui_state,
        .style = zrame.Style.fluent(),
    });
    defer win.deinit();
    // La navigazione con le frecce usa la finestra per animare il resize sul
    // contenuto. Impostata prima di `win.run()` (dove partono le callback).
    gui_state.win = win;

    // Spawna il thread lavoratore per il rendering offscreen e compositing
    const thread = try std.Thread.spawn(.{}, renderWorker, .{ win, &gui_state, &composited_rgba, &yaw, &pitch, &zoom });
    defer thread.join();

    // File grande/PDF iniziale: decodifica su un thread di background mentre il
    // worker mostra lo spinner. Va gioinato prima dei defer che liberano lo stato.
    var decode_thread: ?std.Thread = null;
    if (loading) {
        decode_thread = try std.Thread.spawn(.{}, decodeInitial, .{ &gui_state, file_path });
    }
    defer if (decode_thread) |t| t.join();

    // Thread di prefetch dei file adiacenti (navigazione istantanea). Il suo
    // defer è registrato DOPO quello che libera la cache → viene eseguito PRIMA:
    // il thread è fermato e gioinato prima che la cache venga distrutta.
    const prefetch_thread = try std.Thread.spawn(.{}, prefetchWorker, .{&gui_state});
    defer {
        pf_mutex.lockUncancelable(io);
        pf_stop = true;
        pf_mutex.unlock(io);
        pf_cond.signal(io);
        prefetch_thread.join();
    }
    // Percorso sincrono: il file iniziale è già pronto → precarica subito i
    // vicini. (Nel percorso async lo fa `decodeInitial` dopo aver installato
    // il contenuto, per non decodificare in parallelo al decode iniziale.)
    if (!loading) gui_state.schedulePrefetchAround();

    try win.run();
}

/// Thread loader: attende richieste (`postLoad`) e decodifica il file più recente
/// (latest-wins) fuori dal thread di input, installandolo con `applyDecoded`
/// (che spegne lo spinner). Sugli errori mostra il messaggio come testo.
/// Decodifica il file iniziale su un thread di background e lo installa nello
/// stato quando è pronto (azzerando lo spinner via `applyDecoded`). Sugli errori
/// mostra il messaggio come testo nella finestra invece di terminare il processo.
fn decodeInitial(state: *GuiAppState, path: []const u8) void {
    var d = decoder_mod.decode(path, state.io, state.gpa);
    if (d == .err) {
        const msg: []const u8 = std.fmt.allocPrint(state.gpa, "Errore nel caricamento del file:\n{s}", .{d.err}) catch "";
        d.deinit(state.gpa);
        state.applyDecoded(.{ .text = msg }, null, path) catch {};
        return;
    }
    state.applyDecoded(d, null, path) catch |e|
        std.debug.print("Impossibile applicare il file decodificato: {s}\n", .{@errorName(e)});
    // Contenuto iniziale pronto: precarica i vicini per una navigazione fluida.
    state.schedulePrefetchAround();
}

/// Thread di prefetch: decodifica (e stage-a, se mesh) i file vicini indicati da
/// `pf_want` nella cache `pf_cache`, evitando quelli già presenti ed evincendo
/// quelli non più desiderati (cache limitata ai 2 vicini). Fa SOLO decode+stage
/// (CPU/memfd): non tocca mai il renderer né lo stato condiviso della finestra.
fn prefetchWorker(state: *GuiAppState) void {
    const io = state.io;
    const gpa = state.gpa;
    // Soglia oltre cui NON precaricare (file enormi: lenti e pesanti in RAM;
    // tenerne 2 in cache gonfierebbe la memoria). Configurabile via env.
    const max_mb: u64 = blk: {
        if (getenv("ZUER_PREFETCH_MAX_MB")) |v| {
            if (std.fmt.parseInt(u64, std.mem.span(v), 10) catch null) |n| break :blk n;
        }
        break :blk 48;
    };
    while (true) {
        // Attende una richiesta (o lo stop) e ne prende una copia dei percorsi.
        state.pf_mutex.lockUncancelable(io);
        while (!state.pf_stop.* and state.pf_want[0] == null and state.pf_want[1] == null)
            state.pf_cond.waitUncancelable(io, state.pf_mutex);
        if (state.pf_stop.*) {
            state.pf_mutex.unlock(io);
            break;
        }
        var want: [2]?[]u8 = .{ null, null };
        for (&want, state.pf_want) |*w, src| w.* = if (src) |s| (gpa.dupe(u8, s) catch null) else null;
        // Evince dalla cache tutto ciò che non è più tra i vicini desiderati.
        var it = state.pf_cache.iterator();
        var to_evict: [8][]const u8 = undefined;
        var n_evict: usize = 0;
        while (it.next()) |entry| {
            const keep = wantContains(&want, entry.key_ptr.*);
            if (!keep and n_evict < to_evict.len) {
                to_evict[n_evict] = entry.key_ptr.*;
                n_evict += 1;
            }
        }
        for (to_evict[0..n_evict]) |k| {
            if (state.pf_cache.fetchRemove(k)) |kv| {
                var v = kv.value;
                v.deinit(gpa);
                gpa.free(kv.key);
            }
        }
        state.pf_mutex.unlock(io);
        defer for (want) |w| if (w) |x| gpa.free(x);

        // Decodifica (fuori dal lock) i vicini mancanti.
        for (want) |maybe_path| {
            const path = maybe_path orelse continue;
            state.pf_mutex.lockUncancelable(io);
            const already = state.pf_cache.contains(path) or state.pf_stop.*;
            state.pf_mutex.unlock(io);
            if (already) continue;

            // Salta i file troppo grandi (memoria) — verranno decodificati
            // sincronamente alla navigazione, come prima.
            if (fileSizeBytes(io, path)) |sz| {
                if (sz > max_mb * 1024 * 1024) continue;
            }

            var d = decoder_mod.decode(path, io, gpa);
            if (d == .err) {
                d.deinit(gpa);
                continue;
            }
            var pf = Prefetched{ .decoded = d };
            if (d == .mesh) pf.stage = loader_mod.stageToGpu(gpa, &pf.decoded);

            // Reinserisce solo se ancora desiderato e la richiesta non è cambiata.
            state.pf_mutex.lockUncancelable(io);
            const still_wanted = wantContains(state.pf_want, path) and !state.pf_stop.* and !state.pf_cache.contains(path);
            if (still_wanted) {
                const key = gpa.dupe(u8, path) catch {
                    state.pf_mutex.unlock(io);
                    pf.deinit(gpa);
                    continue;
                };
                state.pf_cache.put(gpa, key, pf) catch {
                    gpa.free(key);
                    state.pf_mutex.unlock(io);
                    pf.deinit(gpa);
                    continue;
                };
                state.pf_mutex.unlock(io);
            } else {
                state.pf_mutex.unlock(io);
                pf.deinit(gpa);
            }
        }
    }
}

fn wantContains(want: *const [2]?[]u8, path: []const u8) bool {
    for (want) |w| {
        if (w) |x| if (std.mem.eql(u8, x, path)) return true;
    }
    return false;
}

/// Dimensione del file in byte, o `null` se non stat-abile.
fn fileSizeBytes(io: std.Io, path: []const u8) ?u64 {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const st = f.stat(io) catch return null;
    return st.size;
}

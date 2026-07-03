//! zuer-gui — viewer GPU a finestra basato su zrame.
//!
//! Decodifica il file con gli stessi plugin di zuer, poi presenta in una
//! finestra Wayland zrame: le mesh sono rasterizzate dal renderer Vulkan
//! offscreen condiviso (`gpu_renderer.zig`), le immagini e testi sono
//! compositati a CPU; il frame finale RGBA viene inviato a zrame per la presentazione.

const std = @import("std");
const gpu = @import("gpu_renderer.zig");
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
const KEY_LEFTCTRL: u32 = 29;
const KEY_RIGHTCTRL: u32 = 97;

// Il testo viene ri-rasterizzato al pointsize scalato: oltre questi limiti la
// resa degrada (corpo minuscolo) o esplode in memoria (immagini enormi).
const text_zoom_min: f32 = 0.4;
const text_zoom_max: f32 = 6.0;
const scroll_step: f32 = 60.0;
const scrollbar_w: u32 = 14; // larghezza della scrollbar del testo (px)
const scroll_ease: f32 = 0.35; // frazione di avvicinamento a scroll_target per frame

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

/// Modalità documento per i contenuti testuali: l'immagine è già rasterizzata
/// alla larghezza della finestra, quindi si blitta 1:1 (nessun ricampionamento
/// che sfocherebbe il testo), ancorata in alto, con scorrimento verticale.
/// Geometria del blit del testo nella finestra: offset di scroll (clampato) e
/// centratura orizzontale. Condivisa da compose, selezione e scrollbar per non
/// divergere.
const BlitGeom = struct { off_y: u32, x_dst: u32, x_src: u32, copy_w: u32 };
fn textBlitGeom(W: u32, H: u32, src_w: u32, src_h: u32, scroll_y: f32) BlitGeom {
    const max_scroll: u32 = if (src_h > H) src_h - H else 0;
    return .{
        .off_y = @min(@as(u32, @intFromFloat(@max(scroll_y, 0))), max_scroll),
        // Se una rasterizzazione è in ritardo su un resize l'immagine può essere
        // più stretta o più larga della finestra: si centra senza scalare.
        .x_dst = if (src_w < W) (W - src_w) / 2 else 0,
        .x_src = if (src_w > W) (src_w - W) / 2 else 0,
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
) void {
    const geom = textBlitGeom(W, H, src_w, src_h, scroll_y);
    const off_y = geom.off_y;
    const x_dst = geom.x_dst;
    const x_src = geom.x_src;
    const copy_w = geom.copy_w;

    var py: u32 = 0;
    while (py < H) : (py += 1) {
        const idx_row = py * W * 4;
        const sy = py + off_y;
        var px: u32 = 0;
        while (px < W) : (px += 1) {
            const idx = idx_row + px * 4;
            if (sy < src_h and px >= x_dst and px < x_dst + copy_w) {
                const sx = px - x_dst + x_src;
                const s_idx = (sy * src_w + sx) * 4;
                const sr = src_rgba[s_idx + 0];
                const sg = src_rgba[s_idx + 1];
                const sb = src_rgba[s_idx + 2];
                var sa = src_rgba[s_idx + 3];
                if (sr == 8 and sg == 8 and sb == 16) {
                    sa = 0;
                }
                composited_rgba[idx + 0] = sr;
                composited_rgba[idx + 1] = sg;
                composited_rgba[idx + 2] = sb;
                composited_rgba[idx + 3] = sa;
            } else {
                composited_rgba[idx + 0] = 0;
                composited_rgba[idx + 1] = 0;
                composited_rgba[idx + 2] = 0;
                composited_rgba[idx + 3] = 0;
            }
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
fn drawTextSelection(buf: []u8, W: u32, H: u32, src_w: u32, src_h: u32, scroll_y: f32, m: text_render.Metrics, lines: []const []const u8, a_in: [2]i32, b_in: [2]i32) void {
    if (lines.len == 0 or m.advance <= 0 or m.line_h <= 0) return;
    const geom = textBlitGeom(W, H, src_w, src_h, scroll_y);
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
    const geom = textBlitGeom(W, H, state.static_w.*, state.static_h.*, state.scroll_y.*);
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

    var py: u32 = 0;
    while (py < H) : (py += 1) {
        const idx_row = py * W * 4;
        const iy = @as(i32, @intCast(py));
        var px: u32 = 0;
        while (px < W) : (px += 1) {
            const idx = idx_row + px * 4;
            const ix = @as(i32, @intCast(px));

            if (iy >= fit_y and iy < fit_y + @as(i32, @intCast(fit_h_zoomed)) and
                ix >= fit_x and ix < fit_x + @as(i32, @intCast(fit_w_zoomed)))
            {
                const sx = @as(u32, @intCast(@divFloor((ix - fit_x) * @as(i32, @intCast(src_w)), @as(i32, @intCast(fit_w_zoomed)))));
                const sy = @as(u32, @intCast(@divFloor((iy - fit_y) * @as(i32, @intCast(src_h)), @as(i32, @intCast(fit_h_zoomed)))));

                const bounded_sx = @min(sx, src_w - 1);
                const bounded_sy = @min(sy, src_h - 1);
                const s_idx = (bounded_sy * src_w + bounded_sx) * 4;

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
            } else {
                composited_rgba[idx + 0] = 0;
                composited_rgba[idx + 1] = 0;
                composited_rgba[idx + 2] = 0;
                composited_rgba[idx + 3] = 0;
            }
        }
    }
}

const GuiAppState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

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
    file_changed: *bool,
    // Incrementato a ogni load: il worker ri-rasterizza il testo solo quando
    // cambiano file, larghezza o zoom — mai per un semplice scroll.
    load_seq: *u32,
    zoom: *f32,
    static_rgba: *[]u8,
    static_w: *u32,
    static_h: *u32,
    mesh_center: *[3]f32,
    mesh_max_size: *f32,

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

    fn loadFile(self: *GuiAppState, new_path: []const u8) !void {
        // 1. Decodifica il nuovo file (fuori dal lock: non tocca stato condiviso)
        var new_decoded = decoder_mod.decode(new_path, self.io, self.gpa);
        if (new_decoded == .err) {
            std.debug.print("Errore nel caricamento del file {s}: {s}\n", .{ new_path, new_decoded.err });
            new_decoded.deinit(self.gpa);
            return;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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

        // 6. Aggiorna i dati per GPU/CPU. I contenuti testuali non vengono
        // rasterizzati qui: lo fa il thread di rendering alla larghezza
        // corrente della finestra, per una resa 1:1 nitida.
        if (self.is_mesh.*) {
            const m = self.decoded.mesh;
            self.stage_opt.* = loader_mod.stageToGpu(self.gpa, self.decoded) orelse return error.StageFailed;
            const stage = &self.stage_opt.*.?;
            try self.renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
            self.mesh_center.* = m.center;
            self.mesh_max_size.* = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
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

        self.loadFile(new_path) catch |err| {
            std.debug.print("Impossibile caricare il file: {s}\n", .{@errorName(err)});
            return;
        };
        self.current_file_index = next_idx;
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

fn keyCallback(win: *zrame.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const app_state: *GuiAppState = @ptrCast(@alignCast(user orelse return));
    const pressed = (state == 1);
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
        } else if (key == KEY_RIGHT or key == KEY_DOWN) {
            app_state.navigate(1);
        } else if (key == KEY_LEFT or key == KEY_UP) {
            app_state.navigate(-1);
        } else if (key == KEY_EQUAL) {
            applyZoom(app_state, 1.1);
        } else if (key == KEY_MINUS) {
            applyZoom(app_state, 1.0 / 1.1);
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
    if (axis == 0) {
        const val = @as(f32, @floatFromInt(value)) / 256.0;
        if (app_state.is_text.*) {
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

    var pacer_60 = zicro.time.Pacer.hz(state.io, 60.0);
    var pacer_20 = zicro.time.Pacer.hz(state.io, 20.0);

    while (!win.closed) {
        const cur_w = win.panel_w;
        const cur_h = win.panel_h;
        if (cur_w == 0 or cur_h == 0) {
            _ = pacer_20.tick();
            continue;
        }

        state.mutex.lockUncancelable(state.io);

        const size_changed = (cur_w != last_w or cur_h != last_h);
        var need_render = size_changed or state.file_changed.* or state.is_mesh.*;
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
                const pc = gpu.buildPushConstants(state.mesh_center.*, state.mesh_max_size.* / zoom.*, yaw.*, pitch.*, cur_w, cur_h);
                const mesh_rgba = state.renderer.render(cur_w, cur_h, &pc) catch {
                    state.mutex.unlock(state.io);
                    break;
                };
                composeFrame(composited_rgba.*, cur_w, cur_h, mesh_rgba, cur_w, cur_h, false, 1.0, 0.0, 0.0);
            } else if (state.is_text.*) {
                composeTextFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, state.scroll_y.*);
                if (state.sel_active.*) {
                    drawTextSelection(composited_rgba.*, cur_w, cur_h, state.static_w.*, state.static_h.*, state.scroll_y.*, state.text_metrics.*, state.text_lines.items, state.sel_a.*, state.sel_b.*);
                }
                drawScrollbar(composited_rgba.*, cur_w, cur_h, state.static_h.*, textBlitGeom(cur_w, cur_h, state.static_w.*, state.static_h.*, state.scroll_y.*).off_y);
            } else {
                composeFrame(composited_rgba.*, cur_w, cur_h, state.static_rgba.*, state.static_w.*, state.static_h.*, false, zoom.*, state.pan_x.*, state.pan_y.*);
            }

            win.presentRgba(cur_w, cur_h, composited_rgba.*);
        }

        const is_mesh = state.is_mesh.*;
        state.mutex.unlock(state.io);

        // 60 Hz per mesh (rotazione continua) e durante l'animazione dello
        // scroll testo; 20 Hz a riposo.
        if (is_mesh or text_animating) {
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

/// Dimensione iniziale della finestra. Per le immagini il frame si adatta al
/// contenuto (l'immagine lo riempie per intero), con un tetto a ~metà schermo:
/// zrame non espone la geometria dell'output, quindi il tetto è ZUER_MAX_WIN
/// (formato "LxA") oppure 1600x900.
fn initialWindowSize(is_image: bool, img_w: u32, img_h: u32) struct { w: u32, h: u32 } {
    if (!is_image or img_w == 0 or img_h == 0) return .{ .w = 1280, .h = 720 };

    var max_w: u32 = 1600;
    var max_h: u32 = 900;
    if (getenv("ZUER_MAX_WIN")) |val| {
        const s = std.mem.span(val);
        if (std.mem.indexOfScalar(u8, s, 'x')) |sep| {
            max_w = std.fmt.parseInt(u32, s[0..sep], 10) catch max_w;
            max_h = std.fmt.parseInt(u32, s[sep + 1 ..], 10) catch max_h;
        }
    }

    const fw: f32 = @floatFromInt(img_w);
    const fh: f32 = @floatFromInt(img_h);
    const scale = @min(1.0, @min(@as(f32, @floatFromInt(max_w)) / fw, @as(f32, @floatFromInt(max_h)) / fh));
    const w: u32 = @intFromFloat(@round(fw * scale));
    const h: u32 = @intFromFloat(@round(fh * scale));
    return .{ .w = @max(w, 320), .h = @max(h, 200) };
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
    const file_path = args.next() orelse {
        std.debug.print("Uso: zuer-gui <file>\n", .{});
        std.process.exit(1);
    };

    var decoded = decoder_mod.decode(file_path, io, gpa);
    defer decoded.deinit(gpa);
    if (decoded == .err) {
        std.debug.print("Errore: {s}\n", .{decoded.err});
        std.process.exit(1);
    }
    // I contenuti testuali (testo, markdown, csv, schede info) non vengono
    // rasterizzati qui: lo fa il thread di rendering alla larghezza reale
    // della finestra, così il testo è nitido e scorre come un documento.
    var is_text = (decoded != .mesh and decoded != .image);

    var stage_opt: ?loader_mod.GpuStage = null;
    defer if (stage_opt) |*s| s.buffer.deinit(gpa);

    // Renderer Vulkan Offscreen (nessuna estensione swapchain WSI richiesta)
    var renderer = try gpu.Renderer.init(gpa, .{});
    defer renderer.deinit();

    var mesh_center: [3]f32 = .{ 0, 0, 0 };
    var mesh_max_size: f32 = 1;
    var is_mesh = decoded == .mesh;

    var static_rgba: []u8 = &.{};
    defer gpa.free(static_rgba);
    var static_w: u32 = 0;
    var static_h: u32 = 0;

    if (is_mesh) {
        const m = decoded.mesh;
        stage_opt = loader_mod.stageToGpu(gpa, &decoded) orelse return error.StageFailed;
        const stage = &stage_opt.?;
        try renderer.setMesh(stage.buffer.ptr, stage.vertex_bytes, @intCast(stage.index_bytes / @sizeOf(u32)));
        mesh_center = m.center;
        mesh_max_size = @max(m.bbox_max[0] - m.bbox_min[0], @max(m.bbox_max[1] - m.bbox_min[1], m.bbox_max[2] - m.bbox_min[2]));
    } else if (decoded == .image) {
        const img = decoded.image;
        static_w = @intCast(img.width);
        static_h = @intCast(img.height);
        static_rgba = try gpa.alloc(u8, static_w * static_h * 4);
        for (0..static_w * static_h) |i| {
            static_rgba[i * 4 + 0] = img.pixels[i * 3 + 0];
            static_rgba[i * 4 + 1] = img.pixels[i * 3 + 1];
            static_rgba[i * 4 + 2] = img.pixels[i * 3 + 2];
            static_rgba[i * 4 + 3] = 255;
        }
    }

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
        .file_changed = &file_changed,
        .load_seq = &load_seq,
        .zoom = &zoom,
        .static_rgba = &static_rgba,
        .static_w = &static_w,
        .static_h = &static_h,
        .mesh_center = &mesh_center,
        .mesh_max_size = &mesh_max_size,
        .dragging = &dragging,
        .yaw = &yaw,
        .pitch = &pitch,
        .pan_x = &pan_x,
        .pan_y = &pan_y,
        .scroll_y = &scroll_y,
        .scroll_target = &scroll_target,
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
    };
    defer {
        gpa.free(gui_state.current_file_path);
        for (gui_state.file_list.items) |f| gpa.free(f);
        gui_state.file_list.deinit(gpa);
        for (text_lines.items) |l| gpa.free(l);
        text_lines.deinit(gpa);
    }
    try gui_state.initFileList();

    var composited_rgba: []u8 = &.{};
    defer gpa.free(composited_rgba);

    const win_size = initialWindowSize(decoded == .image, static_w, static_h);
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

    // Spawna il thread lavoratore per il rendering offscreen e compositing
    const thread = try std.Thread.spawn(.{}, renderWorker, .{ win, &gui_state, &composited_rgba, &yaw, &pitch, &zoom });
    defer thread.join();

    try win.run();
}

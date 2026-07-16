//! Esploratore file per zuer-gui (tasto `e`): overlay con griglia di card stile
//! Netflix — miniatura (decodificata in background dai plugin), nome file e
//! badge dimensione; le cartelle mostrano un'icona a cartella. Click sinistro su
//! una cartella la apre nella griglia, click DESTRO ne avvia l'anteprima
//! sfogliabile (primo file + frecce); su un file qualsiasi tasto del mouse apre
//! l'anteprima. Lo stato vive in `GuiAppState.Shared.fx` ed è protetto da
//! `shared.mutex` come l'overlay YouTube, di cui ricalca l'impianto (hover,
//! scrollbar, latest-wins sulla generazione per il worker delle miniature).

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const glyph = @import("glyph.zig");
const layout = @import("layout.zig");
const nav = @import("nav.zig");
const videomod = @import("video.zig");
const yt_search = @import("yt_search.zig");
const gui_state_mod = @import("gui_state.zig");
const GuiAppState = gui_state_mod.GuiAppState;
const zrame = @import("zrame");
const zicro = @import("zicro");
const paint = zicro.paint;
const build_options = @import("build_options");
const has_video = build_options.video;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Codici evdev, gli stessi di input.zig (privati lì).
const KEY_ESC: u32 = 1;
const KEY_BACKSPACE: u32 = 14;
const KEY_E: u32 = 18;
const KEY_ENTER: u32 = 28;
const KEY_UP: u32 = 103;
const KEY_PGUP: u32 = 104;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_DOWN: u32 = 108;
const KEY_PGDOWN: u32 = 109;

/// Tetto alle voci mostrate (cartelle sterminate) e ai file di cui tentare la
/// miniatura (ogni tentativo è un decode completo su thread di background).
const max_entries: usize = 512;
const max_thumb_files: usize = 96;
/// Oltre questa dimensione niente miniatura (decode lento/pesante in RAM).
const max_thumb_bytes: u64 = 256 * 1024 * 1024;

/// Una voce della cartella (stringhe e miniatura possedute, vedi `freeEntries`).
pub const Entry = struct {
    name: []u8,
    is_dir: bool,
    size: u64 = 0,
    /// Miniatura RGBA (vuota finché il thumb worker non la installa).
    thumb_rgba: []u8 = &.{},
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
    /// Il worker ha già tentato il decode (evita retry sui formati falliti).
    thumb_tried: bool = false,
};

/// Stato dell'overlay, dentro `Shared` (ogni accesso sotto `shared.mutex`).
pub const FxState = struct {
    active: bool = false,
    /// Cartella mostrata (posseduta; vuota = mai aperta).
    dir: []u8 = &.{},
    entries: []Entry = &.{},
    /// Card selezionata (-1 = nessuna).
    sel: i32 = -1,
    /// Prima riga di card visibile.
    row_off: i32 = 0,
    /// Generazione delle voci: il thumb worker installa solo se è ancora la sua.
    gen: u32 = 0,
    /// La selezione è appena cambiata da tastiera: lo scroll la insegue.
    follow_sel: bool = false,
    /// Trascinamento del thumb della scrollbar in corso.
    sb_drag: bool = false,
    /// Messaggio di stato (posseduto), sotto l'header. null = nessuno.
    err: ?[]u8 = null,
};

fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        gpa.free(e.name);
        gpa.free(e.thumb_rgba);
    }
    gpa.free(entries);
}

/// Libera tutto lo stato posseduto (a fine processo).
pub fn deinit(state: *GuiAppState) void {
    const fx = &state.shared.fx;
    freeEntries(state.gpa, fx.entries);
    fx.entries = &.{};
    state.gpa.free(fx.dir);
    fx.dir = &.{};
    if (fx.err) |e| state.gpa.free(e);
    fx.err = null;
}

/// Installa un messaggio di stato (copiato). Con `shared.mutex` acquisito.
fn setErr(state: *GuiAppState, msg: []const u8) void {
    const fx = &state.shared.fx;
    if (fx.err) |e| state.gpa.free(e);
    fx.err = state.gpa.dupe(u8, msg) catch null;
}

/// Chiude l'overlay liberando voci e miniature (decine di MB con le thumbnail
/// installate): alla riapertura la cartella viene comunque riscandita. Il bump
/// di generazione fa scartare al thumb worker ciò che ha ancora in volo.
/// Con `shared.mutex` acquisito.
fn closeOverlay(state: *GuiAppState) void {
    const fx = &state.shared.fx;
    fx.active = false;
    fx.sb_drag = false;
    fx.gen +%= 1;
    freeEntries(state.gpa, fx.entries);
    fx.entries = &.{};
    fx.sel = -1;
    fx.row_off = 0;
    if (fx.err) |e| {
        state.gpa.free(e);
        fx.err = null;
    }
    state.shared.file_changed = true;
}

// ── Scansione della cartella ─────────────────────────────────────────────────

/// Confronto case-insensitive (ASCII) tra nomi, per un ordine da file manager.
fn lessNameCi(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return la < lb;
    }
    return a.len < b.len;
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir; // cartelle prima
    return lessNameCi(a.name, b.name);
}

/// Scandisce `dir_path` e installa la griglia (attivando l'overlay). La scansione
/// avviene FUORI dal lock (il lock si prende solo per lo swap); ritorna false se
/// la cartella non è apribile (lo stato precedente resta in piedi).
fn enterDir(state: *GuiAppState, dir_path: []const u8) bool {
    var list: std.ArrayList(Entry) = .empty;
    var truncated = false;
    {
        var dir = std.Io.Dir.cwd().openDir(state.io, dir_path, .{ .iterate = true }) catch {
            state.shared.mutex.lockUncancelable(state.io);
            if (state.shared.fx.active) {
                setErr(state, "cartella inaccessibile");
                state.shared.file_changed = true;
            }
            state.shared.mutex.unlock(state.io);
            return false;
        };
        defer dir.close(state.io);
        var it = dir.iterate();
        while (it.next(state.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue; // nascosti
            const is_dir = entry.kind == .directory;
            if (!is_dir and entry.kind != .file) continue;
            if (list.items.len >= max_entries) {
                truncated = true;
                break;
            }
            // NIENTE statFile qui: siamo sul thread finestra e su Windows ogni
            // stat apre un handle (500 voci = secondi, peggio sotto Wine). Le
            // dimensioni le riempie il thumb worker (fillSizes) in background.
            const name = state.gpa.dupe(u8, entry.name) catch break;
            list.append(state.gpa, .{ .name = name, .is_dir = is_dir }) catch {
                state.gpa.free(name);
                break;
            };
        }
    }
    std.mem.sort(Entry, list.items, {}, entryLess);
    const owned: []Entry = list.toOwnedSlice(state.gpa) catch {
        for (list.items) |e| {
            state.gpa.free(e.name);
            state.gpa.free(e.thumb_rgba);
        }
        list.deinit(state.gpa);
        return false;
    };
    const dir_copy = state.gpa.dupe(u8, dir_path) catch {
        freeEntries(state.gpa, owned);
        return false;
    };

    state.shared.mutex.lockUncancelable(state.io);
    const fx = &state.shared.fx;
    fx.gen +%= 1;
    const gen = fx.gen;
    freeEntries(state.gpa, fx.entries);
    fx.entries = owned;
    state.gpa.free(fx.dir);
    fx.dir = dir_copy;
    fx.sel = if (owned.len > 0) 0 else -1;
    fx.row_off = 0;
    fx.active = true;
    fx.sb_drag = false;
    if (fx.err) |e| {
        state.gpa.free(e);
        fx.err = null;
    }
    if (truncated) setErr(state, "cartella grande: mostrate solo le prime 512 voci");
    state.shared.file_changed = true;
    state.shared.mutex.unlock(state.io);

    const t = std.Thread.spawn(.{}, thumbWorker, .{ state, gen }) catch return true;
    t.detach();
    return true;
}

/// Apre l'esploratore sulla cartella del file corrente, con fallback su $HOME
/// e infine sulla cwd (il "file corrente" può essere un titolo YouTube).
fn openExplorerFrom(state: *GuiAppState, cur_path: []const u8) void {
    if (std.fs.path.dirname(cur_path)) |d| {
        if (enterDir(state, d)) return;
    }
    if (getenv("HOME") orelse getenv("USERPROFILE")) |h| {
        if (enterDir(state, std.mem.span(h))) return;
    }
    _ = enterDir(state, ".");
}

// ── Apertura di file e cartelle ──────────────────────────────────────────────

/// Ricostruisce `file_list` (navigazione con le frecce) sui file di `dir_path`,
/// posizionando l'indice su `cur_name`. Stesso filtro/ordine di `initFileList`.
/// Lo swap avviene sotto `shared.mutex`: `schedulePrefetchAround` legge la lista
/// dai thread loader sotto lo stesso lock.
fn setFileListForDir(state: *GuiAppState, dir_path: []const u8, cur_name: []const u8) void {
    var names: std.ArrayList([]const u8) = .empty;
    {
        var dir = std.Io.Dir.cwd().openDir(state.io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(state.io);
        var it = dir.iterate();
        while (it.next(state.io) catch null) |entry| {
            if (entry.kind == .file and entry.name.len > 0 and entry.name[0] != '.') {
                const name = state.gpa.dupe(u8, entry.name) catch break;
                names.append(state.gpa, name) catch {
                    state.gpa.free(name);
                    break;
                };
            }
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    state.shared.mutex.lockUncancelable(state.io);
    for (state.file_list.items) |n| state.gpa.free(n);
    state.file_list.deinit(state.gpa);
    state.file_list = names;
    state.current_file_index = null;
    for (state.file_list.items, 0..) |f, idx| {
        if (std.mem.eql(u8, f, cur_name)) {
            state.current_file_index = idx;
            break;
        }
    }
    state.shared.mutex.unlock(state.io);
}

/// Anteprima di un file: chiude l'overlay, aggancia le frecce alla sua cartella
/// e posta il caricamento asincrono (spinner + decode su thread loader).
fn openFile(state: *GuiAppState, full_path: []const u8) void {
    setFileListForDir(state, std.fs.path.dirname(full_path) orelse ".", std.fs.path.basename(full_path));
    state.shared.mutex.lockUncancelable(state.io);
    closeOverlay(state);
    state.shared.mutex.unlock(state.io);
    nav.postLoad(state, full_path);
}

/// Anteprima di una CARTELLA (click destro): apre il suo primo file e aggancia
/// le frecce alla cartella, come lanciare `zuer-gui <cartella>`.
fn previewFolder(state: *GuiAppState, dir_path: []const u8) void {
    const first = (nav.resolveInitialFile(state.io, state.gpa, dir_path) catch null) orelse {
        state.shared.mutex.lockUncancelable(state.io);
        setErr(state, "nessun file da mostrare nella cartella");
        state.shared.file_changed = true;
        state.shared.mutex.unlock(state.io);
        return;
    };
    defer state.gpa.free(first);
    openFile(state, first);
}

/// Azione decisa sotto lock ed eseguita DOPO il rilascio (scansioni e postLoad
/// fanno I/O: mai tenerci sotto `shared.mutex`).
const Action = enum { none, open_explorer, enter_dir, open_file, preview_folder };

fn runAction(state: *GuiAppState, act: Action, path: []u8) void {
    defer state.gpa.free(path);
    switch (act) {
        .open_explorer => openExplorerFrom(state, path),
        .enter_dir => _ = enterDir(state, path),
        .open_file => openFile(state, path),
        .preview_folder => previewFolder(state, path),
        .none => {},
    }
}

// ── Tastiera ─────────────────────────────────────────────────────────────────

/// Tasti dell'esploratore. Ritorna true se consumato: a overlay chiuso solo `e`
/// (lo apre); aperto, TUTTA la tastiera è sua (Esc/e chiudono, frecce muovono
/// la selezione, Invio apre, Backspace sale alla cartella padre).
pub fn handleKey(state: *GuiAppState, key: u32) bool {
    var act: Action = .none;
    var act_path: ?[]u8 = null;
    {
        state.shared.mutex.lockUncancelable(state.io);
        defer state.shared.mutex.unlock(state.io);
        const fx = &state.shared.fx;
        if (!fx.active) {
            if (key == KEY_E and !state.ctrl_down) {
                act = .open_explorer;
                act_path = state.gpa.dupe(u8, state.shared.current_file_path) catch null;
            } else return false;
        } else switch (key) {
            KEY_ESC, KEY_E => closeOverlay(state),
            KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT => {
                const n: i32 = @intCast(fx.entries.len);
                if (n > 0) {
                    const step: i32 = switch (key) {
                        KEY_LEFT => -1,
                        KEY_RIGHT => 1,
                        KEY_UP => -grid_cols,
                        else => grid_cols,
                    };
                    fx.sel = std.math.clamp(fx.sel + step, 0, n - 1);
                    fx.follow_sel = true;
                    state.shared.file_changed = true;
                }
            },
            KEY_PGUP, KEY_PGDOWN => {
                const n: i32 = @intCast(fx.entries.len);
                if (n > 0) {
                    const step: i32 = 3 * grid_cols;
                    fx.sel = std.math.clamp(fx.sel + (if (key == KEY_PGDOWN) step else -step), 0, n - 1);
                    fx.follow_sel = true;
                    state.shared.file_changed = true;
                }
            },
            KEY_ENTER => {
                if (fx.sel >= 0 and fx.sel < @as(i32, @intCast(fx.entries.len))) {
                    const e = fx.entries[@intCast(fx.sel)];
                    act = if (e.is_dir) .enter_dir else .open_file;
                    act_path = std.fs.path.join(state.gpa, &.{ fx.dir, e.name }) catch null;
                }
            },
            KEY_BACKSPACE => {
                if (std.fs.path.dirname(fx.dir)) |parent| {
                    act = .enter_dir;
                    act_path = state.gpa.dupe(u8, parent) catch null;
                }
            },
            else => {},
        }
    }
    if (act_path) |p| runAction(state, act, p);
    return true;
}

// ── Geometria della griglia (stessa impostazione dell'overlay YouTube) ───────

pub const grid_cols: i32 = 4;
const pad: i32 = 14;
const gap: i32 = 10;
const header_h: i32 = 40;
const title_strip_h: i32 = 24;
const status_h: i32 = 20;
const panel_top: i32 = 24;

const Layout = struct {
    xp: i32,
    yp: i32,
    wp: i32,
    hp: i32,
    grid_x: i32,
    grid_y: i32,
    card_w: i32,
    thumb_h: i32,
    card_h: i32,
    total_rows: i32,
    vis_rows: i32,
};

fn layoutFor(W: u32, H: u32, n: usize, status: bool) Layout {
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const wp: i32 = @min(wi - 32, 1080);
    const xp = @divTrunc(wi - wp, 2);
    const card_w = @divTrunc(wp - pad * 2 - gap * (grid_cols - 1), grid_cols);
    const thumb_h = @divTrunc(card_w * 9, 16);
    const card_h = thumb_h + title_strip_h;
    const st: i32 = if (status) status_h else 0;
    const total_rows: i32 = @intCast((n + @as(usize, @intCast(grid_cols)) - 1) / @as(usize, @intCast(grid_cols)));
    const avail = hi - panel_top - pad * 2 - header_h - st - gap;
    var vis = @max(@as(i32, 1), @divTrunc(avail, card_h + gap));
    vis = @min(vis, @max(total_rows, 1));
    const rows_shown = if (total_rows == 0) 0 else vis;
    const hp = pad * 2 + header_h + st + (if (rows_shown > 0) gap + rows_shown * (card_h + gap) - gap else 0);
    return .{
        .xp = xp,
        .yp = panel_top,
        .wp = wp,
        .hp = hp,
        .grid_x = xp + pad,
        .grid_y = panel_top + pad + header_h + st + gap,
        .card_w = card_w,
        .thumb_h = thumb_h,
        .card_h = card_h,
        .total_rows = total_rows,
        .vis_rows = vis,
    };
}

fn cardRect(lay: Layout, row_off: i32, i: usize) ?[4]i32 {
    const idx: i32 = @intCast(i);
    const row = @divTrunc(idx, grid_cols);
    const col = @mod(idx, grid_cols);
    if (row < row_off or row >= row_off + lay.vis_rows) return null;
    const x = lay.grid_x + col * (lay.card_w + gap);
    const y = lay.grid_y + (row - row_off) * (lay.card_h + gap);
    return .{ x, y, lay.card_w, lay.card_h };
}

/// Dimensioni del frame presentato: col player attivo è il fit-rect (zrame
/// consegna il mouse già nel suo spazio), altrimenti il content rect.
fn overlayDims(state: *GuiAppState, win: *zrame.Window) [2]u32 {
    const cpx = win.contentPx();
    if (has_video and state.video.isActive()) {
        const fr = videomod.videoFitRect(cpx.w, cpx.h, state.shared.static_w, state.shared.static_h);
        return .{ fr.w, fr.h };
    }
    return .{ cpx.w, cpx.h };
}

fn scrollbarGeom(lay: Layout) ?[4]i32 {
    if (lay.total_rows <= lay.vis_rows) return null;
    const h = lay.vis_rows * (lay.card_h + gap) - gap;
    return .{ lay.xp + lay.wp - 11, lay.grid_y, 7, h };
}

fn scrollbarThumb(lay: Layout, sb: [4]i32, row_off: i32) [2]i32 {
    const track_h = sb[3];
    const th = @max(@as(i32, 24), @divTrunc(track_h * lay.vis_rows, lay.total_rows));
    const max_off = @max(lay.total_rows - lay.vis_rows, 1);
    const ty = sb[1] + @divTrunc((track_h - th) * std.math.clamp(row_off, 0, max_off), max_off);
    return .{ ty, th };
}

fn rowOffFromY(lay: Layout, sb: [4]i32, my: f32) i32 {
    const th = scrollbarThumb(lay, sb, 0)[1];
    const span: f32 = @floatFromInt(@max(sb[3] - th, 1));
    const rel = (my - @as(f32, @floatFromInt(sb[1]))) - @as(f32, @floatFromInt(th)) / 2.0;
    const max_off: f32 = @floatFromInt(@max(lay.total_rows - lay.vis_rows, 0));
    const off: i32 = @intFromFloat(@round(std.math.clamp(rel / span, 0.0, 1.0) * max_off));
    return off;
}

// ── Input mouse ──────────────────────────────────────────────────────────────

/// Rotella a overlay attivo: scorre la griglia di una riga per scatto.
pub fn handleWheel(state: *GuiAppState, win: *zrame.Window, axis: u32, value: i32) bool {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const fx = &state.shared.fx;
    if (!fx.active) return false;
    if (axis != 0 or value == 0) return true;
    const dims = overlayDims(state, win);
    const lay = layoutFor(dims[0], dims[1], fx.entries.len, fx.err != null);
    const step: i32 = if (value > 0) 1 else -1;
    const max_off = @max(lay.total_rows - lay.vis_rows, 0);
    const new_off = std.math.clamp(fx.row_off + step, 0, max_off);
    if (new_off != fx.row_off) {
        fx.row_off = new_off;
        state.shared.file_changed = true;
    }
    return true;
}

/// Mouse a overlay attivo: hover seleziona la card; su una CARTELLA il click
/// sinistro entra e il destro avvia l'anteprima sfogliabile; su un FILE
/// qualsiasi tasto apre l'anteprima. Click fuori dal pannello chiude.
pub fn handleMouse(state: *GuiAppState, win: *zrame.Window, event: zrame.MouseEvent) bool {
    var act: Action = .none;
    var act_path: ?[]u8 = null;
    var consumed = true;
    {
        state.shared.mutex.lockUncancelable(state.io);
        defer state.shared.mutex.unlock(state.io);
        const fx = &state.shared.fx;
        if (!fx.active) return false;

        const dims = overlayDims(state, win);
        const lay = layoutFor(dims[0], dims[1], fx.entries.len, fx.err != null);
        const sb = scrollbarGeom(lay);

        switch (event) {
            .motion => |mot| {
                state.last_x = mot.x;
                state.last_y = mot.y;
                if (fx.sb_drag) {
                    if (sb) |bar| {
                        const off = rowOffFromY(lay, bar, mot.y);
                        if (off != fx.row_off) {
                            fx.row_off = off;
                            state.shared.file_changed = true;
                        }
                    }
                } else for (fx.entries, 0..) |_, i| {
                    const rc = cardRect(lay, fx.row_off, i) orelse continue;
                    if (mot.x >= @as(f32, @floatFromInt(rc[0])) and mot.x < @as(f32, @floatFromInt(rc[0] + rc[2])) and
                        mot.y >= @as(f32, @floatFromInt(rc[1])) and mot.y < @as(f32, @floatFromInt(rc[1] + rc[3])))
                    {
                        if (fx.sel != @as(i32, @intCast(i))) {
                            fx.sel = @intCast(i);
                            state.shared.file_changed = true;
                        }
                        break;
                    }
                }
            },
            .button => |btn| {
                // 0x110/0x111/0x112 = sinistro/destro/centrale.
                const known = btn.button == 0x110 or btn.button == 0x111 or btn.button == 0x112;
                if (btn.state != 1) {
                    fx.sb_drag = false;
                } else if (known) hit: {
                    const mx = state.last_x;
                    const my = state.last_y;
                    if (btn.button == 0x110) {
                        if (sb) |bar| {
                            if (mx >= @as(f32, @floatFromInt(bar[0] - 4)) and mx < @as(f32, @floatFromInt(bar[0] + bar[2] + 4)) and
                                my >= @as(f32, @floatFromInt(bar[1])) and my < @as(f32, @floatFromInt(bar[1] + bar[3])))
                            {
                                fx.sb_drag = true;
                                fx.row_off = rowOffFromY(lay, bar, my);
                                state.shared.file_changed = true;
                                break :hit;
                            }
                        }
                    }
                    for (fx.entries, 0..) |e, i| {
                        const rc = cardRect(lay, fx.row_off, i) orelse continue;
                        if (mx >= @as(f32, @floatFromInt(rc[0])) and mx < @as(f32, @floatFromInt(rc[0] + rc[2])) and
                            my >= @as(f32, @floatFromInt(rc[1])) and my < @as(f32, @floatFromInt(rc[1] + rc[3])))
                        {
                            fx.sel = @intCast(i);
                            state.shared.file_changed = true;
                            act = if (!e.is_dir)
                                .open_file
                            else if (btn.button == 0x111)
                                .preview_folder
                            else
                                .enter_dir;
                            act_path = std.fs.path.join(state.gpa, &.{ fx.dir, e.name }) catch null;
                            break :hit;
                        }
                    }
                    // Click fuori dal pannello: chiudi l'overlay.
                    const inside = mx >= @as(f32, @floatFromInt(lay.xp)) and mx < @as(f32, @floatFromInt(lay.xp + lay.wp)) and
                        my >= @as(f32, @floatFromInt(lay.yp)) and my < @as(f32, @floatFromInt(lay.yp + lay.hp));
                    if (!inside) closeOverlay(state);
                }
            },
            .leave => consumed = false,
        }
    }
    if (act_path) |p| runAction(state, act, p);
    return consumed;
}

// ── Miniature ────────────────────────────────────────────────────────────────

fn extEqCi(ext: []const u8, comptime lit: []const u8) bool {
    if (ext.len != lit.len) return false;
    for (ext, lit) |c, l| {
        if (std.ascii.toLower(c) != l) return false;
    }
    return true;
}

/// Formati per cui tentare la miniatura: immagini, video (poster del plugin
/// media) e PDF (prima pagina). Testo/tabelle/mesh restano sul segnaposto.
fn thumbable(name: []const u8) bool {
    switch (layout.winKindFromExt(name)) {
        .image, .video => return true,
        else => {},
    }
    return extEqCi(decoder_mod.getExtension(name), "pdf");
}

/// Downscale RGB→RGBA con media per area (campionata) entro `thumb_max`²: le
/// decodifiche GUI arrivano fino a 4096² e a piena risoluzione peserebbero
/// ~64 MB l'una nella griglia.
const thumb_max: usize = 512;

fn makeThumb(gpa: std.mem.Allocator, pixels: []const u8, sw: usize, sh: usize) ?struct { rgba: []u8, w: u32, h: u32 } {
    if (sw == 0 or sh == 0 or pixels.len < sw * sh * 3) return null;
    const fw: f32 = @floatFromInt(sw);
    const fh: f32 = @floatFromInt(sh);
    const fmax: f32 = @floatFromInt(thumb_max);
    const s = @min(1.0, @min(fmax / fw, fmax / fh));
    const dw = @max(1, @as(usize, @intFromFloat(@round(fw * s))));
    const dh = @max(1, @as(usize, @intFromFloat(@round(fh * s))));

    const rgba = gpa.alignedAlloc(u8, .@"4", dw * dh * 4) catch return null;
    for (0..dh) |dy| {
        const y0 = dy * sh / dh;
        const y1 = @max(y0 + 1, (dy + 1) * sh / dh);
        const step_y = @max(1, (y1 - y0) / 4); // max ~4 campioni per asse
        for (0..dw) |dx| {
            const x0 = dx * sw / dw;
            const x1 = @max(x0 + 1, (dx + 1) * sw / dw);
            const step_x = @max(1, (x1 - x0) / 4);
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var cnt: u32 = 0;
            var sy = y0;
            while (sy < y1) : (sy += step_y) {
                var sx = x0;
                while (sx < x1) : (sx += step_x) {
                    const o = (sy * sw + sx) * 3;
                    r += pixels[o];
                    g += pixels[o + 1];
                    b += pixels[o + 2];
                    cnt += 1;
                }
            }
            const o = (dy * dw + dx) * 4;
            rgba[o] = @intCast(r / cnt);
            rgba[o + 1] = @intCast(g / cnt);
            rgba[o + 2] = @intCast(b / cnt);
            rgba[o + 3] = 255;
        }
    }
    return .{ .rgba = rgba, .w = @intCast(dw), .h = @intCast(dh) };
}

/// Fase dimensioni del thumb worker: le `statFile` avvengono qui, fuori dal
/// thread finestra, e i risultati sono installati per indice sotto lock (le
/// voci non cambiano entro la stessa generazione). Va eseguita PRIMA delle
/// miniature: il guard `size > max_thumb_bytes` legge questi valori.
fn fillSizes(state: *GuiAppState, gen: u32) void {
    const Pending = struct { idx: usize, name: []u8 };
    var dir_copy: []u8 = &.{};
    var names: std.ArrayList(Pending) = .empty;
    defer {
        for (names.items) |n| state.gpa.free(n.name);
        names.deinit(state.gpa);
        state.gpa.free(dir_copy);
    }
    {
        // Snapshot di cartella e nomi file sotto lock (poche KB, niente I/O).
        state.shared.mutex.lockUncancelable(state.io);
        defer state.shared.mutex.unlock(state.io);
        const fx = &state.shared.fx;
        if (gen != fx.gen) return;
        dir_copy = state.gpa.dupe(u8, fx.dir) catch return;
        for (fx.entries, 0..) |e, i| {
            if (e.is_dir) continue;
            const nm = state.gpa.dupe(u8, e.name) catch return;
            names.append(state.gpa, .{ .idx = i, .name = nm }) catch {
                state.gpa.free(nm);
                return;
            };
        }
    }
    if (names.items.len == 0) return;

    var dir = std.Io.Dir.cwd().openDir(state.io, dir_copy, .{}) catch return;
    defer dir.close(state.io);
    const sizes = state.gpa.alloc(u64, names.items.len) catch return;
    defer state.gpa.free(sizes);
    for (names.items, sizes) |n, *sz| {
        sz.* = if (dir.statFile(state.io, n.name, .{})) |st| st.size else |_| 0;
    }

    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const fx = &state.shared.fx;
    if (gen != fx.gen) return;
    for (names.items, sizes) |n, sz| {
        if (n.idx < fx.entries.len) fx.entries[n.idx].size = sz;
    }
    state.shared.file_changed = true;
}

/// Thread miniature: decodifica in sequenza i file "thumbabili" della
/// generazione `gen` coi normali plugin decoder e installa il risultato
/// downscalato. Ogni installazione ricontrolla la generazione sotto lock.
fn thumbWorker(state: *GuiAppState, gen: u32) void {
    fillSizes(state, gen);
    var i: usize = 0;
    var attempts: usize = 0;
    while (attempts < max_thumb_files) : (i += 1) {
        // Snapshot del percorso sotto lock; il decode avviene fuori.
        state.shared.mutex.lockUncancelable(state.io);
        const fx = &state.shared.fx;
        if (gen != fx.gen or i >= fx.entries.len) {
            state.shared.mutex.unlock(state.io);
            return;
        }
        const e = &fx.entries[i];
        if (e.is_dir or e.thumb_tried or e.thumb_w != 0 or e.size > max_thumb_bytes or !thumbable(e.name)) {
            state.shared.mutex.unlock(state.io);
            continue;
        }
        e.thumb_tried = true;
        const full = std.fs.path.join(state.gpa, &.{ fx.dir, e.name }) catch {
            state.shared.mutex.unlock(state.io);
            return;
        };
        const name = state.gpa.dupe(u8, e.name) catch {
            state.gpa.free(full);
            state.shared.mutex.unlock(state.io);
            return;
        };
        state.shared.mutex.unlock(state.io);
        defer state.gpa.free(full);
        defer state.gpa.free(name);
        attempts += 1;

        var d = decoder_mod.decode(full, state.io, state.gpa);
        defer d.deinit(state.gpa);
        if (d != .image) continue;
        const th = makeThumb(state.gpa, d.image.pixels, d.image.width, d.image.height) orelse continue;

        state.shared.mutex.lockUncancelable(state.io);
        const fx2 = &state.shared.fx;
        if (gen != fx2.gen) {
            state.shared.mutex.unlock(state.io);
            state.gpa.free(th.rgba);
            return;
        }
        // Riaggancio per nome (l'array non cambia entro la stessa generazione,
        // ma il controllo tiene il worker onesto).
        var installed = false;
        for (fx2.entries) |*en| {
            if (std.mem.eql(u8, en.name, name)) {
                if (en.thumb_w == 0) {
                    en.thumb_rgba = th.rgba;
                    en.thumb_w = th.w;
                    en.thumb_h = th.h;
                    installed = true;
                }
                break;
            }
        }
        state.shared.file_changed = true;
        state.shared.mutex.unlock(state.io);
        if (!installed) state.gpa.free(th.rgba);
    }
}

// ── Disegno dell'overlay ─────────────────────────────────────────────────────

const panel_bg = paint.Color.rgba(13, 15, 22, 0.94);
const card_bg = paint.Color.rgba(26, 30, 41, 0.98);
const thumb_bg = paint.Color.rgba(16, 19, 27, 1.0);
const sel_accent = paint.Color.rgba(120, 160, 255, 0.95);
const header_bg = paint.Color.rgba(28, 32, 44, 0.9);
const badge_bg = paint.Color.rgba(0, 0, 0, 0.72);
const folder_body = paint.Color.rgba(222, 168, 62, 0.95);
const folder_tab = paint.Color.rgba(240, 190, 84, 0.95);
const text_fg = [3]u8{ 235, 238, 245 };
const text_dim = [3]u8{ 150, 158, 175 };
const text_err = [3]u8{ 240, 180, 110 };

/// Tinta del segnaposto per tipo di contenuto (file senza miniatura).
fn kindColor(name: []const u8) paint.Color {
    if (extEqCi(decoder_mod.getExtension(name), "pdf")) return paint.Color.rgba(150, 62, 56, 0.95);
    return switch (layout.winKindFromExt(name)) {
        .image => paint.Color.rgba(44, 116, 108, 0.95),
        .video => paint.Color.rgba(96, 66, 148, 0.95),
        .table => paint.Color.rgba(146, 100, 42, 0.95),
        .mesh => paint.Color.rgba(52, 118, 70, 0.95),
        .document, .generic => paint.Color.rgba(52, 62, 84, 0.95),
    };
}

/// Dimensione umana ("3.4 MB") in `buf`.
fn fmtSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var ui: usize = 0;
    v /= 1024.0;
    while (v >= 1024.0 and ui < units.len - 1) : (ui += 1) v /= 1024.0;
    if (v < 10.0) return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[ui] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[ui] }) catch "";
}

fn countCps(text: []const u8) i32 {
    var cols: i32 = 0;
    var view = std.unicode.Utf8View.init(text) catch return @intCast(text.len);
    var it = view.iterator();
    while (it.nextCodepoint()) |_| cols += 1;
    return cols;
}

/// Disegna l'overlay dell'esploratore sul frame corrente (`W`×`H`). Da chiamare
/// con `shared.mutex` acquisito e solo se `fx.active`.
pub fn drawOverlay(buf: []u8, W: u32, H: u32, state: *GuiAppState, raster: *glyph.Raster) void {
    if (W < 160 or H < 160) return;
    const fx = &state.shared.fx;

    const status = fx.err != null;
    const lay = layoutFor(W, H, fx.entries.len, status);

    // Scroll a inseguimento della selezione (solo da tastiera, come YouTube).
    if (fx.follow_sel and fx.sel >= 0) {
        const sel_row = @divTrunc(fx.sel, grid_cols);
        if (sel_row < fx.row_off) fx.row_off = sel_row;
        if (sel_row >= fx.row_off + lay.vis_rows) fx.row_off = sel_row - lay.vis_rows + 1;
    }
    fx.follow_sel = false;
    fx.row_off = std.math.clamp(fx.row_off, 0, @max(lay.total_rows - lay.vis_rows, 0));

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);

    const line_h = raster.ascent - raster.descent;

    canvas.fillRoundedRect(@floatFromInt(lay.xp), @floatFromInt(lay.yp), @floatFromInt(lay.wp), @floatFromInt(lay.hp), 14.0, panel_bg);
    canvas.fillRoundedRect(@floatFromInt(lay.xp + pad), @floatFromInt(lay.yp + pad), @floatFromInt(lay.wp - pad * 2), @floatFromInt(header_h), 9.0, header_bg);

    // Header: conteggio a destra, percorso a sinistra (troncato dalla TESTA:
    // della cartella conta la coda del percorso).
    const head_base = lay.yp + pad + @divTrunc(header_h - line_h, 2) + raster.ascent;
    var cnt_buf: [32]u8 = undefined;
    const cnt_txt = std.fmt.bufPrint(&cnt_buf, "{d} voci", .{fx.entries.len}) catch "";
    const cnt_w = countCps(cnt_txt) * raster.advance;
    _ = yt_search.drawText(buf, W, H, raster, lay.xp + lay.wp - pad - 12 - cnt_w, head_base, cnt_txt, text_dim, cnt_w + 4);

    const path_x = lay.xp + pad + 12;
    const path_max_w = lay.wp - pad * 2 - 24 - cnt_w - 16;
    if (raster.advance > 0) {
        const max_cols = @divTrunc(path_max_w, raster.advance);
        var shown: []const u8 = fx.dir;
        var prefix: []const u8 = "";
        const cols = countCps(fx.dir);
        if (cols > max_cols and max_cols > 1) {
            // Salta i codepoint in testa finché il resto (più "…") non entra.
            var to_skip = cols - (max_cols - 1);
            var idx: usize = 0;
            var view = std.unicode.Utf8View.init(fx.dir) catch null;
            if (view) |*v| {
                var it = v.iterator();
                while (to_skip > 0) : (to_skip -= 1) {
                    if (it.nextCodepoint() == null) break;
                    idx = it.i;
                }
            }
            shown = fx.dir[idx..];
            prefix = "…";
        }
        var pen = path_x;
        pen += yt_search.drawText(buf, W, H, raster, pen, head_base, prefix, text_dim, path_max_w);
        _ = yt_search.drawText(buf, W, H, raster, pen, head_base, shown, text_fg, path_max_w - (pen - path_x));
    }

    // Riga di stato (avvisi: cartella vuota/inaccessibile/troncata).
    if (fx.err) |e| {
        const sy = lay.yp + pad + header_h;
        const sbase = sy + @divTrunc(status_h - line_h, 2) + raster.ascent;
        _ = yt_search.drawText(buf, W, H, raster, path_x, sbase, e, text_err, lay.wp - pad * 2 - 24);
    }

    // Griglia di card: miniatura (o segnaposto/cartella), nome, badge dimensione.
    for (fx.entries, 0..) |e, i| {
        const rc = cardRect(lay, fx.row_off, i) orelse continue;
        const x = rc[0];
        const y = rc[1];

        if (@as(i32, @intCast(i)) == fx.sel) {
            canvas.fillRoundedRect(@floatFromInt(x - 3), @floatFromInt(y - 3), @floatFromInt(lay.card_w + 6), @floatFromInt(lay.card_h + 6), 10.0, sel_accent);
        }
        canvas.fillRoundedRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(lay.card_w), @floatFromInt(lay.card_h), 8.0, card_bg);

        const tw = lay.card_w - 2;
        const th = lay.thumb_h - 1;
        if (e.is_dir) {
            // Cartella: icona disegnata (linguetta + corpo) centrata nella miniatura.
            canvas.fillRoundedRect(@floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(tw), @floatFromInt(th), 8.0, thumb_bg);
            const fw: i32 = @divTrunc(tw * 2, 5);
            const fh: i32 = @divTrunc(fw * 3, 4);
            const fx0 = x + 1 + @divTrunc(tw - fw, 2);
            const fy0 = y + 1 + @divTrunc(th - fh, 2);
            const tab_h = @max(6, @divTrunc(fh, 5));
            canvas.fillRoundedRect(@floatFromInt(fx0), @floatFromInt(fy0), @floatFromInt(@divTrunc(fw * 2, 5)), @floatFromInt(tab_h * 2), 5.0, folder_tab);
            canvas.fillRoundedRect(@floatFromInt(fx0), @floatFromInt(fy0 + tab_h), @floatFromInt(fw), @floatFromInt(fh - tab_h), 6.0, folder_body);
        } else if (e.thumb_w != 0) {
            // Miniatura in aspect-fit su fondo scuro (mai stirata).
            canvas.fillRoundedRect(@floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(tw), @floatFromInt(th), 8.0, thumb_bg);
            const sw: f32 = @floatFromInt(e.thumb_w);
            const sh: f32 = @floatFromInt(e.thumb_h);
            const s = @min(@as(f32, @floatFromInt(tw)) / sw, @as(f32, @floatFromInt(th)) / sh);
            const dw: i32 = @intFromFloat(@round(sw * s));
            const dh: i32 = @intFromFloat(@round(sh * s));
            const dx = x + 1 + @divTrunc(tw - dw, 2);
            const dy = y + 1 + @divTrunc(th - dh, 2);
            yt_search.blitThumb(buf, W, H, dx, dy, dw, dh, e.thumb_rgba, e.thumb_w, e.thumb_h);
        } else {
            // Segnaposto: tinta per tipo + estensione al centro.
            canvas.fillRoundedRect(@floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(tw), @floatFromInt(th), 8.0, kindColor(e.name));
            var ext_buf: [8]u8 = undefined;
            const ext = decoder_mod.getExtension(e.name);
            var n: usize = 0;
            while (n < ext.len and n < ext_buf.len) : (n += 1) ext_buf[n] = std.ascii.toUpper(ext[n]);
            const ext_txt: []const u8 = if (n > 0) ext_buf[0..n] else "FILE";
            const ex = x + 1 + @divTrunc(tw - countCps(ext_txt) * raster.advance, 2);
            const ebase = y + 1 + @divTrunc(th - line_h, 2) + raster.ascent;
            _ = yt_search.drawText(buf, W, H, raster, ex, ebase, ext_txt, text_fg, tw);
        }

        // Badge dimensione in basso a destra (solo file).
        if (!e.is_dir and e.size > 0) {
            var sz_buf: [24]u8 = undefined;
            const sz = fmtSize(&sz_buf, e.size);
            const bw = countCps(sz) * raster.advance + 10;
            const bh = line_h + 4;
            const bx = x + lay.card_w - bw - 6;
            const by = y + lay.thumb_h - bh - 6;
            canvas.fillRoundedRect(@floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), @floatFromInt(bh), 4.0, badge_bg);
            _ = yt_search.drawText(buf, W, H, raster, bx + 5, by + 2 + raster.ascent, sz, text_fg, bw);
        }

        // Striscia nome sotto la miniatura.
        const tbase = y + lay.thumb_h + @divTrunc(title_strip_h - line_h, 2) + raster.ascent;
        _ = yt_search.drawText(buf, W, H, raster, x + 8, tbase, e.name, text_fg, lay.card_w - 16);
    }

    // Scrollbar della griglia (solo se c'è altro da sfogliare).
    if (scrollbarGeom(lay)) |sb| {
        canvas.fillRoundedRect(@floatFromInt(sb[0]), @floatFromInt(sb[1]), @floatFromInt(sb[2]), @floatFromInt(sb[3]), 3.5, paint.Color.rgba(255, 255, 255, 0.10));
        const th = scrollbarThumb(lay, sb, fx.row_off);
        canvas.fillRoundedRect(@floatFromInt(sb[0]), @floatFromInt(th[0]), @floatFromInt(sb[2]), @floatFromInt(th[1]), 3.5, paint.Color.rgba(255, 255, 255, if (fx.sb_drag) 0.65 else 0.38));
    }
}

// ── Stress test TEMPORANEO (ZUER_FX_TEST=1): niente input reale ──────────────
// Pilota l'overlay dagli stessi entry point del thread finestra: apre
// l'explorer, alterna cartelle (churn di generazioni + thumb worker) e misura
// enterDir. DA RIMUOVERE a diagnosi conclusa.

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn nowMs() i64 {
    if (comptime @import("builtin").os.tag == .windows) {
        return @intCast(GetTickCount64());
    } else {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
}

fn testSleep(state: *GuiAppState, ms: u64) void {
    std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

pub fn stressTest(state: *GuiAppState) void {
    testSleep(state, 2000); // finestra su e primo file caricato
    std.debug.print("[fx-test] via\n", .{});
    _ = handleKey(state, KEY_E); // apre l'explorer sulla cartella corrente
    testSleep(state, 400);

    var iter: usize = 0;
    while (iter < 60) : (iter += 1) {
        // Movimento selezione (repaint sotto churn di miniature).
        _ = handleKey(state, KEY_RIGHT);
        _ = handleKey(state, KEY_DOWN);
        _ = handleKey(state, KEY_LEFT);
        // Invio: entra nella cartella selezionata o apre l'anteprima del file.
        var t0 = nowMs();
        _ = handleKey(state, KEY_ENTER);
        std.debug.print("[fx-test] iter {d} enter: {d} ms\n", .{ iter, nowMs() - t0 });
        testSleep(state, (iter * 7) % 90); // fase variabile vs thumb worker
        // Se l'Invio ha aperto un file l'overlay è chiuso: riaprilo.
        {
            state.shared.mutex.lockUncancelable(state.io);
            const was_active = state.shared.fx.active;
            state.shared.mutex.unlock(state.io);
            if (!was_active) _ = handleKey(state, KEY_E);
        }
        t0 = nowMs();
        _ = handleKey(state, KEY_BACKSPACE); // sale alla cartella padre
        std.debug.print("[fx-test] iter {d} up: {d} ms\n", .{ iter, nowMs() - t0 });
        testSleep(state, (iter * 13) % 40);
        if (iter % 9 == 8) { // ogni tanto chiudi e riapri l'overlay
            _ = handleKey(state, KEY_ESC);
            testSleep(state, 30);
            _ = handleKey(state, KEY_E);
        }
    }
    std.debug.print("[fx-test] fine senza crash\n", .{});
}

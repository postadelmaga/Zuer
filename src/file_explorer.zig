//! Esploratore file per zuer-gui (tasto `e`): overlay con griglia di card stile
//! Netflix — miniatura (decodificata in background dai plugin), nome file e
//! badge dimensione; le cartelle mostrano un'icona a cartella. Click sinistro su
//! una cartella la apre nella griglia, click DESTRO ne avvia l'anteprima
//! sfogliabile (primo file + frecce); su un file qualsiasi tasto del mouse apre
//! l'anteprima. Lo stato vive in `GuiAppState.Shared.fx` ed è protetto da
//! `shared.mutex` come l'overlay YouTube, di cui ricalca l'impianto (hover,
//! scrollbar, latest-wins sulla generazione per il worker delle miniature).

const std = @import("std");
const builtin = @import("builtin");
const decoder_mod = @import("decoder.zig");
const thumbs = @import("thumbs.zig");
const glyph = @import("glyph.zig");
const layout = @import("layout.zig");
const nav = @import("nav.zig");
const videomod = @import("video.zig");
const yt_search = @import("yt_search.zig");
const card_grid = @import("card_grid.zig");
const gui_state_mod = @import("gui_state.zig");
const vtcache = @import("vtcache.zig");
const unicode_path = @import("unicode_path.zig");
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

// Il motore delle miniature (voci, claim, cache, job) sta in thumbs.zig.
pub const Entry = thumbs.Entry;
pub const FxState = thumbs.FxState;
const freeEntries = thumbs.freeEntries;
const extEqCi = thumbs.extEqCi;
const max_entries = thumbs.max_entries;
pub const grid_cols = thumbs.grid_cols;

/// La pipeline delle miniature vista dalla GUI: stato e mutex condivisi.
fn thumbHost(state: *GuiAppState) thumbs.Host {
    return .{
        .io = state.io,
        .gpa = state.gpa,
        .mutex = &state.shared.mutex,
        .fx = &state.shared.fx,
        .changed = &state.shared.file_changed,
    };
}

/// Libera tutto lo stato posseduto (a fine processo). Sotto lock e con un
/// cambio di generazione: un job delle miniature ancora in corso su un worker
/// (lo scheduler si ferma dopo) vede la generazione superata e non tocca più
/// le voci liberate qui.
pub fn deinit(state: *GuiAppState) void {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const fx = &state.shared.fx;
    _ = fx.bumpGeneration();
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

/// Chiude l'overlay TENENDO voci e miniature della cartella corrente: con
/// `thumb_max` a 256 il costo massimo è `max_thumb_files` × 256² × 4 B ≈ 24 MB,
/// e la riapertura sulla stessa cartella le ritrova pronte (`enterDir` le
/// trasferisce per nome, vedi `adoptThumbs`) invece di ridecodificare tutto.
/// La memoria torna al sistema al primo `enterDir` su un'ALTRA cartella (o a
/// `deinit`). Il bump di generazione ferma comunque il thumb worker: a overlay
/// chiuso non deve consumare CPU. Con `shared.mutex` acquisito.
fn closeOverlay(state: *GuiAppState) void {
    const fx = &state.shared.fx;
    fx.active = false;
    _ = fx.scroll.onRelease();
    _ = fx.bumpGeneration();
    fx.sel = -1;
    fx.scroll.reset();
    fx.top_row = 0;
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

/// Trasferisce alle voci `new` le miniature già in RAM delle voci `old` con lo
/// stesso nome (riapertura del pannello sulla stessa cartella, o `enterDir`
/// ripetuto). Entrambe le liste sono ordinate con `entryLess`: basta una
/// fusione lineare. Le voci `old` cedute restano con `thumb_rgba` vuoto, così
/// `freeEntries` non libera un buffer ora posseduto da `new`.
/// Ritorna quante miniature sono passate (riparte da lì il budget RAM).
fn adoptThumbs(old: []Entry, new: []Entry) u32 {
    var i: usize = 0;
    var j: usize = 0;
    var moved: u32 = 0;
    while (i < old.len and j < new.len) {
        const o = &old[i];
        const w = &new[j];
        if (entryLess({}, o.*, w.*)) {
            i += 1;
            continue;
        }
        if (entryLess({}, w.*, o.*)) {
            j += 1;
            continue;
        }
        // Stessa posizione d'ordine: `lessNameCi` ignora il case, quindi il
        // nome esatto va confrontato comunque ("ABC" e "abc" convivono).
        if (o.is_dir == w.is_dir and std.mem.eql(u8, o.name, w.name)) {
            w.size = o.size;
            w.mtime_ns = o.mtime_ns;
            w.thumb_tried = o.thumb_tried;
            w.cache_tried = o.cache_tried;
            if (o.thumb_w != 0) {
                w.thumb_rgba = o.thumb_rgba;
                w.thumb_w = o.thumb_w;
                w.thumb_h = o.thumb_h;
                o.thumb_rgba = &.{};
                o.thumb_w = 0;
                moved += 1;
            }
        }
        i += 1;
        j += 1;
    }
    return moved;
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
    // Il bump di generazione è la CANCELLAZIONE del worker precedente: quello
    // in volo esce al primo check (prima di ogni decode) senza installare nulla.
    const gen = fx.bumpGeneration();
    // Stessa cartella (riapertura del pannello dopo `closeOverlay`, o rientro):
    // le miniature già decodificate passano alle nuove voci invece di essere
    // buttate. Sotto lock: il worker tocca le voci solo con lo stesso mutex.
    const kept: u32 = if (std.mem.eql(u8, fx.dir, dir_path)) adoptThumbs(fx.entries, owned) else 0;
    freeEntries(state.gpa, fx.entries);
    fx.entries = owned;
    fx.thumb_installed = kept;
    fx.thumb_attempts = 0;
    state.gpa.free(fx.dir);
    fx.dir = dir_copy;
    fx.sel = if (owned.len > 0) 0 else -1;
    fx.scroll.reset();
    fx.top_row = 0;
    fx.active = true;
    _ = fx.scroll.onRelease();
    if (fx.err) |e| {
        state.gpa.free(e);
        fx.err = null;
    }
    if (truncated) setErr(state, "cartella grande: mostrate solo le prime 512 voci");
    state.shared.file_changed = true;
    state.shared.mutex.unlock(state.io);

    thumbs.start(thumbHost(state), gen);
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

    // Fuori dal lock: col nome in un'altra forma Unicode il confronto fa stat.
    const cur_idx = nav.indexOfFile(state.io, dir_path, names.items, cur_name);

    state.shared.mutex.lockUncancelable(state.io);
    for (state.file_list.items) |n| state.gpa.free(n);
    state.file_list.deinit(state.gpa);
    state.file_list = names;
    state.current_file_index = cur_idx;
    state.shared.mutex.unlock(state.io);
}

/// Anteprima di un file: chiude l'overlay, aggancia le frecce alla sua cartella
/// e posta il caricamento asincrono (spinner + decode su thread loader).
fn openFile(state: *GuiAppState, full_path: []const u8) void {
    const dir = std.fs.path.dirname(full_path) orelse ".";
    const base = std.fs.path.basename(full_path);
    setFileListForDir(state, dir, base);
    // Si apre il nome come lo elenca la cartella: se il percorso aveva gli accenti in
    // un'altra forma Unicode (vedi `nav.indexOfFile`) è lo stesso file, ma la forma del
    // disco è quella giusta per l'etichetta e per le frecce.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    state.shared.mutex.lockUncancelable(state.io);
    const path = blk: {
        const idx = state.current_file_index orelse break :blk full_path;
        const listed = state.file_list.items[idx];
        if (std.mem.eql(u8, listed, base)) break :blk full_path;
        break :blk std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, listed }) catch full_path;
    };
    closeOverlay(state);
    state.shared.mutex.unlock(state.io);
    nav.postLoad(state, path);
}

/// Percorso chiesto dal sistema (macOS: doppio clic nel Finder, "Apri con", drop
/// sull'icona del Dock — l'app parte senza argv e il file arriva dopo, come Apple
/// Event): come lanciare `zuer-gui <percorso>`. Chiude gli overlay (anche la ricerca
/// YouTube, aperta da sé all'avvio senza file); una cartella apre il suo primo file.
pub fn openFromSystem(state: *GuiAppState, path: []const u8) void {
    state.shared.mutex.lockUncancelable(state.io);
    const yt = &state.shared.yt;
    if (yt.active) {
        yt.active = false;
        yt.bs_held = false;
        _ = yt.scroll.onRelease();
        state.shared.file_changed = true;
    }
    state.shared.mutex.unlock(state.io);
    const io = state.io;
    var found: ?[]u8 = null;
    defer if (found) |f| state.gpa.free(f);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |e| retry: {
        // Non trovato: forse ha gli accenti in un'altra forma Unicode di com'è sul
        // disco. Da macOS (e da Darling) arrivano sempre decomposti; su un filesystem
        // che confronta i byte serve il nome com'è salvato (vedi unicode_path.zig).
        var why: anyerror = e;
        if (e == error.FileNotFound) {
            if (unicode_path.findEquivalent(io, state.gpa, path)) |f| {
                found = f;
                std.debug.print("[gui] file dal sistema ritrovato in un'altra forma Unicode: {s}\n", .{f});
                if (std.Io.Dir.cwd().statFile(io, f, .{})) |s| break :retry s else |e2| why = e2;
            } else |fe| why = fe;
        }
        std.debug.print("[gui] file dal sistema illeggibile: {s} ({s})\n", .{ path, @errorName(why) });
        var buf: [std.fs.max_path_bytes + 160]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}:\n{s}", .{ switch (why) {
            error.FileNotFound => "File non trovato",
            error.AmbiguousName => "Più file con questo nome, con gli accenti in forme Unicode diverse: non ne scelgo uno",
            else => "File non leggibile",
        }, path }) catch "File non trovato";
        nav.showMessage(state, path, msg);
        return;
    };
    const real = found orelse path;
    if (st.kind == .directory) previewFolder(state, real) else openFile(state, real);
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

/// Geometria verticale della griglia, per lo scroll.
fn geom(lay: Layout) card_grid.Geom {
    return .{
        .grid_x = lay.grid_x,
        .grid_y = lay.grid_y,
        .right = lay.xp + lay.wp - 3, // la scrollbar flottante sta nel margine del pannello
        .card_h = lay.card_h,
        .gap = gap,
        .total_rows = lay.total_rows,
        .vis_rows = lay.vis_rows,
    };
}

/// Rettangolo intero della card `i` spostato dallo scroll in pixel, o null se
/// nemmeno un pixel cade nella banda visibile. Può sporgere dalla banda: chi
/// disegna taglia alla banda, chi fa hit-test usa `cardHit`.
fn cardRect(lay: Layout, scroll: f32, i: usize) ?[4]i32 {
    const idx: i32 = @intCast(i);
    const row = @divTrunc(idx, grid_cols);
    const col = @mod(idx, grid_cols);
    const y = geom(lay).rowY(scroll, row) orelse return null;
    return .{ lay.grid_x + col * (lay.card_w + gap), y, lay.card_w, lay.card_h };
}

/// Il punto (x,y) cade sulla parte VISIBILE della card `i`?
fn cardHit(lay: Layout, scroll: f32, i: usize, x: f32, y: f32) bool {
    const rc = cardRect(lay, scroll, i) orelse return false;
    return geom(lay).inBand(y) and x >= @as(f32, @floatFromInt(rc[0])) and x < @as(f32, @floatFromInt(rc[0] + rc[2])) and
        y >= @as(f32, @floatFromInt(rc[1])) and y < @as(f32, @floatFromInt(rc[1] + rc[3]));
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

// ── Input mouse ──────────────────────────────────────────────────────────────

/// Rotella a overlay attivo: scorre la griglia col passo di zicro, con l'easing
/// applicato al disegno (come la griglia YouTube).
pub fn handleWheel(state: *GuiAppState, win: *zrame.Window, axis: u32, value: f32) bool {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const fx = &state.shared.fx;
    if (!fx.active) return false;
    if (axis != 0 or value == 0) return true;
    _ = win; // la geometria la allinea il prossimo disegno (`GridScroll.tick`)
    fx.scroll.sc.wheel(.vertical, value);
    state.shared.file_changed = true;
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

        switch (event.kind) {
            .motion => {
                state.last_x = event.x;
                state.last_y = event.y;
                const m = fx.scroll.onMotion(geom(lay), event.x, event.y);
                if (m.redraw) state.shared.file_changed = true;
                // Sulla scrollbar o in drag: niente hover sulle card.
                if (!m.consumed) {
                    for (fx.entries, 0..) |_, i| {
                        if (cardHit(lay, fx.scroll.pos(), i, event.x, event.y)) {
                            if (fx.sel != @as(i32, @intCast(i))) {
                                fx.sel = @intCast(i);
                                state.shared.file_changed = true;
                            }
                            break;
                        }
                    }
                }
            },
            .press, .release => {
                // 0x110/0x111/0x112 = sinistro/destro/centrale.
                const known = event.button == 0x110 or event.button == 0x111 or event.button == 0x112;
                if (event.kind != .press) {
                    if (fx.scroll.onRelease()) state.shared.file_changed = true; // fine del drag
                } else if (known) hit: {
                    const mx = state.last_x;
                    const my = state.last_y;
                    // Sinistro sulla scrollbar: prende il thumb (o lo porta lì) e inizia il drag.
                    if (event.button == 0x110 and fx.scroll.onPress(geom(lay), mx, my)) {
                        state.shared.file_changed = true;
                        break :hit;
                    }
                    for (fx.entries, 0..) |e, i| {
                        if (cardHit(lay, fx.scroll.pos(), i, mx, my)) {
                            fx.sel = @intCast(i);
                            state.shared.file_changed = true;
                            act = if (!e.is_dir)
                                .open_file
                            else if (event.button == 0x111)
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
            .leave => {
                fx.scroll.sc.onLeave(); // la scrollbar torna a riposo
                state.shared.file_changed = true;
                consumed = false;
            },
            .scroll => consumed = false, // la rotella passa da `handleWheel`
        }
    }
    if (act_path) |p| runAction(state, act, p);
    return consumed;
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

    // Scroll a inseguimento della selezione (solo da tastiera, come YouTube):
    // la card selezionata entra intera nella banda.
    if (fx.follow_sel and fx.sel >= 0) fx.scroll.revealRow(geom(lay), @divTrunc(fx.sel, grid_cols));
    fx.follow_sel = false;
    if (fx.scroll.tick(geom(lay), zrame.widget.nowMs())) state.shared.file_changed = true; // easing o dissolvenza in corso: un altro frame
    fx.top_row = fx.scroll.topRow(geom(lay));

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
    // Tutto tagliato alla banda (più i 3 px del bordo di selezione): le card a
    // metà dello scroll escono dal bordo alto e basso.
    const clip_y0 = lay.grid_y - 3;
    const clip_y1 = lay.grid_y + geom(lay).bandH() + 3;
    const saved_clip = canvas.setClip(0, @intCast(@max(clip_y0, 0)), W, @intCast(@max(clip_y1 - @max(clip_y0, 0), 0)));
    defer canvas.clip = saved_clip;
    for (fx.entries, 0..) |e, i| {
        const rc = cardRect(lay, fx.scroll.pos(), i) orelse continue;
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
            yt_search.blitThumbClip(buf, W, H, dx, dy, dw, dh, e.thumb_rgba, e.thumb_w, e.thumb_h, clip_y0, clip_y1);
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
            _ = yt_search.drawTextClip(buf, W, H, raster, ex, ebase, ext_txt, text_fg, tw, clip_y0, clip_y1);
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
            _ = yt_search.drawTextClip(buf, W, H, raster, bx + 5, by + 2 + raster.ascent, sz, text_fg, bw, clip_y0, clip_y1);
        }

        // Striscia nome sotto la miniatura.
        const tbase = y + lay.thumb_h + @divTrunc(title_strip_h - line_h, 2) + raster.ascent;
        _ = yt_search.drawTextClip(buf, W, H, raster, x + 8, tbase, e.name, text_fg, lay.card_w - 16, clip_y0, clip_y1);
    }

    // Scrollbar flottante di zicro, come quella del testo.
    canvas.clip = saved_clip;
    fx.scroll.sc.draw(&canvas);
}

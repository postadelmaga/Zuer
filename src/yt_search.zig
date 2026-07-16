//! Ricerca YouTube per zuer-gui: overlay (tasto `y`) con campo query e griglia
//! di risultati stile Netflix (card con miniatura, titolo e durata). Click o
//! Invio aprono il video in streaming nel player nativo (libav). La ricerca,
//! le miniature (curl → `~/.cache/zuer/ytthumb`) e la risoluzione degli URL
//! passano da `yt-dlp` su thread di background (`decoder.runCaptureTimeout`);
//! lo stato dell'overlay vive in `GuiAppState.Shared` ed è protetto da
//! `shared.mutex` come il resto (thread finestra scrive, render worker disegna,
//! i worker installano i risultati con latest-wins sulla generazione).

const std = @import("std");
const decoder_mod = @import("decoder.zig");
const glyph = @import("glyph.zig");
const clipboard = @import("clipboard.zig");
const videomod = @import("video.zig");
const gui_state_mod = @import("gui_state.zig");
const GuiAppState = gui_state_mod.GuiAppState;
const zrame = @import("zrame");
const zicro = @import("zicro");
const paint = zicro.paint;
const build_options = @import("build_options");
const has_video = build_options.video;
const builtin = @import("builtin");
const vtcache = @import("vtcache.zig");

/// Un risultato di ricerca (stringhe e miniatura possedute, vedi `freeResults`).
pub const Result = struct {
    id: []u8,
    title: []u8,
    duration: []u8,
    channel: []u8,
    /// Miniatura RGBA (vuota finché il thumb worker non la installa).
    thumb_rgba: []u8 = &.{},
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
};

/// Stato dell'overlay, dentro `Shared` (ogni accesso sotto `shared.mutex`).
pub const YtState = struct {
    active: bool = false,
    /// Query corrente (byte UTF-8 così come digitati).
    query: std.ArrayList(u8) = .empty,
    results: []Result = &.{},
    /// Card selezionata nella griglia (-1 = nessuna).
    sel: i32 = -1,
    /// Prima riga di card visibile (la griglia scorre seguendo la selezione).
    row_off: i32 = 0,
    /// Ricerca yt-dlp in corso (spinner nel campo).
    searching: bool = false,
    /// Risoluzione/apertura dello stream in corso.
    opening: bool = false,
    /// Messaggio d'errore (posseduto), mostrato sotto il campo. null = nessuno.
    err: ?[]u8 = null,
    /// Generazione di ricerca/risultati: i worker (search e thumb) installano
    /// solo se è ancora la loro (latest-wins, come `Nav.gen`).
    gen: u32 = 0,
    /// Il tasto `y` che ha aperto l'overlay produce anche un evento testo
    /// (`on_text` è additivo a `on_key`): va inghiottito una volta.
    swallow_text: bool = false,
    /// Ctrl+A: query tutta selezionata (il prossimo input la rimpiazza).
    sel_all: bool = false,
    /// Backspace fisicamente premuto: il render worker genera l'autorepeat
    /// (zrame non sintetizza il key-repeat di Wayland).
    bs_held: bool = false,
    /// La selezione è appena cambiata da tastiera: al prossimo draw lo scroll
    /// la insegue (l'hover del mouse e la rotella NON la inseguono).
    follow_sel: bool = false,
    /// Trascinamento del thumb della scrollbar in corso.
    sb_drag: bool = false,
};

pub fn freeResults(gpa: std.mem.Allocator, results: []Result) void {
    for (results) |r| {
        gpa.free(r.id);
        gpa.free(r.title);
        gpa.free(r.duration);
        gpa.free(r.channel);
        gpa.free(r.thumb_rgba);
    }
    gpa.free(results);
}

/// Libera tutto lo stato posseduto (a fine processo).
pub fn deinit(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    yt.query.deinit(state.gpa);
    freeResults(state.gpa, yt.results);
    yt.results = &.{};
    if (yt.err) |e| state.gpa.free(e);
    yt.err = null;
}

/// Svuota risultati/errore correnti (dopo una modifica alla query i vecchi
/// risultati non corrispondono più) e brucia la generazione così i worker in
/// volo (search/thumb) buttano ciò che portano. Con `shared.mutex` acquisito.
pub fn invalidateResults(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    yt.gen +%= 1;
    freeResults(state.gpa, yt.results);
    yt.results = &.{};
    yt.sel = -1;
    yt.row_off = 0;
    if (yt.err) |e| state.gpa.free(e);
    yt.err = null;
}

/// Installa un messaggio d'errore (copiato). Con `shared.mutex` acquisito.
fn setErr(state: *GuiAppState, msg: []const u8) void {
    const yt = &state.shared.yt;
    if (yt.err) |e| state.gpa.free(e);
    yt.err = state.gpa.dupe(u8, msg) catch null;
}

// ── Editing della textbox ────────────────────────────────────────────────────

/// Inserisce testo nella query (digitazione o incolla). Con Ctrl+A attivo il
/// nuovo testo RIMPIAZZA la selezione. Con `shared.mutex` acquisito.
pub fn insertText(state: *GuiAppState, bytes: []const u8) void {
    const yt = &state.shared.yt;
    if (yt.sel_all) {
        yt.query.clearRetainingCapacity();
        yt.sel_all = false;
    }
    if (yt.query.items.len + bytes.len > 256) return; // query oltre ogni ragionevolezza
    yt.query.appendSlice(state.gpa, bytes) catch return;
    invalidateResults(state);
    state.shared.file_changed = true;
}

/// Una cancellazione di Backspace: con Ctrl+A attivo svuota la query, altrimenti
/// rimuove l'ultimo codepoint UTF-8. Usata dal key handler (pressione) e dal
/// render worker (autorepeat). Con `shared.mutex` acquisito.
pub fn backspaceOnce(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    if (yt.sel_all) {
        if (yt.query.items.len == 0) {
            yt.sel_all = false;
            return;
        }
        yt.query.clearRetainingCapacity();
        yt.sel_all = false;
    } else {
        const q = &yt.query;
        if (q.items.len == 0) return;
        // Rimuove l'ultimo codepoint UTF-8 (i byte continuazione 10xxxxxx).
        var i = q.items.len - 1;
        while (i > 0 and (q.items[i] & 0xC0) == 0x80) i -= 1;
        q.shrinkRetainingCapacity(i);
    }
    invalidateResults(state);
    state.shared.file_changed = true;
}

/// Ctrl+C: copia la query negli appunti. La copia (wl-copy + waitpid) avviene su
/// un thread così il lock non resta tenuto per un subprocess.
pub fn copyQuery(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    if (yt.query.items.len == 0) return;
    const txt = state.gpa.dupe(u8, yt.query.items) catch return;
    const t = std.Thread.spawn(.{}, copyWorker, .{ state, txt }) catch {
        state.gpa.free(txt);
        return;
    };
    t.detach();
}

fn copyWorker(state: *GuiAppState, txt: []u8) void {
    clipboard.copy(txt);
    state.gpa.free(txt);
}

/// Ctrl+V: incolla dagli appunti (wl-paste o clipboard Win32, su thread).
/// Con `shared.mutex` acquisito.
pub fn startPaste(state: *GuiAppState) void {
    const t = std.Thread.spawn(.{}, pasteWorker, .{state}) catch return;
    t.detach();
}

fn pasteWorker(state: *GuiAppState) void {
    const raw: []u8 = if (comptime builtin.os.tag == .windows)
        clipboard.pasteAlloc(state.gpa) orelse return
    else raw: {
        var res = decoder_mod.runCaptureTimeout(state.gpa, &.{ "wl-paste", "-n" }, 2_000) catch return;
        defer res.deinit(state.gpa);
        if (res.exit_code != 0 or res.stdout.len == 0) return;
        break :raw state.gpa.dupe(u8, res.stdout) catch return;
    };
    defer state.gpa.free(raw);
    // Una query è una riga sola: newline/tab diventano spazi, il resto dei
    // caratteri di controllo sparisce.
    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(state.gpa);
    for (raw) |ch| {
        if (ch == '\n' or ch == '\r' or ch == '\t') {
            clean.append(state.gpa, ' ') catch return;
        } else if (ch >= 0x20) { // include i byte di continuazione UTF-8 (>= 0x80)
            clean.append(state.gpa, ch) catch return;
        }
    }
    const trimmed = std.mem.trim(u8, clean.items, " ");
    if (trimmed.len == 0) return;

    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    if (!state.shared.yt.active) return;
    insertText(state, trimmed);
}

// ── Ricerca ──────────────────────────────────────────────────────────────────

const search_max = 12;

/// Avvia la ricerca della query corrente su un thread di background.
/// Da chiamare con `shared.mutex` acquisito (thread finestra, Invio).
pub fn startSearch(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    if (yt.query.items.len == 0 or yt.searching) return;
    const q = state.gpa.dupe(u8, yt.query.items) catch return;
    invalidateResults(state);
    yt.searching = true;
    state.shared.file_changed = true;
    const t = std.Thread.spawn(.{}, searchWorker, .{ state, q, yt.gen }) catch {
        state.gpa.free(q);
        yt.searching = false;
        setErr(state, "impossibile avviare la ricerca");
        return;
    };
    t.detach();
}

/// Thread di ricerca: `yt-dlp ytsearchN:` in flat-playlist, un risultato per
/// riga con campi separati da tab (i "\t" nel template sono tab REALI, scritti
/// da Zig nella argv: yt-dlp li stampa tali e quali). Prende possesso di `query`.
fn searchWorker(state: *GuiAppState, query: []u8, gen: u32) void {
    defer state.gpa.free(query);

    const spec = std.fmt.allocPrint(state.gpa, "ytsearch{d}:{s}", .{ search_max, query }) catch return;
    defer state.gpa.free(spec);

    var res = decoder_mod.runCaptureTimeout(state.gpa, &.{
        "yt-dlp",
        "--no-warnings",
        "--flat-playlist",
        "--print",
        "%(id)s\t%(title).96s\t%(duration_string)s\t%(channel).40s",
        spec,
    }, 25_000) catch |e| {
        finishSearchErr(state, gen, if (e == error.Timeout) "ricerca scaduta (rete?)" else "yt-dlp non eseguibile");
        return;
    };
    defer res.deinit(state.gpa);
    if (res.exit_code != 0) {
        finishSearchErr(state, gen, "ricerca fallita (yt-dlp)");
        return;
    }

    var list: std.ArrayList(Result) = .empty;
    var lines = std.mem.tokenizeScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, line, "\r"), '\t');
        const id = fields.next() orelse continue;
        const title = fields.next() orelse continue;
        const dur = fields.next() orelse "";
        const chan = fields.next() orelse "";
        if (id.len == 0) continue;
        const rid = state.gpa.dupe(u8, id) catch continue;
        const rtitle = state.gpa.dupe(u8, if (title.len > 0) title else "(senza titolo)") catch {
            state.gpa.free(rid);
            continue;
        };
        const rdur = state.gpa.dupe(u8, if (std.mem.eql(u8, dur, "NA")) "" else dur) catch {
            state.gpa.free(rid);
            state.gpa.free(rtitle);
            continue;
        };
        const rchan = state.gpa.dupe(u8, if (std.mem.eql(u8, chan, "NA")) "" else chan) catch {
            state.gpa.free(rid);
            state.gpa.free(rtitle);
            state.gpa.free(rdur);
            continue;
        };
        list.append(state.gpa, .{ .id = rid, .title = rtitle, .duration = rdur, .channel = rchan }) catch {
            state.gpa.free(rid);
            state.gpa.free(rtitle);
            state.gpa.free(rdur);
            state.gpa.free(rchan);
            continue;
        };
    }
    const owned: []Result = list.toOwnedSlice(state.gpa) catch &.{};

    var installed = false;
    {
        state.shared.mutex.lockUncancelable(state.io);
        defer state.shared.mutex.unlock(state.io);
        const yt = &state.shared.yt;
        if (gen != yt.gen) {
            // Superata da una ricerca più recente: butta tutto.
            freeResults(state.gpa, owned);
            return;
        }
        freeResults(state.gpa, yt.results);
        yt.results = owned;
        yt.sel = if (owned.len > 0) 0 else -1;
        yt.row_off = 0;
        yt.searching = false;
        if (owned.len == 0) setErr(state, "nessun risultato");
        state.shared.file_changed = true;
        installed = owned.len > 0;
    }
    // Miniature in coda, fuori dal lock: un worker le scarica e le installa una
    // per una (la griglia si riempie progressivamente).
    if (installed) {
        const t = std.Thread.spawn(.{}, thumbWorker, .{ state, gen }) catch return;
        t.detach();
    }
}

fn finishSearchErr(state: *GuiAppState, gen: u32, msg: []const u8) void {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const yt = &state.shared.yt;
    if (gen != yt.gen) return;
    yt.searching = false;
    setErr(state, msg);
    state.shared.file_changed = true;
}

// ── Miniature ────────────────────────────────────────────────────────────────

/// Directory cache delle miniature (`…/zuer/ytthumb`), creata al volo.
fn thumbCacheDir(gpa: std.mem.Allocator) ?[]u8 {
    return vtcache.appCacheDir(gpa, "ytthumb");
}

/// Thread miniature: per ogni risultato della generazione `gen` scarica la
/// `mqdefault.jpg` di YouTube (curl, con cache su disco), la decodifica col
/// plugin immagini e la installa nel risultato. Ogni installazione ricontrolla
/// la generazione sotto lock: se l'utente ha già cambiato query non tocca nulla.
fn thumbWorker(state: *GuiAppState, gen: u32) void {
    // `appCacheDir` crea già la catena di directory (niente subprocess: su
    // Windows `mkdir` non esiste come eseguibile).
    const dir = thumbCacheDir(state.gpa) orelse return;
    defer state.gpa.free(dir);

    var i: usize = 0;
    while (true) : (i += 1) {
        // Snapshot dell'id sotto lock; il download/decode avviene fuori.
        state.shared.mutex.lockUncancelable(state.io);
        const yt = &state.shared.yt;
        if (gen != yt.gen or i >= yt.results.len) {
            state.shared.mutex.unlock(state.io);
            return;
        }
        if (yt.results[i].thumb_w != 0) {
            state.shared.mutex.unlock(state.io);
            continue;
        }
        const id = state.gpa.dupe(u8, yt.results[i].id) catch {
            state.shared.mutex.unlock(state.io);
            return;
        };
        state.shared.mutex.unlock(state.io);
        defer state.gpa.free(id);

        const jpg = std.fmt.allocPrint(state.gpa, "{s}/{s}.jpg", .{ dir, id }) catch continue;
        defer state.gpa.free(jpg);

        // Cache su disco: scarica solo se assente/vuota.
        const cached = (decoder_mod.fileSizeLibc(state.gpa, jpg) orelse 0) > 0;
        if (!cached) {
            const url = std.fmt.allocPrint(state.gpa, "https://i.ytimg.com/vi/{s}/mqdefault.jpg", .{id}) catch continue;
            defer state.gpa.free(url);
            var dl = decoder_mod.runCaptureTimeout(state.gpa, &.{ "curl", "-fsSL", "-m", "10", "-o", jpg, url }, 15_000) catch continue;
            const ok = dl.exit_code == 0;
            dl.deinit(state.gpa);
            if (!ok) continue;
        }

        var d = decoder_mod.decode(jpg, state.io, state.gpa);
        defer d.deinit(state.gpa);
        if (d != .image) continue;
        const img = d.image;
        const rgba = gui_state_mod.rgbToRgba(state.gpa, img.pixels, @intCast(img.width), @intCast(img.height)) catch continue;

        state.shared.mutex.lockUncancelable(state.io);
        const yt2 = &state.shared.yt;
        if (gen != yt2.gen) {
            state.shared.mutex.unlock(state.io);
            state.gpa.free(rgba);
            return;
        }
        // Riaggancio per id (l'array non cambia entro la stessa generazione,
        // ma il controllo tiene il worker onesto).
        var installed = false;
        for (yt2.results) |*r| {
            if (std.mem.eql(u8, r.id, id)) {
                if (r.thumb_w == 0) {
                    r.thumb_rgba = rgba;
                    r.thumb_w = @intCast(img.width);
                    r.thumb_h = @intCast(img.height);
                    installed = true;
                }
                break;
            }
        }
        state.shared.file_changed = true;
        state.shared.mutex.unlock(state.io);
        if (!installed) state.gpa.free(rgba);
    }
}

// ── Apertura in streaming ────────────────────────────────────────────────────

/// Apre il risultato selezionato: risolve gli URL diretti con `yt-dlp -g` e
/// avvia il player nativo, tutto su un thread di background.
/// Da chiamare con `shared.mutex` acquisito (thread finestra: Invio o click).
pub fn openSelected(state: *GuiAppState) void {
    if (comptime !has_video) return;
    const yt = &state.shared.yt;
    if (yt.opening) return;
    if (yt.sel < 0 or yt.sel >= @as(i32, @intCast(yt.results.len))) return;
    const r = yt.results[@intCast(yt.sel)];
    const id = state.gpa.dupe(u8, r.id) catch return;
    const title = state.gpa.dupe(u8, r.title) catch {
        state.gpa.free(id);
        return;
    };
    yt.opening = true;
    if (yt.err) |e| {
        state.gpa.free(e);
        yt.err = null;
    }
    state.shared.file_changed = true;
    const t = std.Thread.spawn(.{}, openWorker, .{ state, id, title }) catch {
        state.gpa.free(id);
        state.gpa.free(title);
        yt.opening = false;
        setErr(state, "impossibile avviare l'apertura");
        return;
    };
    t.detach();
}

fn finishOpenErr(state: *GuiAppState, msg: []const u8) void {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    state.shared.yt.opening = false;
    setErr(state, msg);
    state.shared.file_changed = true;
}

/// Thread di apertura: yt-dlp -g → URL video (DASH ≤720p) + URL audio su due
/// righe (o una sola muxed). Il container libav viene aperto QUI, fuori dal
/// lock (rete: secondi); solo lo swap dello stato avviene sotto `mutex`.
/// Prende possesso di `id` e `title`.
fn openWorker(state: *GuiAppState, id: []u8, title: []u8) void {
    defer state.gpa.free(id);
    if (comptime !has_video) {
        state.gpa.free(title);
        return;
    }

    const url = std.fmt.allocPrint(state.gpa, "https://www.youtube.com/watch?v={s}", .{id}) catch {
        state.gpa.free(title);
        return;
    };
    defer state.gpa.free(url);

    var res = decoder_mod.runCaptureTimeout(state.gpa, &.{
        "yt-dlp",
        "--no-warnings",
        "--no-playlist",
        "-g",
        "-f",
        "bv*[height<=720]+ba/b",
        url,
    }, 30_000) catch |e| {
        state.gpa.free(title);
        finishOpenErr(state, if (e == error.Timeout) "risoluzione stream scaduta" else "yt-dlp non eseguibile");
        return;
    };
    defer res.deinit(state.gpa);
    if (res.exit_code != 0) {
        state.gpa.free(title);
        finishOpenErr(state, "video non riproducibile (yt-dlp)");
        return;
    }

    var lines = std.mem.tokenizeScalar(u8, res.stdout, '\n');
    const vurl = std.mem.trimEnd(u8, lines.next() orelse {
        state.gpa.free(title);
        finishOpenErr(state, "nessun URL dallo stream");
        return;
    }, "\r");
    const aurl = if (lines.next()) |l| std.mem.trimEnd(u8, l, "\r") else vurl;

    // Apre il container in uno stato LOCALE: niente lock durante l'handshake di
    // rete. Lo swap col player corrente avviene dopo, sotto `mutex`.
    var local: videomod.VideoState = .{};
    const first = videomod.setupStream(&local, vurl, aurl, state.gpa) catch |e| {
        state.gpa.free(title);
        finishOpenErr(state, @errorName(e));
        return;
    };

    // Il titolo diventa il "nome file" della label in alto a destra: la label usa
    // basename(), quindi eventuali '/' nel titolo vanno neutralizzati.
    for (title) |*ch| {
        if (ch.* == '/') ch.* = '-';
    }

    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);

    // Stessa sequenza della navigazione verso un video (applyDecoded): ferma il
    // player precedente PRIMA di installare il nuovo, sotto lo stesso mutex del
    // worker che chiama advanceVideo/advanceAudio.
    state.video.deinit();
    if (state.midi) |mp| {
        mp.stopAndDestroy();
        state.midi = null;
    }
    state.video = local;

    // Sorgenti correnti per il toggle 'v' (video ↔ solo audio con oscilloscopio).
    gui_state_mod.setAvSrc(state, vurl, aurl, true);

    state.gpa.free(state.shared.static_rgba);
    state.shared.static_rgba = first.rgba;
    state.shared.static_w = first.w;
    state.shared.static_h = first.h;

    state.gpa.free(state.shared.current_file_path);
    state.shared.current_file_path = title; // possesso trasferito
    state.shared.is_text = false;
    state.shared.is_table = false;
    state.shared.sel_active = false;

    const yt = &state.shared.yt;
    yt.opening = false;
    yt.active = false; // overlay chiuso: si riapre con `y` (query/risultati restano)
    state.shared.file_changed = true;
}

// ── Geometria della griglia (condivisa da draw e hit-test) ───────────────────

pub const grid_cols: i32 = 3;
const pad: i32 = 14;
const gap: i32 = 10;
const input_h: i32 = 42;
const title_strip_h: i32 = 26;
const status_h: i32 = 22;
const panel_top: i32 = 28;

pub const Layout = struct {
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

/// Geometria del pannello per la finestra `W`×`H` con `n` risultati e una riga
/// di stato opzionale (errore/apertura). Le card scorrono per righe (`row_off`).
fn layoutFor(W: u32, H: u32, n: usize, status: bool) Layout {
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const wp: i32 = @min(wi - 32, 880);
    const xp = @divTrunc(wi - wp, 2);
    const card_w = @divTrunc(wp - pad * 2 - gap * (grid_cols - 1), grid_cols);
    const thumb_h = @divTrunc(card_w * 9, 16);
    const card_h = thumb_h + title_strip_h;
    const st: i32 = if (status) status_h else 0;
    const total_rows: i32 = @intCast((n + @as(usize, @intCast(grid_cols)) - 1) / @as(usize, @intCast(grid_cols)));
    const avail = hi - panel_top - pad * 2 - input_h - st - gap;
    var vis = @max(@as(i32, 1), @divTrunc(avail, card_h + gap));
    vis = @min(vis, @max(total_rows, 1));
    const rows_shown = if (total_rows == 0) 0 else vis;
    const hp = pad * 2 + input_h + st + (if (rows_shown > 0) gap + rows_shown * (card_h + gap) - gap else 0);
    return .{
        .xp = xp,
        .yp = panel_top,
        .wp = wp,
        .hp = hp,
        .grid_x = xp + pad,
        .grid_y = panel_top + pad + input_h + st + gap,
        .card_w = card_w,
        .thumb_h = thumb_h,
        .card_h = card_h,
        .total_rows = total_rows,
        .vis_rows = vis,
    };
}

/// Rettangolo della card `i` (indice assoluto) con lo scroll `row_off`, o null
/// se fuori dalla banda visibile.
fn cardRect(lay: Layout, row_off: i32, i: usize) ?[4]i32 {
    const idx: i32 = @intCast(i);
    const row = @divTrunc(idx, grid_cols);
    const col = @mod(idx, grid_cols);
    if (row < row_off or row >= row_off + lay.vis_rows) return null;
    const x = lay.grid_x + col * (lay.card_w + gap);
    const y = lay.grid_y + (row - row_off) * (lay.card_h + gap);
    return .{ x, y, lay.card_w, lay.card_h };
}

// ── Input mouse ──────────────────────────────────────────────────────────────

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

/// Geometria della scrollbar della griglia (binario verticale sul bordo destro
/// del pannello): `{x, y, w, h}` del binario, o null se non serve (tutto visibile).
fn scrollbarGeom(lay: Layout) ?[4]i32 {
    if (lay.total_rows <= lay.vis_rows) return null;
    const h = lay.vis_rows * (lay.card_h + gap) - gap;
    return .{ lay.xp + lay.wp - 11, lay.grid_y, 7, h };
}

/// Posizione/altezza del thumb per lo scroll corrente.
fn scrollbarThumb(lay: Layout, sb: [4]i32, row_off: i32) [2]i32 {
    const track_h = sb[3];
    const th = @max(@as(i32, 24), @divTrunc(track_h * lay.vis_rows, lay.total_rows));
    const max_off = @max(lay.total_rows - lay.vis_rows, 1);
    const ty = sb[1] + @divTrunc((track_h - th) * std.math.clamp(row_off, 0, max_off), max_off);
    return .{ ty, th };
}

/// `row_off` dalla coordinata Y del mouse sul binario (drag/click del thumb).
fn rowOffFromY(lay: Layout, sb: [4]i32, my: f32) i32 {
    const th = scrollbarThumb(lay, sb, 0)[1];
    const span: f32 = @floatFromInt(@max(sb[3] - th, 1));
    const rel = (my - @as(f32, @floatFromInt(sb[1]))) - @as(f32, @floatFromInt(th)) / 2.0;
    const max_off: f32 = @floatFromInt(@max(lay.total_rows - lay.vis_rows, 0));
    const off: i32 = @intFromFloat(@round(std.math.clamp(rel / span, 0.0, 1.0) * max_off));
    return off;
}

/// Rotella col pannello aperto: scorre la griglia di una riga per scatto.
/// Ritorna true se l'evento è consumato (sempre, a overlay attivo).
pub fn handleWheel(state: *GuiAppState, win: *zrame.Window, axis: u32, value: i32) bool {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const yt = &state.shared.yt;
    if (!yt.active) return false;
    if (axis != 0 or value == 0) return true;
    const dims = overlayDims(state, win);
    const lay = layoutFor(dims[0], dims[1], yt.results.len, yt.err != null or yt.opening);
    const step: i32 = if (value > 0) 1 else -1;
    const max_off = @max(lay.total_rows - lay.vis_rows, 0);
    const new_off = std.math.clamp(yt.row_off + step, 0, max_off);
    if (new_off != yt.row_off) {
        yt.row_off = new_off;
        state.shared.file_changed = true;
    }
    return true;
}

/// Gestione del mouse a overlay attivo: hover seleziona la card, click sinistro
/// la apre, la scrollbar si trascina, click fuori dal pannello chiude l'overlay.
/// Ritorna true se l'evento è consumato (a overlay aperto: sempre, tranne il leave).
pub fn handleMouse(state: *GuiAppState, win: *zrame.Window, event: zrame.MouseEvent) bool {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const yt = &state.shared.yt;
    if (!yt.active) return false;

    const dims = overlayDims(state, win);
    const status = yt.err != null or yt.opening;
    const lay = layoutFor(dims[0], dims[1], yt.results.len, status);
    const sb = scrollbarGeom(lay);

    switch (event) {
        .motion => |mot| {
            state.last_x = mot.x;
            state.last_y = mot.y;
            if (yt.sb_drag) {
                if (sb) |bar| {
                    const off = rowOffFromY(lay, bar, mot.y);
                    if (off != yt.row_off) {
                        yt.row_off = off;
                        state.shared.file_changed = true;
                    }
                }
                return true;
            }
            for (yt.results, 0..) |_, i| {
                const rc = cardRect(lay, yt.row_off, i) orelse continue;
                if (mot.x >= @as(f32, @floatFromInt(rc[0])) and mot.x < @as(f32, @floatFromInt(rc[0] + rc[2])) and
                    mot.y >= @as(f32, @floatFromInt(rc[1])) and mot.y < @as(f32, @floatFromInt(rc[1] + rc[3])))
                {
                    if (yt.sel != @as(i32, @intCast(i))) {
                        yt.sel = @intCast(i);
                        state.shared.file_changed = true;
                    }
                    break;
                }
            }
            return true;
        },
        .button => |btn| {
            if (btn.button != 0x110) return true;
            if (btn.state != 1) {
                yt.sb_drag = false; // rilascio: fine del drag della scrollbar
                return true;
            }
            const mx = state.last_x;
            const my = state.last_y;
            // Pressione sul binario della scrollbar: salta lì e inizia il drag.
            if (sb) |bar| {
                if (mx >= @as(f32, @floatFromInt(bar[0] - 4)) and mx < @as(f32, @floatFromInt(bar[0] + bar[2] + 4)) and
                    my >= @as(f32, @floatFromInt(bar[1])) and my < @as(f32, @floatFromInt(bar[1] + bar[3])))
                {
                    yt.sb_drag = true;
                    yt.row_off = rowOffFromY(lay, bar, my);
                    state.shared.file_changed = true;
                    return true;
                }
            }
            for (yt.results, 0..) |_, i| {
                const rc = cardRect(lay, yt.row_off, i) orelse continue;
                if (mx >= @as(f32, @floatFromInt(rc[0])) and mx < @as(f32, @floatFromInt(rc[0] + rc[2])) and
                    my >= @as(f32, @floatFromInt(rc[1])) and my < @as(f32, @floatFromInt(rc[1] + rc[3])))
                {
                    yt.sel = @intCast(i);
                    openSelected(state);
                    return true;
                }
            }
            // Click fuori dal pannello: chiudi l'overlay (dentro ma non su una
            // card — campo, bordi — non fa nulla).
            const inside = mx >= @as(f32, @floatFromInt(lay.xp)) and mx < @as(f32, @floatFromInt(lay.xp + lay.wp)) and
                my >= @as(f32, @floatFromInt(lay.yp)) and my < @as(f32, @floatFromInt(lay.yp + lay.hp));
            if (!inside) {
                yt.active = false;
                state.shared.file_changed = true;
            }
            return true;
        },
        .leave => return false,
    }
}

// ── Disegno dell'overlay ─────────────────────────────────────────────────────

const panel_bg = paint.Color.rgba(13, 15, 22, 0.94);
const card_bg = paint.Color.rgba(26, 30, 41, 0.98);
const sel_accent = paint.Color.rgba(120, 160, 255, 0.95);
const input_bg = paint.Color.rgba(28, 32, 44, 0.9);
const badge_bg = paint.Color.rgba(0, 0, 0, 0.72);
const text_fg = [3]u8{ 235, 238, 245 };
const text_dim = [3]u8{ 150, 158, 175 };
const text_err = [3]u8{ 240, 120, 110 };

/// Testo monospazio troncato a `max_w` px; ritorna la larghezza usata.
/// Pubblica: riusata dall'esploratore file (stesso stile di overlay).
pub fn drawText(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, x: i32, baseline: i32, text: []const u8, rgb: [3]u8, max_w: i32) i32 {
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const cell = raster.advance;
    if (cell <= 0 or max_w <= 0) return 0;
    var pen_x = x;
    var view = std.unicode.Utf8View.init(text) catch return 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (pen_x + cell > x + max_w) break;
        const gph = raster.getGlyph(.regular, cp) catch {
            pen_x += cell;
            continue;
        };
        if (gph.bitmap.len != 0) {
            const gx0 = pen_x + gph.xoff;
            const gy0 = baseline + gph.yoff;
            var gy: i32 = 0;
            while (gy < gph.h) : (gy += 1) {
                const py = gy0 + gy;
                if (py < 0 or py >= hi) continue;
                var gx: i32 = 0;
                while (gx < gph.w) : (gx += 1) {
                    const px = gx0 + gx;
                    if (px < 0 or px >= wi) continue;
                    const cov = gph.bitmap[@intCast(gy * gph.w + gx)];
                    if (cov == 0) continue;
                    blendPx(buf, @intCast((py * wi + px) * 4), rgb, cov);
                }
            }
        }
        pen_x += cell;
    }
    return pen_x - x;
}

fn blendPx(buf: []u8, idx: usize, rgb: [3]u8, a: u8) void {
    const av: u32 = a;
    const inv: u32 = 255 - av;
    buf[idx + 0] = @intCast((@as(u32, buf[idx + 0]) * inv + @as(u32, rgb[0]) * av) / 255);
    buf[idx + 1] = @intCast((@as(u32, buf[idx + 1]) * inv + @as(u32, rgb[1]) * av) / 255);
    buf[idx + 2] = @intCast((@as(u32, buf[idx + 2]) * inv + @as(u32, rgb[2]) * av) / 255);
    buf[idx + 3] = @max(buf[idx + 3], a);
}

/// Blit della miniatura scalata (nearest) nel rettangolo destinazione, con clip
/// ai bordi del frame. Sorgente e destinazione sono RGBA opache: copia di parole.
/// Pubblica: riusata dall'esploratore file.
pub fn blitThumb(buf: []u8, W: u32, H: u32, dx: i32, dy: i32, dw: i32, dh: i32, src: []const u8, sw: u32, sh: u32) void {
    if (dw <= 0 or dh <= 0 or sw == 0 or sh == 0) return;
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const dst_words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buf[0 .. @as(usize, W) * H * 4]));
    const src_words: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, src[0 .. @as(usize, sw) * sh * 4]));
    var y: i32 = @max(dy, 0);
    const y1 = @min(dy + dh, hi);
    while (y < y1) : (y += 1) {
        const sy: u32 = @intCast(@divTrunc((y - dy) * @as(i32, @intCast(sh)), dh));
        const srow = @as(usize, @min(sy, sh - 1)) * sw;
        const drow = @as(usize, @intCast(y)) * W;
        var x: i32 = @max(dx, 0);
        const x1 = @min(dx + dw, wi);
        while (x < x1) : (x += 1) {
            const sx: u32 = @intCast(@divTrunc((x - dx) * @as(i32, @intCast(sw)), dw));
            dst_words[drow + @as(usize, @intCast(x))] = src_words[srow + @min(sx, sw - 1)];
        }
    }
}

/// Disegna l'overlay di ricerca sul frame corrente (`W`×`H`). Da chiamare con
/// `shared.mutex` acquisito e solo se `yt.active`. `spin_phase` in secondi
/// anima lo spinner mentre ricerca/apertura sono in corso.
pub fn drawOverlay(buf: []u8, W: u32, H: u32, state: *GuiAppState, raster: *glyph.Raster, spin_phase: f32) void {
    if (W < 160 or H < 160) return;
    const yt = &state.shared.yt;

    const status = yt.err != null or yt.opening;
    const lay = layoutFor(W, H, yt.results.len, status);

    // Scroll a inseguimento della selezione SOLO quando è cambiata da tastiera:
    // rotella e drag della scrollbar sfogliano liberamente (l'hover non c'entra,
    // il mouse è già su una card visibile).
    if (yt.follow_sel and yt.sel >= 0) {
        const sel_row = @divTrunc(yt.sel, grid_cols);
        if (sel_row < yt.row_off) yt.row_off = sel_row;
        if (sel_row >= yt.row_off + lay.vis_rows) yt.row_off = sel_row - lay.vis_rows + 1;
    }
    yt.follow_sel = false;
    yt.row_off = std.math.clamp(yt.row_off, 0, @max(lay.total_rows - lay.vis_rows, 0));

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);

    const line_h = raster.ascent - raster.descent;

    canvas.fillRoundedRect(@floatFromInt(lay.xp), @floatFromInt(lay.yp), @floatFromInt(lay.wp), @floatFromInt(lay.hp), 14.0, panel_bg);
    canvas.fillRoundedRect(@floatFromInt(lay.xp + pad), @floatFromInt(lay.yp + pad), @floatFromInt(lay.wp - pad * 2), @floatFromInt(input_h), 9.0, input_bg);

    // Campo query: testo digitato + caret, o placeholder.
    const in_x = lay.xp + pad + 12;
    const in_max = lay.wp - pad * 2 - 24 - input_h; // spazio a destra per lo spinner
    const in_base = lay.yp + pad + @divTrunc(input_h - line_h, 2) + raster.ascent;
    if (yt.query.items.len == 0) {
        _ = drawText(buf, W, H, raster, in_x, in_base, "Cerca su YouTube…", text_dim, in_max);
    } else {
        // Ctrl+A: highlight di selezione dietro il testo (larghezza dei codepoint
        // effettivamente visibili, come li disegna drawText).
        if (yt.sel_all) {
            var cols: i32 = 0;
            var view = std.unicode.Utf8View.init(yt.query.items) catch null;
            if (view) |*v| {
                var it = v.iterator();
                while (it.nextCodepoint()) |_| cols += 1;
            }
            const sel_w = @min(cols * raster.advance, in_max);
            canvas.fillRoundedRect(@floatFromInt(in_x - 2), @floatFromInt(lay.yp + pad + 6), @floatFromInt(sel_w + 4), @floatFromInt(input_h - 12), 3.0, paint.Color.rgba(70, 110, 190, 0.55));
        }
        const tw = drawText(buf, W, H, raster, in_x, in_base, yt.query.items, text_fg, in_max);
        if (!yt.sel_all) {
            canvas.fillRoundedRect(@floatFromInt(in_x + tw + 1), @floatFromInt(lay.yp + pad + 7), 2.0, @floatFromInt(input_h - 14), 1.0, paint.Color.rgba(text_fg[0], text_fg[1], text_fg[2], 0.9));
        }
    }
    if (yt.searching or yt.opening) {
        const scx: f32 = @floatFromInt(lay.xp + lay.wp - pad - @divTrunc(input_h, 2));
        const scy: f32 = @floatFromInt(lay.yp + pad + @divTrunc(input_h, 2));
        canvas.drawSpinner(scx, scy, @as(f32, @floatFromInt(input_h)) * 0.26, 2.5, spin_phase, paint.Color.rgba(205, 210, 230, 1.0));
    }

    // Riga di stato (errore o "apertura stream…").
    if (status) {
        const sy = lay.yp + pad + input_h;
        const sbase = sy + @divTrunc(status_h - line_h, 2) + raster.ascent;
        if (yt.opening) {
            _ = drawText(buf, W, H, raster, in_x, sbase, "apertura stream…", text_dim, lay.wp - pad * 2 - 24);
        } else if (yt.err) |e| {
            _ = drawText(buf, W, H, raster, in_x, sbase, e, text_err, lay.wp - pad * 2 - 24);
        }
    }

    // Griglia di card stile Netflix: miniatura 16:9, striscia titolo, badge durata.
    for (yt.results, 0..) |r, i| {
        const rc = cardRect(lay, yt.row_off, i) orelse continue;
        const x = rc[0];
        const y = rc[1];

        if (@as(i32, @intCast(i)) == yt.sel) {
            canvas.fillRoundedRect(@floatFromInt(x - 3), @floatFromInt(y - 3), @floatFromInt(lay.card_w + 6), @floatFromInt(lay.card_h + 6), 10.0, sel_accent);
        }
        canvas.fillRoundedRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(lay.card_w), @floatFromInt(lay.card_h), 8.0, card_bg);

        if (r.thumb_w != 0) {
            blitThumb(buf, W, H, x + 1, y + 1, lay.card_w - 2, lay.thumb_h - 1, r.thumb_rgba, r.thumb_w, r.thumb_h);
        } else {
            // Miniatura non ancora arrivata: placeholder scuro.
            canvas.fillRoundedRect(@floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(lay.card_w - 2), @floatFromInt(lay.thumb_h - 1), 8.0, paint.Color.rgba(16, 19, 27, 1.0));
        }

        // Badge durata in basso a destra della miniatura.
        if (r.duration.len > 0) {
            var cols: i32 = 0;
            var view = std.unicode.Utf8View.init(r.duration) catch null;
            if (view) |*v| {
                var it = v.iterator();
                while (it.nextCodepoint()) |_| cols += 1;
            }
            const bw = cols * raster.advance + 10;
            const bh = line_h + 4;
            const bx = x + lay.card_w - bw - 6;
            const by = y + lay.thumb_h - bh - 6;
            canvas.fillRoundedRect(@floatFromInt(bx), @floatFromInt(by), @floatFromInt(bw), @floatFromInt(bh), 4.0, badge_bg);
            _ = drawText(buf, W, H, raster, bx + 5, by + 2 + raster.ascent, r.duration, text_fg, bw);
        }

        // Striscia titolo sotto la miniatura.
        const tbase = y + lay.thumb_h + @divTrunc(title_strip_h - line_h, 2) + raster.ascent;
        _ = drawText(buf, W, H, raster, x + 8, tbase, r.title, text_fg, lay.card_w - 16);
    }

    // Scrollbar della griglia (solo se c'è altro da sfogliare): binario fioco
    // sul bordo destro del pannello + thumb proporzionale, trascinabile.
    if (scrollbarGeom(lay)) |sb| {
        canvas.fillRoundedRect(@floatFromInt(sb[0]), @floatFromInt(sb[1]), @floatFromInt(sb[2]), @floatFromInt(sb[3]), 3.5, paint.Color.rgba(255, 255, 255, 0.10));
        const th = scrollbarThumb(lay, sb, yt.row_off);
        canvas.fillRoundedRect(@floatFromInt(sb[0]), @floatFromInt(th[0]), @floatFromInt(sb[2]), @floatFromInt(th[1]), 3.5, paint.Color.rgba(255, 255, 255, if (yt.sb_drag) 0.65 else 0.38));
    }
}

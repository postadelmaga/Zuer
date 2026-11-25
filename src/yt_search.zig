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
const ui = @import("overlay_ui.zig");
const clipboard = @import("clipboard.zig");
const videomod = @import("video.zig");
const gui_state_mod = @import("gui_state.zig");
const nav = @import("nav.zig");
const GuiAppState = gui_state_mod.GuiAppState;
const zrame = @import("zrame");
const zicro = @import("zicro");
const card_grid = @import("card_grid.zig");
const paint = zicro.paint;
const build_options = @import("build_options");
const has_video = build_options.video;
const builtin = @import("builtin");
const vtcache = @import("vtcache.zig");
const layout_mod = @import("layout.zig");
const crash_report = @import("crash_report.zig");
const hwdec_caps = @import("hwdec_caps.zig");
const ytdlp = @import("ytdlp.zig");
const yt_queue = @import("yt_queue.zig");

/// Un risultato di ricerca (stringhe e miniatura possedute, vedi `freeResults`).
pub const Result = struct {
    id: []u8,
    title: []u8,
    duration: []u8,
    channel: []u8,
    /// Miniatura RGBA (vuota finché il thumb worker non la installa).
    thumb_rgba: []align(4) u8 = &.{},
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
    /// Un thumb worker ha già preso in carico questa miniatura (i download
    /// girano in parallelo su più worker: niente doppi download).
    claimed: bool = false,
};

/// Altezze video selezionabili (chips nell'overlay); indice in `YtState.quality`.
/// 0 = Auto: l'altezza la sceglie `yt_queue.autoHeight` dalla vista.
pub const quality_heights = [_]u32{ 0, 360, 480, 720, 1080 };
pub const quality_labels = [_][]const u8{ "Auto", "360p", "480p", "720p", "1080p" };

/// Un sottotitolo: intervallo in secondi e testo (posseduto).
pub const SubCue = struct { start: f64, end: f64, text: []u8 };

/// Stato dell'overlay, dentro `Shared` (ogni accesso sotto `shared.mutex`).
pub const YtState = struct {
    active: bool = false,
    /// Campo query: testo UTF-8 + caret + selezione (zicro.line_edit).
    query: QueryEdit = .{},
    results: []Result = &.{},
    /// Card selezionata nella griglia (-1 = nessuna).
    sel: i32 = -1,
    /// Scroll della griglia in pixel, col passo e l'easing di zicro.
    scroll: card_grid.GridScroll = .{},
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
    /// La selezione è appena cambiata da tastiera: al prossimo draw lo scroll
    /// la insegue (l'hover del mouse e la rotella NON la inseguono).
    follow_sel: bool = false,
    /// Qualità stream selezionata (indice in `quality_heights`, 0 = Auto). Con
    /// uno stream YT attivo, cambiarla riapre il video alla stessa posizione.
    quality: u8 = 0,
    /// Altezza chiesta per lo stream corrente (0 = nessuno): Auto la alza quando
    /// la vista cresce (`autoTick`).
    stream_h: u32 = 0,
    /// Secondi da cui la vista giustifica un'altezza maggiore (vedi `raise_after_s`).
    raise_s: f32 = 0,
    raise_view_h: u32 = 0,
    /// Coda "guarda dopo" (posseduta, come i risultati), salvata su disco a ogni
    /// modifica e letta alla prima apertura dell'overlay o al primo video.
    queue: std.ArrayList(Result) = .empty,
    queue_loaded: bool = false,
    /// La griglia mostra la coda invece dei risultati (chip "Coda").
    show_queue: bool = false,
    /// Posizione del video corrente al tick precedente: un salto da fine video a
    /// zero senza seek è il video finito (FFmpeg e mpv lo fanno ricominciare).
    prev_pos: f64 = -1,
    /// Id (posseduto) del video YouTube attualmente in riproduzione: serve al
    /// tasto `o` (apri la pagina), ai sottotitoli e al cambio qualità.
    /// null = il player corrente non viene da YouTube.
    current_id: ?[]u8 = null,
    /// Sottotitoli del video corrente (posseduti, ordinati per start) e loro
    /// stato: `subs_on` = disegnali, `subs_loading` = yt-dlp in corso.
    subs: []SubCue = &.{},
    subs_on: bool = false,
    subs_loading: bool = false,
    /// Cache dell'ultimo cue presentato: il lookup del frame dopo riparte da qui.
    sub_idx: usize = 0,
    /// URL dei VTT del video corrente ("it=URL en=URL", posseduti), dalla
    /// stessa estrazione yt-dlp dello stream: il tasto `c` li scarica con curl
    /// senza rilanciare yt-dlp. Vuoto = sconosciuti (si ripiega su yt-dlp).
    sub_urls: []u8 = &.{},
    /// Prefetch: la card selezionata viene risolta in anticipo su un thread
    /// (una alla volta); Invio la trova pronta, o aspetta quella in volo.
    pf: ?Resolved = null,
    pf_busy: bool = false,
    /// Flag d'annullamento del prefetch in volo (del worker, valido finché
    /// `pf_busy`): Invio su un ALTRO video lo alza e yt-dlp viene terminato.
    pf_cancel: ?*std.atomic.Value(bool) = null,
    /// Ultima (id, altezza) mandata in prefetch: non si ritenta la stessa.
    pf_tried: IdBuf = .{},
    pf_tried_h: u32 = 0,
    /// Selezione per cui il motore video è già stato preavviato (-2 = nessuna;
    /// chi apre l'overlay lo rimette a -2).
    /// Il preavvio si rifà quando cambia, non a ogni disegno: con l'overlay
    /// aperto e fermo il motore inattivo veniva ritirato e ricreato ogni 30 s
    /// (connessione Wayland, EGL, istanza mpv), per sempre.
    prewarm_sel: i32 = -2,
    /// Ultima riapertura automatica dopo la caduta dello stream (ms, 0 = mai):
    /// una seconda caduta a breve distanza non si ritenta, si dice.
    fail_reopen_ms: i64 = 0,
};

/// Id video in un buffer fisso (gli id YouTube sono di 11 caratteri).
pub const IdBuf = struct {
    buf: [16]u8 = undefined,
    len: u8 = 0,

    fn get(self: *const IdBuf) []const u8 {
        return self.buf[0..self.len];
    }
    fn set(self: *IdBuf, id: []const u8) bool {
        if (id.len > self.buf.len) return false;
        @memcpy(self.buf[0..id.len], id);
        self.len = @intCast(id.len);
        return true;
    }
    fn eql(self: *const IdBuf, id: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.get(), id);
    }
};

/// Esito di una risoluzione yt-dlp: stdout posseduto e slice al suo interno.
pub const Resolved = struct {
    id: IdBuf,
    height: u32,
    /// `zicro.widget.nowMs()` alla risoluzione (gli URL scadono dopo ore).
    at_ms: i64,
    out: []u8,
    title: []const u8,
    vurl: []const u8,
    aurl: []const u8,
    /// "it=URL en=URL" (campi vuoti possibili), o "".
    subs: []const u8,

    fn deinit(self: *Resolved, gpa: std.mem.Allocator) void {
        gpa.free(self.out);
    }
    fn fresh(self: *const Resolved, id: []const u8, height: u32) bool {
        return self.height == height and self.id.eql(id) and
            zicro.widget.nowMs() - self.at_ms < prefetch_max_age_ms;
    }
};

/// Oltre questa età un prefetch non si usa: gli URL googlevideo valgono ~6 h,
/// ma un margine largo evita sorprese (cambio di rete/IP).
const prefetch_max_age_ms: i64 = 20 * 60 * 1000;

fn freeResult(gpa: std.mem.Allocator, r: Result) void {
    gpa.free(r.id);
    gpa.free(r.title);
    gpa.free(r.duration);
    gpa.free(r.channel);
    gpa.free(r.thumb_rgba);
}

pub fn freeResults(gpa: std.mem.Allocator, results: []Result) void {
    for (results) |r| freeResult(gpa, r);
    gpa.free(results);
}

/// Libera tutto lo stato posseduto (a fine processo).
pub fn deinit(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    freeResults(state.gpa, yt.results);
    yt.results = &.{};
    if (yt.err) |e| state.gpa.free(e);
    yt.err = null;
    for (yt.queue.items) |r| freeResult(state.gpa, r);
    yt.queue.deinit(state.gpa);
    clearCurrentStream(state);
    if (yt.pf) |*p| p.deinit(state.gpa);
    yt.pf = null;
}

/// Le card della griglia: la coda o i risultati della ricerca.
pub fn shown(yt: *YtState) []Result {
    return if (yt.show_queue) yt.queue.items else yt.results;
}

/// Libera i sottotitoli caricati. Con `shared.mutex` acquisito.
fn freeSubs(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    for (yt.subs) |c| state.gpa.free(c.text);
    state.gpa.free(yt.subs);
    yt.subs = &.{};
    yt.sub_idx = 0;
}

/// Il player corrente non è più lo stream YouTube (navigazione verso un file):
/// invalida id corrente e sottotitoli. Con `shared.mutex` acquisito.
pub fn clearCurrentStream(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    if (yt.current_id) |cid| state.gpa.free(cid);
    yt.current_id = null;
    yt.stream_h = 0;
    yt.prev_pos = -1;
    freeSubs(state);
    yt.subs_on = false;
    state.gpa.free(yt.sub_urls);
    yt.sub_urls = &.{};
    // Il titolo dello stream vale finché lo stream è ciò che è aperto.
    state.gpa.free(state.shared.display_name);
    state.shared.display_name = &.{};
}

/// Indirizzo della pagina dello stream in riproduzione (`gpa`, il chiamante
/// libera), o null se ciò che è aperto non è uno stream. Con `shared.mutex`.
pub fn currentLink(state: *GuiAppState) ?[]u8 {
    const id = state.shared.yt.current_id orelse return null;
    if (state.shared.display_name.len == 0) return null;
    return std.fmt.allocPrint(state.gpa, "https://www.youtube.com/watch?v={s}", .{id}) catch null;
}

/// Svuota risultati/errore correnti (dopo una modifica alla query i vecchi
/// risultati non corrispondono più) e brucia la generazione così i worker in
/// volo (search/thumb) buttano ciò che portano. Con `shared.mutex` acquisito.
pub fn invalidateResults(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    yt.gen +%= 1;
    // Una ricerca in corso ora è superata: il suo worker scarterà il risultato
    // (gen diversa) senza toccare lo stato, quindi si spegne qui. Altrimenti
    // `searching` restava vero per sempre e nessuna ricerca successiva partiva.
    yt.searching = false;
    freeResults(state.gpa, yt.results);
    yt.results = &.{};
    yt.sel = -1;
    yt.scroll.reset();
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

/// Il campo query: una riga, al massimo 256 byte (oltre ogni ragionevolezza).
pub const QueryEdit = zicro.line_edit.LineEdit(256);

pub const Move = struct { word: bool, extend: bool };

/// Un'operazione sul campo query (tasti di editing, digitazione, incolla).
pub const QueryOp = union(enum) {
    insert: []const u8,
    backspace: bool, // true = per parola (Ctrl)
    delete: bool,
    left: Move,
    right: Move,
    home: bool, // true = estende la selezione (Shift)
    end: bool,
    select_all,
    cut,
};

/// Applica `op` al campo query. Se il TESTO cambia i risultati mostrati non
/// corrispondono più: vengono invalidati e si torna alla vista ricerca; i soli
/// movimenti del caret non toccano nulla. Con `shared.mutex` acquisito.
pub fn editQuery(state: *GuiAppState, op: QueryOp) void {
    const yt = &state.shared.yt;
    const q = &yt.query;
    var before: [256]u8 = undefined;
    const before_len = q.len;
    @memcpy(before[0..before_len], q.text());
    switch (op) {
        .insert => |t| q.insert(t),
        .backspace => |w| q.backspace(w),
        .delete => |w| q.delete(w),
        .left => |m| q.left(m.word, m.extend),
        .right => |m| q.right(m.word, m.extend),
        .home => |e| q.home(e),
        .end => |e| q.end(e),
        .select_all => q.selectAll(),
        .cut => {
            const sel = q.selectedText();
            if (sel.len == 0) return;
            copyText(state, sel);
            _ = q.deleteSelection();
        },
    }
    if (!std.mem.eql(u8, before[0..before_len], q.text())) {
        yt.show_queue = false;
        invalidateResults(state);
    }
    state.shared.file_changed = true;
}

/// Copia `txt` negli appunti. La copia (wl-copy + waitpid) avviene su un thread
/// così il lock non resta tenuto per un subprocess.
fn copyText(state: *GuiAppState, txt: []const u8) void {
    const dup = state.gpa.dupe(u8, txt) catch return;
    const t = std.Thread.spawn(.{}, copyWorker, .{ state, dup }) catch {
        state.gpa.free(dup);
        return;
    };
    t.detach();
}

/// Ctrl+C nell'overlay: il testo selezionato nel campo, se c'è; altrimenti con
/// una card selezionata il LINK del video (youtube.com/watch?v=…); altrimenti
/// tutta la query. Con `shared.mutex` acquisito.
pub fn copyQueryOrLink(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    const sel = yt.query.selectedText();
    if (sel.len > 0) return copyText(state, sel);
    if (yt.sel >= 0 and yt.sel < @as(i32, @intCast(shown(yt).len))) {
        const r = shown(yt)[@intCast(yt.sel)];
        var link_buf: [128]u8 = undefined;
        const link = std.fmt.bufPrint(&link_buf, "https://www.youtube.com/watch?v={s}", .{r.id}) catch return;
        return copyText(state, link);
    }
    if (yt.query.len > 0) copyText(state, yt.query.text());
}

fn copyWorker(state: *GuiAppState, txt: []u8) void {
    clipboard.copy(txt);
    state.gpa.free(txt);
}

/// Ctrl+V: incolla dagli appunti (wl-paste, pbpaste o clipboard Win32, su thread).
/// Con `shared.mutex` acquisito.
pub fn startPaste(state: *GuiAppState) void {
    const t = std.Thread.spawn(.{}, pasteWorker, .{state}) catch return;
    t.detach();
}

fn pasteWorker(state: *GuiAppState) void {
    const raw: []u8 = if (comptime builtin.os.tag == .windows)
        clipboard.pasteAlloc(state.gpa) orelse return
    else raw: {
        var res = decoder_mod.runCaptureTimeout(state.gpa, clipboard.paste_argv, 2_000) catch return;
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
    editQuery(state, .{ .insert = trimmed });
}

// ── Ricerca ──────────────────────────────────────────────────────────────────

const search_max = 12;

/// Avvia la ricerca della query corrente su un thread di background.
/// Da chiamare con `shared.mutex` acquisito (thread finestra, Invio).
pub fn startSearch(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    if (yt.query.len == 0 or yt.searching) return;
    const q = state.gpa.dupe(u8, yt.query.text()) catch return;
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

    const exe = ytdlp.find(state.gpa, state.io) orelse {
        finishSearchErr(state, gen, ytdlp.missing_msg);
        return;
    };
    defer state.gpa.free(exe);
    var res = decoder_mod.runCaptureTimeout(state.gpa, &.{
        exe,
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
        // L'id arriva dallo stdout di yt-dlp e finisce nei percorsi della cache
        // (`<id>.jpg`, `<id>.<lingua>.vtt`) e nel file della coda: solo la forma
        // canonica, come per i link incollati. Un `../` qui scriverebbe fuori.
        if (validVideoId(id) == null or id.len != 11) continue;
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
        yt.scroll.reset();
        yt.searching = false;
        if (owned.len == 0) setErr(state, "nessun risultato");
        state.shared.file_changed = true;
        installed = owned.len > 0;
    }
    // Miniature fuori dal lock, in PARALLELO: più worker si spartiscono i
    // download tramite il flag `claimed` per-risultato (curl è I/O bound: la
    // serialità era il collo di bottiglia del riempimento della griglia).
    if (installed) {
        const n_workers = @min(owned.len, 4);
        var wi: usize = 0;
        while (wi < n_workers) : (wi += 1) {
            const t = std.Thread.spawn(.{}, thumbWorker, .{ state, gen, ThumbList.results }) catch break;
            t.detach();
        }
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

/// Le miniature si scaricano per i risultati (validi entro una generazione) o
/// per la coda (voci ritrovate per id: possono sparire, mai cambiare id).
const ThumbList = enum { results, queue };

fn thumbList(yt: *YtState, which: ThumbList) []Result {
    return if (which == .queue) yt.queue.items else yt.results;
}

/// Avvia i worker delle miniature mancanti della coda. Con `shared.mutex` acquisito.
fn startQueueThumbs(state: *GuiAppState) void {
    var missing: usize = 0;
    for (state.shared.yt.queue.items) |r| {
        if (r.thumb_w == 0 and !r.claimed) missing += 1;
    }
    var wi: usize = 0;
    while (wi < @min(missing, 4)) : (wi += 1) {
        const t = std.Thread.spawn(.{}, thumbWorker, .{ state, @as(u32, 0), ThumbList.queue }) catch break;
        t.detach();
    }
}

/// Directory cache delle miniature (`…/zuer/ytthumb`), creata al volo.
fn thumbCacheDir(gpa: std.mem.Allocator) ?[]u8 {
    return vtcache.appCacheDir(gpa, "ytthumb");
}

/// Thread miniature (più istanze in parallelo): ognuna RECLAMA sotto lock il
/// prossimo risultato senza miniatura (`claimed`, così nessun download doppio),
/// scarica la `mqdefault.jpg` di YouTube (curl, con cache su disco), la
/// decodifica col plugin immagini e la installa. Ogni installazione ricontrolla
/// la generazione sotto lock: se l'utente ha già cambiato query non tocca nulla.
fn thumbWorker(state: *GuiAppState, gen: u32, which: ThumbList) void {
    // `appCacheDir` crea già la catena di directory (niente subprocess: su
    // Windows `mkdir` non esiste come eseguibile).
    const dir = thumbCacheDir(state.gpa) orelse return;
    defer state.gpa.free(dir);

    while (true) {
        // Reclama la prossima miniatura mancante sotto lock; download/decode fuori.
        state.shared.mutex.lockUncancelable(state.io);
        const yt = &state.shared.yt;
        if (which == .results and gen != yt.gen) {
            state.shared.mutex.unlock(state.io);
            return;
        }
        var id_opt: ?[]u8 = null;
        for (thumbList(yt, which)) |*r| {
            if (r.thumb_w == 0 and !r.claimed) {
                r.claimed = true;
                id_opt = state.gpa.dupe(u8, r.id) catch null;
                break;
            }
        }
        state.shared.mutex.unlock(state.io);
        const id = id_opt orelse return; // niente più lavoro (o alloc fallita)
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
        if (which == .results and gen != yt2.gen) {
            state.shared.mutex.unlock(state.io);
            state.gpa.free(rgba);
            return;
        }
        // Riaggancio per id (l'array non cambia entro la stessa generazione,
        // ma il controllo tiene il worker onesto).
        var installed = false;
        for (thumbList(yt2, which)) |*r| {
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

/// Estrae l'id video (11 caratteri) da un link YouTube: youtube.com/watch?v=…,
/// youtu.be/…, shorts/, live/, embed/, v/, con o senza schema e con i prefissi
/// host "www."/"m."/"music.". Ritorna una slice DENTRO `url` (nessuna
/// allocazione), o null se non è un link video YouTube.
pub fn videoIdFromUrl(url: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, url, " \t\r\n");
    if (std.mem.startsWith(u8, s, "https://")) {
        s = s["https://".len..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        s = s["http://".len..];
    }
    if (std.mem.startsWith(u8, s, "www.")) {
        s = s["www.".len..];
    } else if (std.mem.startsWith(u8, s, "m.")) {
        s = s["m.".len..];
    } else if (std.mem.startsWith(u8, s, "music.")) {
        s = s["music.".len..];
    }

    if (std.mem.startsWith(u8, s, "youtu.be/")) return validVideoId(s["youtu.be/".len..]);
    if (!std.mem.startsWith(u8, s, "youtube.com/")) return null;
    s = s["youtube.com/".len..];
    for ([_][]const u8{ "shorts/", "live/", "embed/", "v/" }) |prefix| {
        if (std.mem.startsWith(u8, s, prefix)) return validVideoId(s[prefix.len..]);
    }
    if (std.mem.startsWith(u8, s, "watch?")) {
        var params = std.mem.tokenizeScalar(u8, s["watch?".len..], '&');
        while (params.next()) |kv| {
            if (std.mem.startsWith(u8, kv, "v=")) return validVideoId(kv["v=".len..]);
        }
    }
    return null;
}

/// Id video valido: esattamente 11 caratteri [A-Za-z0-9_-] in testa a `rest`
/// (ciò che segue — ?t=…, #…, / — viene ignorato).
fn validVideoId(rest: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) break;
    }
    if (end != 11) return null;
    return rest[0..11];
}

/// Apre direttamente un video dal suo id (link da riga di comando o incollato
/// nella query): titolo e URL diretti vengono chiesti a yt-dlp sul thread di
/// apertura. Da chiamare con `shared.mutex` acquisito.
pub fn openById(state: *GuiAppState, id: []const u8) void {
    if (comptime !has_video) return;
    if (state.shared.yt.opening) return;
    const id_owned = state.gpa.dupe(u8, id) catch return;
    startOpen(state, id_owned, null, 0, streamHeight(state));
}

/// Altezza da chiedere a yt-dlp: quella del chip o, con Auto, quella adatta alla
/// vista corrente. Con `shared.mutex` acquisito.
fn streamHeight(state: *GuiAppState) u32 {
    const h = quality_heights[state.shared.yt.quality];
    if (h != 0) return h;
    const view_h: u32 = if (state.win) |w| w.contentPx().h else 0;
    return yt_queue.autoHeight(view_h);
}

/// Avvia il thread di apertura (prende possesso di `id` e `title`). Con
/// `shared.mutex` acquisito e nessuna apertura in corso.
fn startOpen(state: *GuiAppState, id: []u8, title: ?[]u8, resume_s: f64, height: u32) void {
    const yt = &state.shared.yt;
    yt.opening = true;
    cancelOtherPrefetch(yt, id, height);
    // Il motore mpv si inizializza mentre yt-dlp risolve (apertura da link,
    // cambio qualità: lì l'overlay non è aperto).
    videomod.prewarmEngine(state.gpa);
    if (yt.err) |e| {
        state.gpa.free(e);
        yt.err = null;
    }
    state.shared.file_changed = true;
    // Da qui lo stream è la navigazione più recente: un file ancora in
    // caricamento non deve installarsi sopra (e chiudere il video), e se intanto
    // si naviga altrove è lo stream a dover rinunciare (vedi `openWorker`).
    const gen = nav.claimGeneration(state);
    const t = std.Thread.spawn(.{}, openWorker, .{ state, id, title, resume_s, height, gen }) catch {
        state.gpa.free(id);
        if (title) |tt| state.gpa.free(tt);
        yt.opening = false;
        setErr(state, "impossibile avviare l'apertura");
        return;
    };
    t.detach();
}

/// Apre il risultato selezionato: risolve gli URL diretti con `yt-dlp -g` e
/// avvia il player nativo, tutto su un thread di background.
/// Da chiamare con `shared.mutex` acquisito (thread finestra: Invio o click).
pub fn openSelected(state: *GuiAppState) void {
    if (comptime !has_video) return;
    const yt = &state.shared.yt;
    if (yt.opening) return;
    const cards = shown(yt);
    if (yt.sel < 0 or yt.sel >= @as(i32, @intCast(cards.len))) return;
    openResult(state, cards[@intCast(yt.sel)]);
}

/// Apre una card (risultato o voce della coda). Con `shared.mutex` acquisito.
fn openResult(state: *GuiAppState, r: Result) void {
    const id = state.gpa.dupe(u8, r.id) catch return;
    const title = state.gpa.dupe(u8, r.title) catch {
        state.gpa.free(id);
        return;
    };
    startOpen(state, id, title, 0, streamHeight(state));
}

/// Imposta la qualità (indice di `quality_heights`, dai chip dell'overlay).
/// Con uno stream YouTube attivo riapre il video alla stessa posizione con la
/// nuova qualità. Con `shared.mutex` acquisito.
pub fn setQuality(state: *GuiAppState, idx: u8) void {
    const yt = &state.shared.yt;
    if (idx >= quality_heights.len or yt.quality == idx) return;
    yt.quality = idx;
    state.shared.file_changed = true;
    const h = streamHeight(state);
    if (h != yt.stream_h) reopenCurrent(state, h);
}

/// Riapre lo stream YouTube corrente alla stessa posizione con altezza `height`.
/// Con `shared.mutex` acquisito.
fn reopenCurrent(state: *GuiAppState, height: u32) void {
    reopenAt(state, height, state.video.pos_s);
}

fn reopenAt(state: *GuiAppState, height: u32, pos_s: f64) void {
    if (comptime !has_video) return;
    // Un file è in caricamento: l'utente è già altrove. Riaprire lo stream ora
    // (qualità automatica, caduta) gli annullerebbe la navigazione.
    if (state.shared.loading) return;
    const yt = &state.shared.yt;
    if (yt.opening or yt.current_id == null or !state.video.isActive()) return;
    const r_id = state.gpa.dupe(u8, yt.current_id.?) catch return;
    const r_title = state.gpa.dupe(u8, state.shared.display_name) catch {
        state.gpa.free(r_id);
        return;
    };
    startOpen(state, r_id, r_title, pos_s, height);
}

/// Lo stream YouTube in riproduzione è caduto (rete, URL scaduto dopo una pausa
/// lunga): lo si riapre alla stessa posizione con una risoluzione nuova degli
/// indirizzi. Una seconda caduta entro `fail_retry_ms` non si ritenta: si apre
/// l'overlay con il messaggio. false se ciò che è aperto non è uno stream
/// YouTube. Con `shared.mutex` acquisito.
pub fn streamFailed(state: *GuiAppState, at_s: f64) bool {
    if (comptime !has_video) return false;
    const yt = &state.shared.yt;
    if (yt.current_id == null) return false;
    if (yt.opening) return true; // una riapertura è già in corso
    const now = zicro.widget.nowMs();
    if (yt.fail_reopen_ms != 0 and now - yt.fail_reopen_ms < fail_retry_ms) {
        yt.active = true;
        setErr(state, "lo stream si è interrotto");
        state.shared.file_changed = true;
        return true;
    }
    yt.fail_reopen_ms = now;
    // Gli indirizzi in mano possono essere proprio quelli scaduti.
    if (yt.pf) |*p| if (p.id.eql(yt.current_id.?)) {
        p.deinit(state.gpa);
        yt.pf = null;
    };
    reopenAt(state, if (yt.stream_h != 0) yt.stream_h else streamHeight(state), at_s);
    return true;
}

pub const fail_retry_ms: i64 = 30_000;

/// Da chiamare a ogni tick del player (render worker, con `shared.mutex`):
/// con Auto alza la qualità quando la vista (alta `view_h` pixel) è cresciuta ed
/// è rimasta ferma `raise_after_s`; a fine video passa al primo della coda.
pub fn tickStream(state: *GuiAppState, view_h: u32, dt: f32) void {
    if (comptime !has_video) return;
    const yt = &state.shared.yt;
    if (yt.current_id == null or yt.opening) {
        yt.prev_pos = -1;
        yt.raise_s = 0;
        return;
    }
    const vs = &state.video;

    // Fine video: FFmpeg e mpv lo fanno ricominciare, quindi la posizione torna
    // a zero dall'ultimo secondo senza un seek. Con l'overlay aperto (anche per
    // un errore d'apertura del prossimo) si lascia ricominciare.
    const pos = vs.pos_s;
    const ended = yt.prev_pos >= 0 and vs.dur_s > 2 and yt.prev_pos > vs.dur_s - 1.0 and
        pos < 1.0 and !vs.settle_seek and vs.seek_to < 0;
    yt.prev_pos = pos;
    if (ended and !yt.active and !state.shared.loading and yt.queue.items.len > 0) {
        playNext(state);
        return;
    }

    if (quality_heights[yt.quality] == 0 and view_h == yt.raise_view_h and yt_queue.shouldRaise(yt.stream_h, view_h)) {
        yt.raise_s += dt;
        if (yt.raise_s >= yt_queue.raise_after_s) {
            yt.raise_s = 0;
            reopenCurrent(state, yt_queue.autoHeight(view_h));
        }
    } else yt.raise_s = 0;
    yt.raise_view_h = view_h;
}

// ── Coda "guarda dopo" ───────────────────────────────────────────────────────

fn queuePath(state: *GuiAppState) ?[]u8 {
    const home = vtcache.getEnvAlloc(state.gpa, if (builtin.os.tag == .windows) "APPDATA" else "HOME") orelse return null;
    defer state.gpa.free(home);
    return yt_queue.filePath(state.gpa, home) catch null;
}

fn queueIndex(yt: *YtState, id: []const u8) ?usize {
    for (yt.queue.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.id, id)) return i;
    }
    return null;
}

/// Accoda una copia dei campi (la miniatura, se c'è, si copia: niente download).
fn appendQueue(state: *GuiAppState, f: yt_queue.Fields, thumb: []const u8, tw: u32, th: u32) !void {
    const gpa = state.gpa;
    // Anche gli id letti dal file della coda finiscono nei percorsi della cache.
    if (validVideoId(f.id) == null or f.id.len != 11) return error.InvalidVideoId;
    var r: Result = .{ .id = try gpa.dupe(u8, f.id), .title = &.{}, .duration = &.{}, .channel = &.{} };
    errdefer freeResult(gpa, r);
    r.title = try gpa.dupe(u8, f.title);
    r.duration = try gpa.dupe(u8, f.duration);
    r.channel = try gpa.dupe(u8, f.channel);
    if (tw != 0) {
        const px = try gpa.alignedAlloc(u8, .@"4", thumb.len);
        @memcpy(px, thumb);
        r.thumb_rgba = px;
        r.thumb_w = tw;
        r.thumb_h = th;
    }
    try state.shared.yt.queue.append(gpa, r);
}

fn removeQueueAt(state: *GuiAppState, i: usize) void {
    const yt = &state.shared.yt;
    freeResult(state.gpa, yt.queue.orderedRemove(i));
    if (yt.show_queue) {
        const n: i32 = @intCast(yt.queue.items.len);
        if (yt.sel >= n) yt.sel = n - 1;
    }
}

/// Legge la coda dal disco la prima volta che serve. Con `shared.mutex` acquisito.
pub fn ensureQueueLoaded(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    if (yt.queue_loaded) return;
    yt.queue_loaded = true;
    const path = queuePath(state) orelse return;
    defer state.gpa.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(state.io, path, state.gpa, .limited(1 << 20)) catch return;
    defer state.gpa.free(bytes);
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        const f = yt_queue.parseLine(line) orelse continue;
        if (queueIndex(yt, f.id) != null) continue;
        appendQueue(state, f, &.{}, 0, 0) catch break;
    }
    startQueueThumbs(state);
}

/// Riscrive il file della coda (su un temporaneo, poi rinominato: un'uscita a
/// metà non lascia un file troncato). Con `shared.mutex` acquisito.
fn saveQueue(state: *GuiAppState) void {
    const path = queuePath(state) orelse return;
    defer state.gpa.free(path);
    var aw: std.Io.Writer.Allocating = .init(state.gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll(yt_queue.header ++ "\n") catch return;
    for (state.shared.yt.queue.items) |r| {
        yt_queue.writeLine(w, .{ .id = r.id, .title = r.title, .duration = r.duration, .channel = r.channel }) catch return;
    }
    vtcache.makeDirs(path);
    const tmp = std.fmt.allocPrint(state.gpa, "{s}.tmp", .{path}) catch return;
    defer state.gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(state.io, .{ .sub_path = tmp, .data = aw.written() }) catch return;
    cwd.rename(tmp, cwd, path, state.io) catch {};
}

/// Aggiunge alla coda la card `i` della griglia, o la toglie se c'è già.
/// Con `shared.mutex` acquisito.
pub fn toggleQueueAt(state: *GuiAppState, i: i32) void {
    const yt = &state.shared.yt;
    ensureQueueLoaded(state);
    const cards = shown(yt);
    if (i < 0 or i >= @as(i32, @intCast(cards.len))) return;
    const r = cards[@intCast(i)];
    if (queueIndex(yt, r.id)) |qi| {
        removeQueueAt(state, qi);
    } else {
        appendQueue(state, .{ .id = r.id, .title = r.title, .duration = r.duration, .channel = r.channel }, r.thumb_rgba, r.thumb_w, r.thumb_h) catch return;
    }
    saveQueue(state);
    state.shared.file_changed = true;
}

/// La griglia passa dai risultati alla coda e viceversa (chip "Coda").
/// Con `shared.mutex` acquisito.
pub fn toggleQueueView(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    ensureQueueLoaded(state);
    yt.show_queue = !yt.show_queue;
    yt.sel = if (shown(yt).len > 0) 0 else -1;
    yt.scroll = .{};
    state.shared.file_changed = true;
}

/// Apre il primo video della coda (che ne esce quando parte). Tasto `n` e fine
/// video. Con `shared.mutex` acquisito.
pub fn playNext(state: *GuiAppState) void {
    if (comptime !has_video) return;
    const yt = &state.shared.yt;
    ensureQueueLoaded(state);
    if (yt.opening or yt.queue.items.len == 0) return;
    openResult(state, yt.queue.items[0]);
}

/// Posizione nella coda (da 1) del video `id`, o 0 se non c'è.
fn queuePos(yt: *YtState, id: []const u8) usize {
    return if (queueIndex(yt, id)) |i| i + 1 else 0;
}

/// Apre nel browser la pagina YouTube del video: la card selezionata (overlay
/// aperto, Ctrl+O) o il video in riproduzione (tasto `o`). L'handoff al browser
/// (subprocess) avviene su un thread. Con `shared.mutex` acquisito.
pub fn openPageLocked(state: *GuiAppState) void {
    const yt = &state.shared.yt;
    const id: []const u8 = blk: {
        if (yt.active and yt.sel >= 0 and yt.sel < @as(i32, @intCast(shown(yt).len)))
            break :blk shown(yt)[@intCast(yt.sel)].id;
        break :blk yt.current_id orelse return;
    };
    const url = std.fmt.allocPrint(state.gpa, "https://www.youtube.com/watch?v={s}", .{id}) catch return;
    const t = std.Thread.spawn(.{}, browserWorker, .{ state, url }) catch {
        state.gpa.free(url);
        return;
    };
    t.detach();
}

/// Apre `url` nel browser su un thread (subprocess). Con `shared.mutex` acquisito o no.
fn openUrl(state: *GuiAppState, url: []const u8) void {
    const owned = state.gpa.dupe(u8, url) catch return;
    const t = std.Thread.spawn(.{}, browserWorker, .{ state, owned }) catch {
        state.gpa.free(owned);
        return;
    };
    t.detach();
}

/// L'errore mostrato è "yt-dlp non trovato" (la riga di stato porta al download).
fn missingShown(yt: anytype) bool {
    const e = yt.err orelse return false;
    return !yt.opening and std.mem.eql(u8, e, ytdlp.missing_msg);
}

/// Il punto è sulla riga di stato (errore / "apertura stream…") del pannello.
/// Riga di stato sotto i chip: errore, apertura in corso o coda vuota.
fn hasStatus(yt: *YtState) bool {
    return yt.err != null or yt.opening or (yt.show_queue and yt.queue.items.len == 0);
}

fn statusHit(lay: anytype, mx: f32, my: f32) bool {
    const sy = lay.yp + pad + input_h + qual_h;
    return mx >= @as(f32, @floatFromInt(lay.xp)) and mx < @as(f32, @floatFromInt(lay.xp + lay.wp)) and
        my >= @as(f32, @floatFromInt(sy)) and my < @as(f32, @floatFromInt(sy + status_h));
}

fn browserWorker(state: *GuiAppState, url: []u8) void {
    _ = crash_report.openBrowser(state.gpa, url);
    state.gpa.free(url);
}

fn finishOpenErr(state: *GuiAppState, gen: u32, msg: []const u8) void {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    state.shared.yt.opening = false;
    // Nel frattempo si è navigato altrove: l'errore di un'apertura abbandonata
    // non riapre l'overlay sopra il file nuovo né gli spegne lo spinner.
    if (nav.navSuperseded(state, gen)) {
        state.shared.file_changed = true;
        return;
    }
    // L'apertura può essere partita fuori dall'overlay (link da riga di comando,
    // Esc durante l'attesa): spegni lo spinner d'avvio e mostra l'overlay,
    // altrimenti l'errore resterebbe muto.
    state.shared.loading = false;
    state.shared.yt.active = true;
    setErr(state, msg);
    state.shared.file_changed = true;
}

const ResolveError = error{ YtDlpMissing, Timeout, Canceled, NotRunnable, NotPlayable, NoUrl, OutOfMemory };

fn resolveErrMsg(e: ResolveError) []const u8 {
    return switch (e) {
        error.YtDlpMissing => ytdlp.missing_msg,
        error.Timeout => "risoluzione stream scaduta",
        error.Canceled => "risoluzione annullata",
        error.NotRunnable => "yt-dlp non eseguibile",
        error.NotPlayable => "video non riproducibile (yt-dlp)",
        error.NoUrl => "nessun URL dallo stream",
        error.OutOfMemory => "memoria esaurita",
    };
}

/// Una chiamata yt-dlp → titolo, URL video (DASH, altezza ≤ `height`) + URL
/// audio (o uno solo muxed) e URL dei sottotitoli it/en. I sottotitoli in
/// modalità simulata non costano richieste: escono dalla stessa estrazione.
/// Il grosso del tempo (secondi) è la JS challenge di YouTube risolta da yt-dlp
/// con deno: per questo la card selezionata si risolve in anticipo (prefetch).
fn resolve(gpa: std.mem.Allocator, io: std.Io, id: []const u8, height: u32, cancel: ?*const std.atomic.Value(bool)) ResolveError!Resolved {
    var r: Resolved = .{ .id = .{}, .height = height, .at_ms = 0, .out = &.{}, .title = "", .vurl = "", .aurl = "", .subs = "" };
    if (!r.id.set(id)) return error.NoUrl;

    const exe = ytdlp.find(gpa, io) orelse return error.YtDlpMissing;
    defer gpa.free(exe);
    const url = try std.fmt.allocPrint(gpa, "https://www.youtube.com/watch?v={s}", .{id});
    defer gpa.free(url);

    // Selettore formato dalla qualità scelta nei chip dell'overlay.
    var fmt_buf: [48]u8 = undefined;
    const fmt_sel = std.fmt.bufPrint(&fmt_buf, "bv*[height<={d}]+ba/b", .{height}) catch "bv*[height<=720]+ba/b";
    // A parità di risoluzione e fps, il codec che la GPU decodifica in hardware
    // (altrimenti yt-dlp sceglie AV1/VP9 anche dove finirebbero in software).
    var sort_buf: [48]u8 = undefined;
    const sort: ?[]const u8 = if (hwdec_caps.get()) |caps| hwdec_caps.ytdlpSort(&sort_buf, caps, height) else null;

    // Righe in uscita: titolo, 1-2 URL (`--print urls` = `-g`), "subs:it=… en=…".
    // (Le chiavi col trattino, tipo en-orig, il template di yt-dlp non le legge.)
    var argv_buf: [20][]const u8 = undefined;
    var argc: usize = 0;
    const head = [_][]const u8{
        exe,            "--no-warnings",     "--no-playlist",
        "--print",      "%(title).96s",      "--print",
        "urls",         "--print",           "subs:it=%(requested_subtitles.it.url|)s en=%(requested_subtitles.en.url|)s",
        "--write-subs", "--write-auto-subs", "--sub-langs",
        "it,en",        "--sub-format",      "vtt",
    };
    for (head) |a| {
        argv_buf[argc] = a;
        argc += 1;
    }
    if (sort) |srt| {
        argv_buf[argc] = "-S";
        argv_buf[argc + 1] = srt;
        argc += 2;
    }
    argv_buf[argc] = "-f";
    argv_buf[argc + 1] = fmt_sel;
    argv_buf[argc + 2] = url;
    argc += 3;
    const argv = argv_buf[0..argc];
    // Sempre la variante interrompibile, anche senza annullamento: il gruppo di
    // processi proprio fa sì che un timeout termini anche deno, non solo yt-dlp.
    const never: std.atomic.Value(bool) = .init(false);
    var res = decoder_mod.runCaptureCancel(gpa, argv, 60_000, cancel orelse &never) catch |e| return switch (e) {
        error.Timeout => error.Timeout,
        error.Canceled => error.Canceled,
        else => error.NotRunnable,
    };
    errdefer res.deinit(gpa);
    if (res.exit_code != 0) return error.NotPlayable;

    const o = try ytdlp.parseOutput(res.stdout);
    r.title = o.title;
    r.vurl = o.vurl;
    r.aurl = o.aurl;
    r.subs = o.subs;
    r.out = res.stdout;
    r.at_ms = zicro.widget.nowMs();
    return r;
}

/// Il prefetch di (`id`, `height`) se è pronto e fresco; se è ancora in volo lo
/// aspetta (meglio che lanciare un secondo yt-dlp identico). null = da risolvere.
fn takeResolved(state: *GuiAppState, id: []const u8, height: u32) ?Resolved {
    // Il prefetch ha il suo timeout (60 s, vedi `resolve`): oltre, qualcosa non va.
    var waited_ms: u32 = 0;
    while (waited_ms < 65_000) : (waited_ms += 50) {
        {
            state.shared.mutex.lockUncancelable(state.io);
            defer state.shared.mutex.unlock(state.io);
            const yt = &state.shared.yt;
            if (yt.pf) |*p| if (p.fresh(id, height)) {
                const r = p.*;
                yt.pf = null;
                return r;
            };
            const in_flight = yt.pf_busy and yt.pf_tried.eql(id) and yt.pf_tried_h == height;
            if (!in_flight) return null;
        }
        state.io.sleep(.fromMilliseconds(50), .awake) catch return null;
    }
    return null;
}

/// Da chiamare a ogni draw dell'overlay (con `shared.mutex`): se la card
/// selezionata non è ancora risolta e nessun prefetch è in volo, ne avvia uno.
/// Uno alla volta: scorrendo la griglia, alla fine del prefetch corrente si
/// riparte dalla card selezionata in quel momento (il worker chiede un redraw).
fn tickPrefetch(state: *GuiAppState) void {
    if (comptime !has_video) return;
    const yt = &state.shared.yt;
    // Durante un'apertura il motore l'ha già preparato `startOpen`.
    if (!yt.active or yt.opening) return;
    // Overlay aperto = probabile apertura in arrivo: un motore mpv già pronto
    // (il video in corso tiene occupato il suo) risparmia ~0,5 s al primo frame.
    // Una volta per selezione (vedi `prewarm_sel`).
    if (yt.prewarm_sel != yt.sel) {
        yt.prewarm_sel = yt.sel;
        videomod.prewarmEngine(state.gpa);
    }
    if (yt.pf_busy) return;
    const cards = shown(yt);
    if (yt.sel < 0 or yt.sel >= @as(i32, @intCast(cards.len))) return;
    const id = cards[@intCast(yt.sel)].id;
    const height = streamHeight(state);
    if (yt.pf_tried.eql(id) and yt.pf_tried_h == height) return;
    if (yt.pf) |*p| if (p.fresh(id, height)) return;
    var idb: IdBuf = .{};
    if (!idb.set(id)) return;
    const cancel = state.gpa.create(std.atomic.Value(bool)) catch return;
    cancel.* = .init(false);
    yt.pf_busy = true;
    yt.pf_cancel = cancel;
    yt.pf_tried = idb;
    yt.pf_tried_h = height;
    const t = std.Thread.spawn(.{}, prefetchWorker, .{ state, idb, height, cancel }) catch {
        yt.pf_busy = false;
        yt.pf_cancel = null;
        state.gpa.destroy(cancel);
        return;
    };
    t.detach();
}

/// Interrompe il prefetch in volo se non è (`id`, `height`): chi apre un altro
/// video non deve contendersi rete e CPU con una risoluzione ormai inutile.
/// Con `shared.mutex` acquisito.
fn cancelOtherPrefetch(yt: *YtState, id: []const u8, height: u32) void {
    if (!yt.pf_busy) return;
    if (yt.pf_tried.eql(id) and yt.pf_tried_h == height) return;
    if (yt.pf_cancel) |c| c.store(true, .release);
}

/// Prende possesso di `cancel` (lo libera dopo averlo staccato da `YtState`).
fn prefetchWorker(state: *GuiAppState, id: IdBuf, height: u32, cancel: *std.atomic.Value(bool)) void {
    var r_opt: ?Resolved = resolve(state.gpa, state.io, id.get(), height, cancel) catch null;
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const yt = &state.shared.yt;
    yt.pf_busy = false;
    yt.pf_cancel = null;
    // Annullato: si potrà ritentare se la card torna selezionata.
    if (cancel.load(.acquire)) yt.pf_tried = .{};
    state.gpa.destroy(cancel);
    if (r_opt) |*r| {
        if (yt.pf) |*old| old.deinit(state.gpa);
        yt.pf = r.*;
        r_opt = null;
    }
    // Un redraw: se intanto la selezione è cambiata, `tickPrefetch` riparte.
    state.shared.file_changed = true;
}

/// Thread di apertura: risolve lo stream (dal prefetch se pronto, altrimenti
/// con yt-dlp, vedi `resolve`). Con `title_opt == null` (apertura da link) il
/// titolo è quello di yt-dlp. Con `resume_s > 0` (cambio qualità) la
/// riproduzione riparte da lì. Il container libav viene aperto QUI, fuori dal
/// lock (rete: secondi); solo lo swap dello stato avviene sotto `mutex`.
/// Prende possesso di `id` e `title_opt`.
fn openWorker(state: *GuiAppState, id: []u8, title_opt: ?[]u8, resume_s: f64, height: u32, gen: u32) void {
    defer state.gpa.free(id);
    if (comptime !has_video) {
        if (title_opt) |t| state.gpa.free(t);
        return;
    }

    var from_pf = true;
    var res: Resolved = takeResolved(state, id, height) orelse blk: {
        from_pf = false;
        break :blk resolve(state.gpa, state.io, id, height, null) catch |e| {
            if (title_opt) |t| state.gpa.free(t);
            finishOpenErr(state, gen, resolveErrMsg(e));
            return;
        };
    };
    defer res.deinit(state.gpa);

    // Mai vuoto: `display_name` non vuoto è ciò che dice «c'è uno stream aperto».
    const title: []u8 = title: {
        if (title_opt) |t| {
            if (t.len > 0) break :title t;
            state.gpa.free(t);
        }
        break :title state.gpa.dupe(u8, if (res.title.len > 0) res.title else "YouTube") catch {
            finishOpenErr(state, gen, "memoria esaurita");
            return;
        };
    };

    // Apre il container in uno stato LOCALE: niente lock durante l'handshake di
    // rete. Lo swap col player corrente avviene dopo, sotto `mutex`.
    var local: videomod.VideoState = .{};
    const first = videomod.setupStream(&local, res.vurl, res.aurl, resume_s, state.gpa) catch |e| retry: {
        // URL dal prefetch rifiutati (scaduti, rete cambiata): si risolve da capo.
        if (from_pf) {
            res.deinit(state.gpa);
            res.out = &.{};
            if (resolve(state.gpa, state.io, id, height, null)) |fresh_res| {
                res = fresh_res;
                local = .{};
                if (videomod.setupStream(&local, res.vurl, res.aurl, resume_s, state.gpa)) |f| break :retry f else |_| {}
            } else |_| {}
        }
        state.gpa.free(title);
        finishOpenErr(state, gen, @errorName(e));
        return;
    };
    const vurl = res.vurl;
    const sub_urls: []u8 = state.gpa.dupe(u8, res.subs) catch &[_]u8{};

    // Riaperture dello stesso video (qualità) tengono la finestra com'è: Auto
    // riapre proprio perché l'utente l'ha ingrandita.
    var same_vid = false;
    // Proporzioni della sorgente, lette sotto il lock all'install (vedi in fondo).
    var src_aspect: [2]u32 = .{ first.w, first.h };
    {
        state.shared.mutex.lockUncancelable(state.io);
        defer state.shared.mutex.unlock(state.io);

        // yt-dlp e l'apertura hanno preso secondi: se intanto l'utente ha aperto
        // altro (frecce, esploratore, un altro file) questo stream è superato e
        // non si installa sopra. Stesso controllo, sotto lo stesso lock, del
        // loader in `applyDecoded`.
        if (nav.navSuperseded(state, gen)) {
            local.deinit();
            state.gpa.free(first.rgba);
            state.gpa.free(title);
            state.gpa.free(sub_urls);
            state.shared.yt.opening = false;
            state.shared.file_changed = true;
            return;
        }

        // Stessa sequenza della navigazione verso un video (applyDecoded): ferma il
        // player precedente PRIMA di installare il nuovo, sotto lo stesso mutex del
        // worker che chiama advanceVideo/advanceAudio.
        state.video.deinit();
        state.video = local;
        // Cambio qualità: la sessione è già aperta alla posizione a cui si era
        // (`setupStream` con `resume_s`), in pausa finché non è installata.

        // Sorgenti correnti per il toggle 'v' (video ↔ solo audio con oscilloscopio).
        gui_state_mod.setAvSrc(state, vurl, true);

        state.gpa.free(state.shared.static_rgba);
        state.shared.static_serial +%= 1;
        state.shared.static_rgba = first.rgba;
        state.shared.static_w = first.w;
        state.shared.static_h = first.h;

        // Uno stream non ha un percorso: il titolo va nel nome da mostrare.
        // `current_file_index` e la lista restano dove erano, così le frecce
        // ripartono dal file che si guardava prima.
        state.gpa.free(state.shared.current_file_path);
        state.shared.current_file_path = &.{};
        state.gpa.free(state.shared.display_name);
        state.shared.display_name = title; // possesso trasferito
        state.shared.is_text = false;
        state.shared.is_table = false;
        state.shared.sel_active = false;

        const yt = &state.shared.yt;
        // Id corrente (tasto `o`, sottotitoli, cambio qualità). Se è lo STESSO
        // video (riapertura per qualità) i sottotitoli già caricati restano
        // validi; per un video nuovo si riparte da zero (il toggle `c` riscarica).
        same_vid = if (yt.current_id) |cid| std.mem.eql(u8, cid, id) else false;
        if (!same_vid) {
            if (yt.current_id) |cid| state.gpa.free(cid);
            yt.current_id = state.gpa.dupe(u8, id) catch null;
            freeSubs(state);
            yt.subs_on = false;
        }
        state.gpa.free(yt.sub_urls);
        yt.sub_urls = sub_urls; // possesso trasferito
        yt.stream_h = height;
        yt.raise_s = 0;
        yt.prev_pos = -1;
        // Un video aperto esce dalla coda "guarda dopo" (da lì o dai risultati).
        ensureQueueLoaded(state);
        if (queueIndex(yt, id)) |qi| {
            removeQueueAt(state, qi);
            saveQueue(state);
        }
        yt.opening = false;
        yt.active = false; // overlay chiuso: si riapre con `y` (query/risultati restano)
        state.shared.loading = false; // spinner d'avvio (apertura da link): spento
        state.shared.file_changed = true;
        if (state.video.decoder) |dec| {
            if (dec.src_w > 0 and dec.src_h > 0) src_aspect = .{ dec.src_w, dec.src_h };
        }
    }

    // La finestra si adatta alle proporzioni reali del video appena aperto
    // (stessa euristica di `nav.resizeToContent`). Fuori dal lock: `requestResize`
    // è thread-safe (differisce al thread finestra) e no-op in fullscreen.
    if (state.win) |w| if (!same_vid) {
        // Proporzioni del video PRIMA del resize, come `nav.resizeToContent`: la
        // finestra applica il blocco anche alla taglia chiesta. Con quelle del
        // contenuto di prima (un'immagine 4:3) la portava a 960×720, e subito
        // dopo il worker, impostando le 16:9, la rimappava una seconda volta a
        // 1109×624: due rimappature di fila, e su sway la finestra a volte non
        // tornava più a schermo. Gli stessi numeri che userà il worker
        // (`src_w`×`src_h`): per lui sarà un no-op.
        w.setContentAspect(src_aspect[0], src_aspect[1]);
        const az = layout_mod.autoZoomForContent(.video, first.w, first.h);
        const size = layout_mod.initialWindowSize(.video, layout_mod.scaleDim(first.w, az), layout_mod.scaleDim(first.h, az));
        w.requestResize(size.w, size.h);
    };
}

// ── Sottotitoli ──────────────────────────────────────────────────────────────

/// Toggle sottotitoli (tasto `c` durante uno stream YouTube): la prima volta li
/// scarica con yt-dlp su un thread (lingua it, poi en, inclusi gli
/// auto-generati); le volte successive accende/spegne quelli già caricati.
/// Con `shared.mutex` acquisito.
pub fn toggleSubs(state: *GuiAppState) void {
    if (comptime !has_video) return;
    const yt = &state.shared.yt;
    if (yt.subs.len > 0) {
        yt.subs_on = !yt.subs_on;
        state.shared.file_changed = true;
        return;
    }
    if (yt.subs_loading) return;
    const cid = yt.current_id orelse return; // il player corrente non è YouTube
    const id = state.gpa.dupe(u8, cid) catch return;
    const urls = state.gpa.dupe(u8, yt.sub_urls) catch {
        state.gpa.free(id);
        return;
    };
    yt.subs_loading = true;
    const t = std.Thread.spawn(.{}, subsWorker, .{ state, id, urls }) catch {
        state.gpa.free(id);
        state.gpa.free(urls);
        yt.subs_loading = false;
        return;
    };
    t.detach();
}

/// Thread sottotitoli: il VTT finisce nella cache
/// (`~/.cache/zuer/ytsubs/<id>.<lingua>.vtt`), lo si parsa in cue e si installa
/// solo se il video corrente è ancora `id`. Prende possesso di `id` e `urls`.
fn subsWorker(state: *GuiAppState, id: []u8, urls: []u8) void {
    defer state.gpa.free(id);
    defer state.gpa.free(urls);
    const cues = fetchSubs(state, id, urls) catch |e| {
        std.debug.print("[yt] sottotitoli non disponibili: {s}\n", .{@errorName(e)});
        finishSubs(state, id, null);
        return;
    };
    finishSubs(state, id, cues);
}

fn finishSubs(state: *GuiAppState, id: []const u8, cues_opt: ?[]SubCue) void {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const yt = &state.shared.yt;
    yt.subs_loading = false;
    const still = if (yt.current_id) |cid| std.mem.eql(u8, cid, id) else false;
    const cues = cues_opt orelse return;
    if (!still or cues.len == 0) {
        for (cues) |c| state.gpa.free(c.text);
        state.gpa.free(cues);
        return;
    }
    freeSubs(state);
    yt.subs = cues;
    yt.subs_on = true;
    state.shared.file_changed = true;
}

/// Scarica (o riusa dalla cache) il VTT del video e lo parsa in cue. Prima gli
/// URL già noti dall'apertura (`urls`, "it=URL en=URL": una GET con curl, meno
/// di un secondo), poi, se mancano o falliscono, una estrazione yt-dlp intera.
fn fetchSubs(state: *GuiAppState, id: []const u8, urls: []const u8) ![]SubCue {
    const gpa = state.gpa;
    const dir = vtcache.appCacheDir(gpa, "ytsubs") orelse return error.NoCacheDir;
    defer gpa.free(dir);

    // Cache su disco: un VTT già scaricato per questo id evita la rete.
    var vtt_path = findSubFile(gpa, state.io, dir, id);
    if (vtt_path == null) vtt_path = curlSubs(gpa, state.io, dir, id, urls);
    if (vtt_path == null) {
        const exe = ytdlp.find(gpa, state.io) orelse return error.YtDlpMissing;
        defer gpa.free(exe);
        const url = try std.fmt.allocPrint(gpa, "https://www.youtube.com/watch?v={s}", .{id});
        defer gpa.free(url);
        const out_tpl = try std.fmt.allocPrint(gpa, "{s}/%(id)s.%(ext)s", .{dir});
        defer gpa.free(out_tpl);
        var res = try decoder_mod.runCaptureTimeout(gpa, &.{
            exe,            "--no-warnings",     "--no-playlist", "--skip-download",
            "--write-subs", "--write-auto-subs", "--sub-langs",   "it,en,en-orig",
            "--sub-format", "vtt/best",          "-o",            out_tpl,
            url,
        }, 40_000);
        res.deinit(gpa);
        vtt_path = findSubFile(gpa, state.io, dir, id);
    }
    const path = vtt_path orelse return error.NoSubtitles;
    defer gpa.free(path);
    const raw = try std.Io.Dir.cwd().readFileAlloc(state.io, path, gpa, .limited(8 << 20));
    defer gpa.free(raw);
    return parseVtt(gpa, raw);
}

/// Scarica il primo VTT disponibile fra gli URL "lingua=URL" (in ordine di
/// preferenza) in `<dir>/<id>.<lingua>.vtt`. Ritorna il percorso (posseduto).
fn curlSubs(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, id: []const u8, urls: []const u8) ?[]u8 {
    if (!std.fs.path.isAbsolute(dir)) return null; // rename/delete *Absolute
    var it = std.mem.tokenizeScalar(u8, urls, ' ');
    while (it.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const lang = field[0..eq];
        const url = field[eq + 1 ..];
        if (lang.len == 0 or !std.mem.startsWith(u8, url, "https://")) continue;
        // Scarica su un .part e rinomina: un file troncato non entra in cache.
        const path = std.fmt.allocPrint(gpa, "{s}/{s}.{s}.vtt", .{ dir, id, lang }) catch return null;
        const part = std.fmt.allocPrint(gpa, "{s}.part", .{path}) catch {
            gpa.free(path);
            return null;
        };
        defer gpa.free(part);
        const ok = blk: {
            var dl = decoder_mod.runCaptureTimeout(gpa, &.{ "curl", "-fsSL", "-m", "15", "-o", part, url }, 20_000) catch break :blk false;
            defer dl.deinit(gpa);
            break :blk dl.exit_code == 0;
        };
        if (ok) {
            if (std.Io.Dir.renameAbsolute(part, path, io)) |_| return path else |_| {}
        }
        std.Io.Dir.deleteFileAbsolute(io, part) catch {};
        gpa.free(path);
    }
    return null;
}

/// Cerca nella cache un `<id>.<lingua>.vtt`, preferendo it → en → altro.
/// Ritorna il percorso completo (posseduto) o null.
fn findSubFile(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, id: []const u8) ?[]u8 {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return null;
    defer d.close(io);
    var best: ?[]u8 = null;
    var best_rank: u8 = 255;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, id) or name.len <= id.len + 4) continue;
        if (name[id.len] != '.' or !std.mem.endsWith(u8, name, ".vtt")) continue;
        const lang = name[id.len + 1 .. name.len - 4];
        const rank: u8 = if (std.mem.startsWith(u8, lang, "it")) 0 else if (std.mem.startsWith(u8, lang, "en")) 1 else 2;
        if (rank < best_rank) {
            const full = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
            if (best) |b| gpa.free(b);
            best = full;
            best_rank = rank;
        }
    }
    return best;
}

/// Parser minimale del WebVTT di YouTube: cue "start --> end" seguito dal testo
/// su una o più righe. I tag inline (`<c>`, `<00:00:00.000>`) vengono strippati;
/// i cue "rolling" degli auto-sub (testo del cue precedente ripetuto in testa)
/// vengono deduplicati tenendo solo la parte nuova.
fn parseVtt(gpa: std.mem.Allocator, raw: []const u8) ![]SubCue {
    var cues: std.ArrayList(SubCue) = .empty;
    errdefer {
        for (cues.items) |c| gpa.free(c.text);
        cues.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        const arrow = std.mem.indexOf(u8, line, "-->") orelse continue;
        const start = parseVttTs(std.mem.trim(u8, line[0..arrow], " \t")) orelse continue;
        var end_part = std.mem.trim(u8, line[arrow + 3 ..], " \t");
        // Dopo il timestamp possono esserci i cue settings (align:start …).
        if (std.mem.indexOfScalar(u8, end_part, ' ')) |sp| end_part = end_part[0..sp];
        const end = parseVttTs(end_part) orelse continue;

        // Testo del cue: righe fino alla riga vuota, tag strippati, unite da spazio.
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        while (lines.next()) |tl0| {
            const tl = std.mem.trimEnd(u8, tl0, "\r");
            if (tl.len == 0) break;
            if (text.items.len > 0) try text.append(gpa, ' ');
            try appendStripped(&text, gpa, tl);
        }
        const clean = std.mem.trim(u8, text.items, " ");
        if (clean.len == 0) continue;

        if (cues.items.len > 0) {
            const prev = &cues.items[cues.items.len - 1];
            if (std.mem.eql(u8, prev.text, clean)) {
                prev.end = @max(prev.end, end);
                continue;
            }
            // Auto-sub rolling: il cue nuovo ripete il precedente in testa.
            if (clean.len > prev.text.len and std.mem.startsWith(u8, clean, prev.text)) {
                const rest = std.mem.trim(u8, clean[prev.text.len..], " ");
                if (rest.len > 0) {
                    try cues.append(gpa, .{ .start = start, .end = end, .text = try gpa.dupe(u8, rest) });
                }
                continue;
            }
        }
        try cues.append(gpa, .{ .start = start, .end = end, .text = try gpa.dupe(u8, clean) });
        if (cues.items.len >= 20_000) break; // tetto di sanità
    }
    return cues.toOwnedSlice(gpa);
}

/// "HH:MM:SS.mmm" o "MM:SS.mmm" → secondi. null se malformato.
fn parseVttTs(s: []const u8) ?f64 {
    var parts = std.mem.splitScalar(u8, s, ':');
    var vals: [3]f64 = .{ 0, 0, 0 };
    var n: usize = 0;
    while (parts.next()) |p| {
        if (n >= 3) return null;
        vals[n] = std.fmt.parseFloat(f64, p) catch return null;
        n += 1;
    }
    return switch (n) {
        2 => vals[0] * 60 + vals[1],
        3 => vals[0] * 3600 + vals[1] * 60 + vals[2],
        else => null,
    };
}

/// Appende `s` a `out` senza i tag `<…>` e con le entity HTML comuni decodificate.
fn appendStripped(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == '<') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '>')) |e| {
                i = e + 1;
                continue;
            }
            break; // '<' senza chiusura: scarta il resto
        }
        if (ch == '&') {
            const ents = .{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&nbsp;", " " } };
            var matched = false;
            inline for (ents) |ent| {
                if (!matched and std.mem.startsWith(u8, s[i..], ent[0])) {
                    try out.appendSlice(gpa, ent[1]);
                    i += ent[0].len;
                    matched = true;
                }
            }
            if (matched) continue;
        }
        try out.append(gpa, ch);
        i += 1;
    }
}

/// Testo del sottotitolo attivo a `pos_s`, o null. L'indice dell'ultimo cue è
/// cacheato: il lookup del frame successivo riparte da lì (i cue sono ordinati).
/// Con `shared.mutex` acquisito; la slice è valida finché i sub non cambiano.
pub fn currentSubText(state: *GuiAppState, pos_s: f64) ?[]const u8 {
    const yt = &state.shared.yt;
    if (!yt.subs_on or yt.subs.len == 0) return null;
    var i = @min(yt.sub_idx, yt.subs.len - 1);
    while (i > 0 and yt.subs[i].start > pos_s) i -= 1;
    while (i + 1 < yt.subs.len and yt.subs[i + 1].start <= pos_s) i += 1;
    yt.sub_idx = i;
    const c = yt.subs[i];
    return if (pos_s >= c.start and pos_s <= c.end) c.text else null;
}

// ── Geometria della griglia (condivisa da draw e hit-test) ───────────────────

pub const grid_cols: i32 = 3;
// Il pannello copre la finestra (fondo pieno, `overlay_ui`): niente cornice, il
// contenuto sta in una colonna centrata larga al più `max_w`.
const pad: i32 = 0;
const gap: i32 = 16;
const side: i32 = 28;
const col_max_w: i32 = 980;
const input_h: i32 = 44;
/// Sotto la miniatura: due righe di titolo e il canale.
const title_strip_h: i32 = 66;
const status_h: i32 = 28;
const panel_top: i32 = 24;
// Riga sotto il campo: "Coda" a sinistra, qualità (controllo segmentato) a destra.
// Larghezze FISSE (niente metriche font): la stessa geometria serve anche
// all'hit-test del mouse, che non ha raster.
const qual_h: i32 = 48;
const chip_w: i32 = 54;
const chip_h: i32 = 28;

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
/// di stato opzionale (errore/apertura). Le card scorrono in pixel (`YtState.scroll`)
/// dentro una banda alta `vis_rows` righe.
fn layoutFor(W: u32, H: u32, n: usize, status: bool) Layout {
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const wp: i32 = @min(wi - 2 * side, col_max_w);
    const xp = @divTrunc(wi - wp, 2);
    const card_w = @divTrunc(wp - pad * 2 - gap * (grid_cols - 1), grid_cols);
    const thumb_h = @divTrunc(card_w * 9, 16);
    const card_h = thumb_h + title_strip_h;
    const st: i32 = if (status) status_h else 0;
    const total_rows: i32 = @intCast((n + @as(usize, @intCast(grid_cols)) - 1) / @as(usize, @intCast(grid_cols)));
    const avail = hi - panel_top - pad * 2 - input_h - qual_h - st - gap;
    var vis = @max(@as(i32, 1), @divTrunc(avail, card_h + gap));
    vis = @min(vis, @max(total_rows, 1));
    const rows_shown = if (total_rows == 0) 0 else vis;
    const hp = pad * 2 + input_h + qual_h + st + (if (rows_shown > 0) gap + rows_shown * (card_h + gap) - gap else 0);
    return .{
        .xp = xp,
        .yp = panel_top,
        .wp = wp,
        .hp = hp,
        .grid_x = xp + pad,
        .grid_y = panel_top + pad + input_h + qual_h + st + gap,
        .card_w = card_w,
        .thumb_h = thumb_h,
        .card_h = card_h,
        .total_rows = total_rows,
        .vis_rows = vis,
    };
}

/// Rettangolo del chip qualità `i` (riga sotto il campo query).
/// I segmenti sono contigui e allineati a destra della colonna.
fn chipRect(lay: Layout, i: usize) [4]i32 {
    const n: i32 = @intCast(quality_heights.len);
    const x0 = lay.xp + lay.wp - pad - n * chip_w - 3;
    const x = x0 + @as(i32, @intCast(i)) * chip_w;
    const y = lay.yp + pad + input_h + @divTrunc(qual_h - chip_h, 2);
    return .{ x, y, chip_w, chip_h };
}

/// Rettangolo del pulsante "Coda", a sinistra sotto il campo.
const queue_chip_w: i32 = 96;
fn queueChipRect(lay: Layout) [4]i32 {
    const rc = chipRect(lay, 0);
    return .{ lay.xp + pad, rc[1], queue_chip_w, rc[3] };
}

fn rectHit(rc: [4]i32, x: f32, y: f32) bool {
    return x >= @as(f32, @floatFromInt(rc[0])) and x < @as(f32, @floatFromInt(rc[0] + rc[2])) and
        y >= @as(f32, @floatFromInt(rc[1])) and y < @as(f32, @floatFromInt(rc[1] + rc[3]));
}

/// Geometria verticale della griglia, per lo scroll.
fn geom(lay: Layout) card_grid.Geom {
    return .{
        .grid_x = lay.grid_x,
        .grid_y = lay.grid_y,
        .right = lay.xp + lay.wp + @divTrunc(side, 2) + 3, // la scrollbar flottante sta nel margine laterale
        .card_h = lay.card_h,
        .gap = gap,
        .total_rows = lay.total_rows,
        .vis_rows = lay.vis_rows,
    };
}

/// Rettangolo intero della card `i` (indice assoluto) spostato dallo scroll in
/// pixel, o null se nemmeno un pixel cade nella banda visibile. Può sporgere dalla
/// banda: chi disegna taglia alla banda, chi fa hit-test usa `cardHit`.
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

/// Rotella col pannello aperto: scorre la griglia col passo di zicro
/// (`zicro.scroll.wheel_gain`), con l'easing applicato al disegno.
/// Ritorna true se l'evento è consumato (sempre, a overlay attivo).
pub fn handleWheel(state: *GuiAppState, win: *zrame.Window, axis: u32, value: f32) bool {
    state.shared.mutex.lockUncancelable(state.io);
    defer state.shared.mutex.unlock(state.io);
    const yt = &state.shared.yt;
    if (!yt.active) return false;
    if (axis != 0 or value == 0) return true;
    _ = win; // la geometria la allinea il prossimo disegno (`GridScroll.tick`)
    yt.scroll.sc.wheel(.vertical, value);
    state.shared.file_changed = true;
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
    const lay = layoutFor(dims[0], dims[1], shown(yt).len, hasStatus(yt));

    switch (event.kind) {
        .motion => {
            state.last_x = event.x;
            state.last_y = event.y;
            const m = yt.scroll.onMotion(geom(lay), event.x, event.y);
            if (m.redraw) state.shared.file_changed = true;
            if (m.consumed) return true; // sulla scrollbar o in drag
            for (shown(yt), 0..) |_, i| {
                if (cardHit(lay, yt.scroll.pos(), i, event.x, event.y)) {
                    if (yt.sel != @as(i32, @intCast(i))) {
                        yt.sel = @intCast(i);
                        state.shared.file_changed = true;
                    }
                    break;
                }
            }
            return true;
        },
        .press, .release => {
            // Tasto destro su una card: in coda / fuori dalla coda.
            if (event.button == 0x111) {
                if (event.kind == .press) {
                    for (shown(yt), 0..) |_, i| {
                        if (cardHit(lay, yt.scroll.pos(), i, state.last_x, state.last_y)) {
                            toggleQueueAt(state, @intCast(i));
                            break;
                        }
                    }
                }
                return true;
            }
            if (event.button != 0x110) return true;
            if (event.kind != .press) {
                if (yt.scroll.onRelease()) state.shared.file_changed = true; // fine del drag
                return true;
            }
            const mx = state.last_x;
            const my = state.last_y;
            // Pressione sulla scrollbar: prende il thumb (o lo porta lì) e inizia il drag.
            if (yt.scroll.onPress(geom(lay), mx, my)) {
                state.shared.file_changed = true;
                return true;
            }
            // Click su un chip qualità: seleziona (e con uno stream attivo riapre
            // il video alla stessa posizione con la nuova qualità).
            for (0..quality_heights.len) |qi| {
                if (rectHit(chipRect(lay, qi), mx, my)) {
                    setQuality(state, @intCast(qi));
                    return true;
                }
            }
            if (rectHit(queueChipRect(lay), mx, my)) {
                toggleQueueView(state);
                return true;
            }
            for (shown(yt), 0..) |_, i| {
                if (cardHit(lay, yt.scroll.pos(), i, mx, my)) {
                    yt.sel = @intCast(i);
                    openSelected(state);
                    return true;
                }
            }
            // Click sul messaggio "yt-dlp non trovato": apre la pagina di download.
            if (missingShown(yt) and statusHit(lay, mx, my)) {
                openUrl(state, ytdlp.download_url);
                return true;
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
        .leave => {
            yt.scroll.sc.onLeave(); // la scrollbar torna a riposo
            state.shared.file_changed = true;
            return false;
        },
        .scroll => return false, // la rotella passa da `handleWheel`
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
const text_link = [3]u8{ 120, 160, 255 };

/// Codepoint nel testo (= colonne: i glifi dell'overlay sono a cella fissa).
fn colCount(t: []const u8) usize {
    var n: usize = 0;
    for (t) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Offset in byte della colonna `col` (o la fine del testo).
fn byteAtCol(t: []const u8, col: usize) usize {
    var n: usize = 0;
    for (t, 0..) |c, i| {
        if (c & 0xC0 != 0x80) {
            if (n == col) return i;
            n += 1;
        }
    }
    return t.len;
}

/// Il caret del campo query (barra verticale alta quanto il campo, meno i margini).
fn drawCaret(canvas: *paint.Canvas, x: i32, field_y: i32, rgb: [3]u8) void {
    canvas.fillRoundedRect(@floatFromInt(x), @floatFromInt(field_y + 12), 2.0, @floatFromInt(input_h - 24), 1.0, paint.Color.rgba(rgb[0], rgb[1], rgb[2], 0.9));
}

/// Testo monospazio troncato a `max_w` px; ritorna la larghezza usata.
/// Pubblica: riusata dall'esploratore file (stesso stile di overlay).
pub fn drawText(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, x: i32, baseline: i32, text: []const u8, rgb: [3]u8, max_w: i32) i32 {
    return drawTextClip(buf, W, H, raster, x, baseline, text, rgb, max_w, 0, @intCast(H));
}

/// Come `drawText`, ma disegna solo le righe di pixel in `[clip_y0, clip_y1)`.
pub fn drawTextClip(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, x: i32, baseline: i32, text: []const u8, rgb: [3]u8, max_w: i32, clip_y0: i32, clip_y1: i32) i32 {
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const y_lo = @max(clip_y0, 0);
    const y_hi = @min(clip_y1, hi);
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
                if (py < y_lo or py >= y_hi) continue;
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
    blitThumbClip(buf, W, H, dx, dy, dw, dh, src, sw, sh, 0, @intCast(H));
}

/// Come `blitThumb`, ma copia solo le righe in `[clip_y0, clip_y1)`.
pub fn blitThumbClip(buf: []u8, W: u32, H: u32, dx: i32, dy: i32, dw: i32, dh: i32, src: []const u8, sw: u32, sh: u32, clip_y0: i32, clip_y1: i32) void {
    if (dw <= 0 or dh <= 0 or sw == 0 or sh == 0) return;
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(@min(@as(i32, @intCast(H)), clip_y1));
    const dst_words: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buf[0 .. @as(usize, W) * H * 4]));
    const src_words: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, src[0 .. @as(usize, sw) * sh * 4]));
    var y: i32 = @max(dy, @max(clip_y0, 0));
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
pub fn drawOverlay(buf: []u8, W: u32, H: u32, state: *GuiAppState, fonts: ui.Fonts, spin_phase: f32) void {
    if (W < 160 or H < 160) return;
    const yt = &state.shared.yt;
    tickPrefetch(state);

    const status = hasStatus(yt);
    const lay = layoutFor(W, H, shown(yt).len, status);

    // Scroll a inseguimento della selezione SOLO quando è cambiata da tastiera:
    // rotella e drag della scrollbar sfogliano liberamente (l'hover non c'entra,
    // il mouse è già su una card visibile). La card selezionata entra intera.
    if (yt.follow_sel and yt.sel >= 0) yt.scroll.revealRow(geom(lay), @divTrunc(yt.sel, grid_cols));
    yt.follow_sel = false;
    if (yt.scroll.tick(geom(lay), zicro.widget.nowMs())) state.shared.file_changed = true; // easing o dissolvenza in corso: un altro frame

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    const body = fonts.body;
    const small = fonts.small;
    const body_lh = ui.Fonts.lineH(body);
    const small_lh = ui.Fonts.lineH(small);

    ui.fillBackdrop(&canvas, W, H);

    // ── Campo di ricerca: pillola con la lente, testo proporzionale ────────
    const fx0 = lay.xp + pad;
    const fy0 = lay.yp + pad;
    const fw = lay.wp - pad * 2;
    canvas.fillRoundedRect(@floatFromInt(fx0), @floatFromInt(fy0), @floatFromInt(fw), @floatFromInt(input_h), @as(f32, @floatFromInt(input_h)) / 2.0, if (yt.sel < 0) ui.surface_hi else ui.surface);
    ui.searchIcon(&canvas, @floatFromInt(fx0 + 24), @floatFromInt(fy0 + @divTrunc(input_h, 2)), 18.0, paint.Color.rgba(ui.dim[0], ui.dim[1], ui.dim[2], 1.0));
    const in_x = fx0 + 46;
    const in_max = fw - 46 - input_h; // a destra lo spinner
    const in_base = fy0 + @divTrunc(input_h - body_lh, 2) + body.ascent;
    if (yt.query.len == 0) {
        _ = ui.text(buf, W, H, body, in_x, in_base, "Cerca su YouTube", ui.faint, .{ .max_w = in_max });
        if (yt.sel < 0) drawCaret(&canvas, in_x - 3, fy0, ui.fg);
    } else {
        // La vista scorre quanto basta a tenere il caret dentro il campo.
        const q = &yt.query;
        const caret_px = ui.measure(body, .regular, q.text()[0..q.cursor]);
        const shift = @max(0, caret_px - (in_max - 6));
        const tx = in_x - shift;
        if (q.selection()) |r| {
            const x0 = @max(in_x, tx + ui.measure(body, .regular, q.text()[0..r.start]));
            const x1 = @min(in_x + in_max, tx + ui.measure(body, .regular, q.text()[0..r.end]));
            if (x1 > x0) canvas.fillRoundedRect(@floatFromInt(x0 - 1), @floatFromInt(fy0 + 10), @floatFromInt(x1 - x0 + 2), @floatFromInt(input_h - 20), 3.0, paint.Color.rgba(122, 162, 255, 0.40));
        }
        _ = ui.text(buf, W, H, body, tx, in_base, q.text(), ui.fg, .{ .x_lo = in_x, .x_hi = in_x + in_max });
        // Caret solo col fuoco sul campo (nessuna card selezionata: le frecce
        // muovono lui, non la griglia).
        if (yt.sel < 0 and q.selection() == null) drawCaret(&canvas, tx + caret_px, fy0, ui.fg);
    }
    if (yt.searching or yt.opening) {
        const scx: f32 = @floatFromInt(fx0 + fw - @divTrunc(input_h, 2));
        const scy: f32 = @floatFromInt(fy0 + @divTrunc(input_h, 2));
        canvas.drawSpinner(scx, scy, @as(f32, @floatFromInt(input_h)) * 0.22, 2.2, spin_phase, paint.Color.rgba(205, 210, 230, 1.0));
    }

    // ── Riga sotto il campo: Coda a sinistra, qualità a destra ─────────────
    {
        const q0 = chipRect(lay, 0);
        const tb = q0[1] + @divTrunc(chip_h - small_lh, 2) + small.ascent;
        // Controllo segmentato: binario comune, il segmento attivo in rilievo.
        const n: i32 = @intCast(quality_labels.len);
        canvas.fillRoundedRect(@floatFromInt(q0[0] - 3), @floatFromInt(q0[1] - 3), @floatFromInt(n * chip_w + 6), @floatFromInt(chip_h + 6), 9.0, ui.surface);
        for (quality_labels, 0..) |lab, qi| {
            const rc = chipRect(lay, qi);
            const selq = yt.quality == @as(u8, @intCast(qi));
            if (selq) canvas.fillRoundedRect(@floatFromInt(rc[0]), @floatFromInt(rc[1]), @floatFromInt(rc[2]), @floatFromInt(rc[3]), 7.0, ui.surface_hi);
            ui.textCentered(buf, W, H, small, rc[0] + @divTrunc(rc[2], 2), tb, lab, if (selq) ui.fg else ui.dim, .{ .max_w = rc[2] - 4 });
        }
        const rc = queueChipRect(lay);
        canvas.fillRoundedRect(@floatFromInt(rc[0] - 3), @floatFromInt(rc[1] - 3), @floatFromInt(rc[2] + 6), @floatFromInt(rc[3] + 6), 9.0, if (yt.show_queue) ui.surface_hi else ui.surface);
        const lab_rgb = if (yt.show_queue) ui.fg else ui.dim;
        const lw = ui.text(buf, W, H, small, rc[0] + 12, tb, "Coda", lab_rgb, .{});
        if (yt.queue.items.len > 0) {
            var nb: [12]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{yt.queue.items.len}) catch "";
            const nw = ui.measure(small, .regular, ns);
            const bw = @max(nw + 12, chip_h - 8);
            const bx = rc[0] + 12 + lw + 8;
            canvas.fillRoundedRect(@floatFromInt(bx), @floatFromInt(rc[1] + 4), @floatFromInt(bw), @floatFromInt(chip_h - 8), @as(f32, @floatFromInt(chip_h - 8)) / 2.0, ui.accent);
            ui.textCentered(buf, W, H, small, bx + @divTrunc(bw, 2), tb, ns, ui.on_accent, .{});
        }
    }

    // ── Riga di stato (errore, apertura in corso, coda vuota) ─────────────
    if (status) {
        const sy = lay.yp + pad + input_h + qual_h;
        const sbase = sy + @divTrunc(status_h - small_lh, 2) + small.ascent;
        const sx = lay.xp + pad + 4;
        const smax = lay.wp - pad * 2 - 8;
        if (yt.opening) {
            _ = ui.text(buf, W, H, small, sx, sbase, "Apertura dello stream…", ui.dim, .{ .max_w = smax });
        } else if (yt.err == null) {
            _ = ui.text(buf, W, H, small, sx, sbase, "La coda è vuota: tasto destro (o Ctrl+Invio) su un video per aggiungerlo", ui.dim, .{ .max_w = smax });
        } else if (yt.err) |e| {
            const used = ui.text(buf, W, H, small, sx, sbase, e, ui.err, .{ .max_w = smax });
            // Il link per esteso dopo il messaggio, se c'è posto: si legge anche
            // senza cliccare (e si copia a mano).
            if (missingShown(yt)) {
                const lx = sx + used + 12;
                const room = sx + smax - lx;
                if (room >= ui.measure(small, .regular, ytdlp.download_url)) _ = ui.text(buf, W, H, small, lx, sbase, ytdlp.download_url, ui.link, .{});
            }
        }
    }

    // ── Stato vuoto: nessun risultato da mostrare ──────────────────────────
    if (shown(yt).len == 0 and !status and !yt.searching) {
        const top = lay.yp + pad + input_h + qual_h;
        const cy = top + @divTrunc(@as(i32, @intCast(H)) - top, 3);
        const cx = lay.xp + @divTrunc(lay.wp, 2);
        ui.textCentered(buf, W, H, body, cx, cy, if (yt.query.len == 0) "Cerca un video e premi Invio" else "Premi Invio per cercare", ui.dim, .{ .max_w = lay.wp });
        const hints = [_][]const u8{
            "Tasto destro su un video: aggiungi alla coda",
            "Ctrl+O: apri la pagina su YouTube",
            "Esc: chiudi",
        };
        for (hints, 0..) |h, k| {
            ui.textCentered(buf, W, H, small, cx, cy + 14 + body_lh + @as(i32, @intCast(k)) * (small_lh + 6), h, ui.faint, .{ .max_w = lay.wp });
        }
    }

    // ── Griglia: miniatura arrotondata, durata, titolo su due righe, canale ─
    // Tutto tagliato alla banda (più i 5 px dell'anello di selezione): le card a
    // metà dello scroll escono dal bordo alto e basso.
    const clip_y0 = lay.grid_y - 5;
    const clip_y1 = lay.grid_y + geom(lay).bandH() + 5;
    const clip: ui.ClipY = .{ .y0 = clip_y0, .y1 = clip_y1 };
    const saved_clip = canvas.setClip(0, @intCast(@max(clip_y0, 0)), W, @intCast(@max(clip_y1 - @max(clip_y0, 0), 0)));
    defer canvas.clip = saved_clip;
    const rad: f32 = 10.0;
    const title_step = body.lineHeight();
    for (shown(yt), 0..) |r, i| {
        const rc = cardRect(lay, yt.scroll.pos(), i) orelse continue;
        const x = rc[0];
        const y = rc[1];
        const selected = @as(i32, @intCast(i)) == yt.sel;

        if (r.thumb_w != 0) {
            ui.thumb(&canvas, buf, W, H, x, y, lay.card_w, lay.thumb_h, r.thumb_rgba, r.thumb_w, r.thumb_h, rad, .cover, ui.surface, clip);
        } else {
            // Miniatura non ancora arrivata: segnaposto.
            canvas.fillRoundedRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(lay.card_w), @floatFromInt(lay.thumb_h), rad, ui.surface);
        }
        if (selected) ui.selectionRing(&canvas, x, y, lay.card_w, lay.thumb_h, rad);

        if (r.duration.len > 0) ui.badgeBR(&canvas, buf, W, H, small, x + lay.card_w - 8, y + lay.thumb_h - 8, r.duration, clip);

        // "In coda" in alto a sinistra (nella vista coda solo il numero).
        const qn = queuePos(yt, r.id);
        if (qn > 0) {
            var qb: [24]u8 = undefined;
            const qlab = (if (yt.show_queue) std.fmt.bufPrint(&qb, "#{d}", .{qn}) else std.fmt.bufPrint(&qb, "In coda · {d}", .{qn})) catch "In coda";
            const bw = ui.measure(small, .regular, qlab) + 14;
            const bh = small_lh + 6;
            canvas.fillRoundedRect(@floatFromInt(x + 8), @floatFromInt(y + 8), @floatFromInt(bw), @floatFromInt(bh), @as(f32, @floatFromInt(bh)) / 2.0, ui.accent);
            _ = ui.text(buf, W, H, small, x + 15, y + 11 + small.ascent, qlab, ui.on_accent, .{ .clip = clip });
        }

        const tbase = y + lay.thumb_h + 10 + body.ascent;
        const lines = ui.text2(buf, W, H, body, x + 2, tbase, title_step, r.title, ui.fg, .{ .max_w = lay.card_w - 4, .clip = clip });
        if (r.channel.len > 0) {
            const cbase = tbase + @as(i32, lines) * title_step - body.ascent + 3 + small.ascent;
            _ = ui.text(buf, W, H, small, x + 2, cbase, r.channel, ui.dim, .{ .max_w = lay.card_w - 4, .clip = clip });
        }
    }

    // Scrollbar flottante di zicro, come quella del testo.
    canvas.clip = saved_clip;
    yt.scroll.sc.draw(&canvas);
}

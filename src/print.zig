//! Stampa (Ctrl+P, ⌘P su macOS) di PDF, immagini, testi e markdown.
//!
//! Ctrl+P apre un pannello di conferma con una copia di ciò che si sta
//! guardando; Invio avvia la stampa su un thread, Esc annulla. Cosa va in stampa:
//! - un PDF: il file originale, così com'è;
//! - un'immagine (o una pagina di PDF dentro un archivio): i pixel decodificati,
//!   con la rotazione della vista, centrati su un A4 nel verso che le si addice;
//! - testo e codice: le stesse righe del viewer (a capo, numeri di riga,
//!   evidenziazione) impaginate su A4, scure su bianco (`text_render.PrintDoc`);
//! - markdown: la stessa impaginazione dello schermo (`md_layout`: titoli,
//!   liste, tabelle, codice…) con i colori per la carta.
//! Il PDF generato va alla stampante predefinita con `lp` (CUPS, Linux e macOS)
//! o col verbo "print" della shell su Windows.

const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const paint = zicro.paint;
const glyph = @import("glyph.zig");
const yt_search = @import("yt_search.zig");
const decoder_mod = @import("decoder.zig");
const print_pdf = @import("print_pdf.zig");
const vtcache = @import("vtcache.zig");
const gui_state_mod = @import("gui_state.zig");
const GuiAppState = gui_state_mod.GuiAppState;

const is_win = builtin.os.tag == .windows;

pub const Phase = enum { none, confirm, working, done, failed };

/// Testo in un buffer fisso: il pannello vive nello stato condiviso.
const Line = struct {
    b: [200]u8 = undefined,
    len: usize = 0,

    fn set(self: *Line, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.b, fmt, args) catch blk: {
            // Troncato: si taglia su un confine di carattere.
            var n = self.b.len;
            while (n > 0 and (self.b[n - 1] & 0xC0) == 0x80) n -= 1;
            if (n > 0) n -= 1;
            break :blk self.b[0..n];
        };
        self.len = s.len;
    }

    fn text(self: *const Line) []const u8 {
        return self.b[0..self.len];
    }
};

/// Cosa si stampa: una copia presa a Ctrl+P, posseduta dal job.
const Job = struct {
    /// Nome mostrato e titolo del lavoro di stampa.
    name: []u8,
    /// PDF originale da mandare così com'è; altrimenti `content`.
    pdf_path: ?[]u8 = null,
    content: decoder_mod.Decoded = .{ .err = &.{} },
    /// Quarti di giro orari della vista (solo immagini).
    rotation: u2 = 0,

    fn deinit(self: *Job, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.pdf_path) |p| gpa.free(p);
        self.content.deinit(gpa);
    }
};

/// Stato del pannello, in `Shared` (ogni accesso sotto `shared.mutex`).
pub const Ui = struct {
    phase: Phase = .none,
    title: Line = .{},
    detail: Line = .{},
    /// Secondi da quando è comparso l'esito (chiusura automatica).
    age_s: f32 = 0,
    job: ?Job = null,
    /// Un thread sta stampando (anche a pannello nascosto): una stampa alla volta.
    busy: bool = false,
    /// Il puntatore è sopra il pulsante della stampa.
    hover: bool = false,
};

/// Rettangolo del pulsante della stampa nel frame presentato (x, y, lato in
/// pixel, impacchettati a 16 bit; 0 = nascosto). Lo scrive il render worker a
/// ogni disegno dell'etichetta, lo legge il thread finestra per l'hit-test.
pub var button: std.atomic.Value(u64) = .init(0);

pub fn packButton(x: f32, y: f32, s: f32) u64 {
    const c = struct {
        fn f(v: f32) u64 {
            return @intFromFloat(std.math.clamp(v, 0, 65535));
        }
    }.f;
    return c(x) | (c(y) << 16) | (c(s) << 32) | (1 << 48);
}

/// Il punto (`x`, `y`) del frame è sul pulsante della stampa visibile.
pub fn buttonHit(x: f32, y: f32) bool {
    const v = button.load(.monotonic);
    if (v == 0) return false;
    const bx: f32 = @floatFromInt(v & 0xFFFF);
    const by: f32 = @floatFromInt((v >> 16) & 0xFFFF);
    const s: f32 = @floatFromInt((v >> 32) & 0xFFFF);
    return x >= bx and x < bx + s and y >= by and y < by + s;
}

/// Il contenuto corrente si può stampare (PDF, immagine, testo, markdown). Sotto
/// `shared.mutex`.
pub fn printable(app_state: *GuiAppState) bool {
    const sh = &app_state.shared;
    if (app_state.video.isActive() or sh.is_mesh or sh.is_table or sh.loading or sh.decoded_is_message or app_state.midi != null) return false;
    if (gui_state_mod.isPdfPath(sh.current_file_path) and !gui_state_mod.isInsideArchive(sh.current_file_path)) return true;
    return switch (sh.decoded) {
        .image, .text, .markdown => true,
        else => false,
    };
}

/// Pulsante della stampa: un cerchio scuro come l'etichetta del nome, con una
/// stampante disegnata a tratti (foglio in entrata, corpo, foglio in uscita).
/// Registra il proprio rettangolo per l'hit-test (`button`).
pub fn drawButton(canvas: *paint.Canvas, x: f32, y: f32, s: f32, alpha: f32, hover: bool) void {
    button.store(packButton(x, y, s), .monotonic);
    const bg_a: f32 = if (hover) 0.88 else 0.62;
    canvas.fillRoundedRect(x, y, s, s, s / 2, if (hover) paint.Color.rgba(48, 56, 82, bg_a * alpha) else paint.Color.rgba(16, 18, 26, bg_a * alpha));
    const fg = paint.Color.rgba(235, 238, 245, (if (hover) @as(f32, 1.0) else 0.9) * alpha);
    const cut = if (hover) paint.Color.rgba(48, 56, 82, alpha) else paint.Color.rgba(16, 18, 26, alpha);
    // Icona nel quadrato centrale (60% del cerchio).
    const i = s * 0.6;
    const ox = x + (s - i) / 2;
    const oy = y + (s - i) / 2;
    const u = i / 16; // griglia 16×16
    canvas.fillRoundedRect(ox + 4 * u, oy + 1 * u, 8 * u, 4 * u, 0.6 * u, fg); // foglio in entrata
    canvas.fillRoundedRect(ox + 1 * u, oy + 5 * u, 14 * u, 7 * u, 1.6 * u, fg); // corpo
    canvas.fillRoundedRect(ox + 3.5 * u, oy + 9 * u, 9 * u, 6.5 * u, 0.6 * u, cut); // fessura
    canvas.strokeRoundedRect(ox + 4 * u, oy + 9.5 * u, 8 * u, 5.5 * u, 0.6 * u, 1.3 * u, fg); // foglio in uscita
    canvas.fillRoundedRect(ox + 11.2 * u, oy + 6.6 * u, 1.6 * u, 1.6 * u, 0.8 * u, cut); // spia
}

/// Movimento del puntatore: aggiorna l'evidenziazione del pulsante. Sotto lock.
pub fn onMotion(sh: *GuiAppState.Shared, x: f32, y: f32) void {
    const h = buttonHit(x, y);
    if (h != sh.print.hover) {
        sh.print.hover = h;
        sh.file_changed = true;
    }
}

/// Ctrl+P: prepara il job dal contenuto corrente e apre la conferma. Da
/// chiamare SENZA `shared.mutex` (lo prende).
pub fn request(app_state: *GuiAppState) void {
    const gpa = app_state.gpa;
    const busy_video = app_state.video.isActive();
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    const sh = &app_state.shared;
    // Una stampa alla volta: se il pannello era stato nascosto, torna a mostrarla.
    if (sh.print.busy) {
        sh.print.phase = .working;
        sh.file_changed = true;
        return;
    }
    discardJob(app_state);
    sh.help = false;
    sh.info = false;
    sh.file_changed = true;
    sh.ui_idle_s = 0;

    const path = sh.current_file_path;
    const clean = if (std.mem.indexOfScalar(u8, path, '#')) |h| path[0..h] else path;
    const name = std.fs.path.basename(clean);
    _ = busy_video;
    const printable_kind = printable(app_state);

    // In UTF-8 valido: va nel pannello, nel titolo del lavoro e nel piè di pagina.
    var job: Job = .{ .name = print_pdf.validUtf8(gpa, if (gui_state_mod.isInsideArchive(path)) std.fs.path.basename(path) else name) catch return };
    var what: []const u8 = "";
    var pages: u32 = 0;
    const ok = printable_kind and blk: {
        if (gui_state_mod.isPdfPath(path) and !gui_state_mod.isInsideArchive(path) and !std.mem.startsWith(u8, path, "http")) {
            job.pdf_path = gpa.dupe(u8, clean) catch break :blk false;
            if (sh.decoded == .image) pages = sh.decoded.image.total_pages;
            what = "PDF";
            break :blk true;
        }
        switch (sh.decoded) {
            .image => |img| {
                if (img.width == 0 or img.height == 0) break :blk false;
                const px = gpa.dupe(u8, img.pixels[0 .. img.width * img.height * 3]) catch break :blk false;
                const nm = gpa.dupe(u8, img.name) catch {
                    gpa.free(px);
                    break :blk false;
                };
                job.content = .{ .image = .{ .width = img.width, .height = img.height, .pixels = px, .name = nm } };
                job.rotation = sh.rotation;
                what = "immagine";
                break :blk true;
            },
            .text => |t| {
                job.content = .{ .text = gpa.dupe(u8, t) catch break :blk false };
                what = "testo";
                break :blk true;
            },
            .markdown => |m| {
                job.content = .{ .markdown = .{ .content = gpa.dupe(u8, m.content) catch break :blk false } };
                what = "markdown, come è mostrato";
                break :blk true;
            },
            else => break :blk false,
        }
    };
    if (!ok) {
        job.deinit(gpa);
        showResult(sh, .failed, "Stampa non disponibile", "si stampano PDF, immagini, testi e markdown", .{});
        return;
    }
    sh.print.job = job;
    sh.print.phase = .confirm;
    sh.print.title.set("Stampa «{s}»", .{job.name});
    if (pages > 1)
        sh.print.detail.set("{s}, {d} pagine", .{ what, pages })
    else
        sh.print.detail.set("{s}", .{what});
}

/// Tasti col pannello aperto. true = tasto consumato. Da chiamare SENZA lock.
pub fn handleKey(app_state: *GuiAppState, key: u32) bool {
    const KEY_ESC: u32 = 1;
    const KEY_ENTER: u32 = 28;
    const KEY_KPENTER: u32 = 96;
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    const ui = &app_state.shared.print;
    switch (ui.phase) {
        .none => return false,
        .confirm => {
            if (key == KEY_ESC) {
                discardJob(app_state);
                ui.phase = .none;
            } else if (key == KEY_ENTER or key == KEY_KPENTER) {
                const job = ui.job.?;
                ui.job = null;
                ui.phase = .working;
                ui.busy = true;
                ui.detail.set("preparazione…", .{});
                const t = std.Thread.spawn(.{}, run, .{ app_state, job }) catch {
                    var j = job;
                    j.deinit(app_state.gpa);
                    ui.busy = false;
                    showResult(&app_state.shared, .failed, "Stampa non riuscita", "impossibile avviare il lavoro", .{});
                    return true;
                };
                t.detach();
            }
            app_state.shared.file_changed = true;
            return true; // col pannello di conferma aperto la tastiera è sua
        },
        // In corso: Esc nasconde il pannello, la stampa prosegue.
        .working => {
            if (key != KEY_ESC) return false;
            ui.phase = .none;
            app_state.shared.file_changed = true;
            return true;
        },
        .done, .failed => {
            ui.phase = .none;
            app_state.shared.file_changed = true;
            return key == KEY_ESC;
        },
    }
}

/// Avanza la chiusura automatica dell'esito. Dal render worker, sotto lock.
pub fn tick(sh: *GuiAppState.Shared, dt: f32) void {
    const ui = &sh.print;
    if (ui.phase != .done and ui.phase != .failed) return;
    ui.age_s += dt;
    if (ui.age_s > 5) {
        ui.phase = .none;
        sh.file_changed = true;
    }
}

fn discardJob(app_state: *GuiAppState) void {
    if (app_state.shared.print.job) |*j| j.deinit(app_state.gpa);
    app_state.shared.print.job = null;
}

fn showResult(sh: *GuiAppState.Shared, phase: Phase, title: []const u8, comptime fmt: []const u8, args: anytype) void {
    sh.print.phase = phase;
    sh.print.title.set("{s}", .{title});
    sh.print.detail.set(fmt, args);
    sh.print.age_s = 0;
    sh.file_changed = true;
}

/// Thread della stampa: genera il PDF (se serve), lo manda alla stampante e
/// pubblica l'esito nel pannello.
fn run(app_state: *GuiAppState, job_in: Job) void {
    var job = job_in;
    const gpa = app_state.gpa;
    defer job.deinit(gpa);
    var msg: Line = .{};
    const ok = submit(gpa, app_state.io, &job, &msg);
    app_state.shared.mutex.lockUncancelable(app_state.io);
    defer app_state.shared.mutex.unlock(app_state.io);
    app_state.shared.print.busy = false;
    if (ok)
        showResult(&app_state.shared, .done, "Stampa inviata", "{s}", .{msg.text()})
    else
        showResult(&app_state.shared, .failed, "Stampa non riuscita", "{s}", .{msg.text()});
}

fn submit(gpa: std.mem.Allocator, io: std.Io, job: *Job, msg: *Line) bool {
    if (job.pdf_path) |p| return send(gpa, p, job.name, false, msg);

    const bytes = print_pdf.build(gpa, &job.content, job.name, job.rotation) catch |e| {
        msg.set("impaginazione fallita ({s})", .{@errorName(e)});
        return false;
    };
    defer gpa.free(bytes);
    const dir = vtcache.appCacheDir(gpa, "print") orelse {
        msg.set("cartella della cache non disponibile", .{});
        return false;
    };
    defer gpa.free(dir);
    sweepOld(io, dir);
    const path = std.fmt.allocPrint(gpa, "{s}{c}stampa-{d}.pdf", .{ dir, std.fs.path.sep, std.Thread.getCurrentId() }) catch return false;
    defer gpa.free(path);
    writeFile(io, path, bytes) catch |e| {
        msg.set("scrittura del PDF fallita ({s})", .{@errorName(e)});
        return false;
    };
    // CUPS copia il file nella sua coda: dopo `lp` il PDF temporaneo non serve.
    // La shell di Windows lo stampa in modo asincrono: lì resta fino alla
    // stampa successiva (`sweepOld`).
    defer if (!is_win) std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return send(gpa, path, job.name, true, msg);
}

/// Cancella i PDF temporanei delle stampe precedenti (su Windows restano
/// finché l'applicazione associata li legge; altrove dopo un'interruzione).
/// Un file ancora aperto da chi stampa non si cancella: si riprova la volta dopo.
fn sweepOld(io: std.Io, dir_path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "stampa-") or !std.mem.endsWith(u8, entry.name, ".pdf")) continue;
        dir.deleteFile(io, entry.name) catch {};
    }
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.end();
}

const shell = struct {
    extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, verb: ?[*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: i32) callconv(.winapi) ?*anyopaque;
};

/// Manda `path` (un PDF) alla stampante predefinita. `fit`: il PDF è nostro, in
/// A4; CUPS lo adatta al foglio se la stampante ne usa un altro.
fn send(gpa: std.mem.Allocator, path: []const u8, title: []const u8, fit: bool, msg: *Line) bool {
    if (comptime is_win) {
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch return false;
        defer gpa.free(path_w);
        // "print": l'applicazione associata ai PDF stampa sulla stampante
        // predefinita. Senza quel verbo si apre il PDF, da stampare da lì.
        const h = shell.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("print"), path_w, null, null, 0);
        if (@intFromPtr(h) > 32) {
            msg.set("alla stampante predefinita", .{});
            return true;
        }
        const o = shell.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), path_w, null, null, 1);
        if (@intFromPtr(o) > 32) {
            msg.set("aperto nel lettore PDF: stampalo da lì", .{});
            return true;
        }
        msg.set("nessuna applicazione sa stampare i PDF", .{});
        return false;
    }
    // `sh -c` solo per unire stderr a stdout (il messaggio d'errore di lp):
    // titolo e percorso arrivano come argomenti, mai dentro lo script.
    const script = if (fit)
        "exec lp -t \"$1\" -o fit-to-page -- \"$2\" 2>&1"
    else
        "exec lp -t \"$1\" -- \"$2\" 2>&1";
    var res = decoder_mod.runCaptureTimeout(gpa, &.{ "sh", "-c", script, "sh", title, path }, 60_000) catch |e| {
        msg.set("lp non avviato ({s})", .{@errorName(e)});
        return false;
    };
    defer res.deinit(gpa);
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    const first = out[0 .. std.mem.indexOfScalar(u8, out, '\n') orelse out.len];
    if (res.exit_code == 127) {
        msg.set("comando lp assente: serve CUPS", .{});
        return false;
    }
    if (res.exit_code != 0) {
        msg.set("{s}", .{if (first.len > 0) first else "lp ha restituito un errore"});
        return false;
    }
    // "request id is Stampante-42 (1 file(s))"
    const prefix = "request id is ";
    if (std.mem.indexOf(u8, first, prefix)) |i| {
        const rest = first[i + prefix.len ..];
        const id = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len];
        const printer = id[0 .. std.mem.lastIndexOfScalar(u8, id, '-') orelse id.len];
        msg.set("a {s} (lavoro {s})", .{ printer, id });
    } else {
        msg.set("alla stampante predefinita", .{});
    }
    return true;
}

const panel_bg = paint.Color.rgba(13, 15, 22, 0.97);
const title_fg = [3]u8{ 120, 160, 255 };
const text_fg = [3]u8{ 235, 238, 245 };
const muted_fg = [3]u8{ 150, 158, 175 };
const error_fg = [3]u8{ 255, 140, 120 };

/// Pannello in basso al centro. Sotto `shared.mutex`, dal render worker.
pub fn draw(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, ui: *const Ui) void {
    if (ui.phase == .none or W < 200 or H < 120) return;
    const adv = raster.advance;
    if (adv <= 0) return;
    const line_h = raster.ascent - raster.descent + 4;
    const pad: i32 = 18;

    var lines: [5]struct { t: []const u8, c: [3]u8 } = undefined;
    var n: usize = 0;
    lines[n] = .{ .t = ui.title.text(), .c = if (ui.phase == .failed) error_fg else title_fg };
    n += 1;
    lines[n] = .{ .t = ui.detail.text(), .c = muted_fg };
    n += 1;
    if (ui.phase == .confirm) {
        lines[n] = .{ .t = "", .c = text_fg };
        n += 1;
        lines[n] = .{ .t = "Invio  stampa sulla stampante predefinita", .c = text_fg };
        n += 1;
        lines[n] = .{ .t = "Esc    annulla", .c = text_fg };
        n += 1;
    }

    var cols: i32 = 0;
    for (lines[0..n]) |l| cols = @max(cols, @as(i32, @intCast(std.unicode.utf8CountCodepoints(l.t) catch l.t.len)));
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);
    const pw = @min(wi - 32, cols * adv + 2 * pad);
    const ph = @as(i32, @intCast(n)) * line_h + 2 * pad - 4;
    const px = @divTrunc(wi - pw, 2);
    const py = @max(16, hi - ph - 48);

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    canvas.fillRoundedRect(@floatFromInt(px), @floatFromInt(py), @floatFromInt(pw), @floatFromInt(ph), 14.0, panel_bg);
    var y = py + pad;
    for (lines[0..n]) |l| {
        _ = yt_search.drawText(buf, W, H, raster, px + pad, y + raster.ascent, l.t, l.c, pw - 2 * pad);
        y += line_h;
    }
}

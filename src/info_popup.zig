//! Scheda informazioni sul file (tasto `i`): nome, tipo, dimensioni del contenuto,
//! peso su disco, data di modifica, posizione nella cartella. Resta aperta finché
//! non si ripreme `i` (o Esc) e segue il file mentre si naviga con le frecce: il
//! render worker la ricostruisce a ogni nuovo contenuto (`load_seq`).

const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const paint = zicro.paint;
const glyph = @import("glyph.zig");
const yt_search = @import("yt_search.zig");
const decoder_mod = @import("decoder.zig");
const gui_state_mod = @import("gui_state.zig");
const GuiAppState = gui_state_mod.GuiAppState;
const has_video = @import("build_options").video;
const info_fmt = @import("info_format.zig");
const grouped = info_fmt.grouped;
const decimal = info_fmt.decimal;
const humanSize = info_fmt.humanSize;
const utf8Floor = info_fmt.utf8Floor;
const ellipsize = info_fmt.ellipsize;

const max_rows = 12;
const label_cols = 13; // colonna delle etichette, in caratteri
const value_cols = 40;

/// Testo di una riga, in un buffer fisso: la scheda vive nello stato condiviso.
const Buf = struct {
    b: [192]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Buf) []const u8 {
        return self.b[0..self.len];
    }

    fn set(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(&self.b, fmt, args) catch {
            // Troppo lungo: si tiene quello che ci sta, tagliato su un carattere intero.
            var w: std.Io.Writer = .fixed(&self.b);
            w.print(fmt, args) catch {};
            self.len = utf8Floor(self.b[0..w.end]);
            return;
        };
        self.len = out.len;
    }
};

const Row = struct { label: []const u8, value: Buf = .{} };

pub const Card = struct {
    /// `load_seq` del contenuto descritto (0 = da costruire).
    seq: u32 = 0,
    title: Buf = .{},
    rows: [max_rows]Row = undefined,
    n: usize = 0,

    fn add(self: *Card, label: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (self.n == max_rows) return;
        self.rows[self.n] = .{ .label = label };
        self.rows[self.n].value.set(fmt, args);
        self.n += 1;
    }
};

/// Ricostruisce `state.shared.info_card` per il contenuto corrente. Con
/// `state.shared.mutex` acquisito (legge `decoded`, il player, la lista dei file).
pub fn build(state: *GuiAppState) void {
    const card = &state.shared.info_card;
    card.* = .{ .seq = state.shared.load_seq };
    const path = state.shared.current_file_path;
    const hash = std.mem.indexOfScalar(u8, path, '#');
    const clean = if (hash) |h| path[0..h] else path;
    const url = std.mem.indexOf(u8, path, "://") != null;
    const in_archive = gui_state_mod.isInsideArchive(path);
    const ext = decoder_mod.getExtension(clean);
    var ext_up: [12]u8 = undefined;
    const EXT = std.ascii.upperString(ext_up[0..@min(ext.len, ext_up.len)], ext[0..@min(ext.len, ext_up.len)]);

    // Titolo: il nome del file (della voce, dentro un archivio).
    const name = if (in_archive) std.fs.path.basename(path[hash.? + 1 ..]) else if (url) path else std.fs.path.basename(clean);
    card.title.set("{s}", .{name});

    // Tipo e dettagli del contenuto.
    const vs = &state.video;
    if (comptime has_video) if (vs.isActive()) {
        const is_video = state.shared.av_has_video and !vs.audio_only;
        if (url) {
            card.add("Tipo", "{s} in streaming", .{if (is_video) "Video" else "Audio"});
        } else {
            card.add("Tipo", "{s} {s}", .{ if (is_video) "Video" else "Audio", EXT });
        }
        if (vs.decoder) |d| if (d.src_w > 0 and d.src_h > 0)
            card.add("Risoluzione", "{d} × {d}", .{ d.src_w, d.src_h });
        if (vs.dur_s > 0) addDuration(card, vs.dur_s);
        if (url) card.add("Indirizzo", "{s}", .{path});
        addFileRows(state, card, clean, in_archive, url);
        return;
    };
    if (state.midi) |mp| {
        card.add("Tipo", "Audio MIDI", .{});
        const dur = mp.durationSeconds();
        if (dur > 0) addDuration(card, dur);
        addFileRows(state, card, clean, in_archive, url);
        return;
    }
    // Al posto del contenuto c'è un messaggio d'errore (file illeggibile): niente
    // dettagli del contenuto, solo quelli del file.
    if (state.shared.decoded_is_message) {
        card.add("Tipo", "Non leggibile ({s})", .{if (EXT.len > 0) EXT else "?"});
        addFileRows(state, card, clean, in_archive, url);
        return;
    }
    switch (state.shared.decoded) {
        .image => |img| {
            if (gui_state_mod.isPdfPath(path)) {
                card.add("Tipo", "Documento PDF", .{});
                const page = if (hash) |h| parsePage(path[h + 1 ..]) else 1;
                if (img.total_pages > 0) {
                    card.add("Pagina", "{d} di {d}", .{ page, img.total_pages });
                }
            } else {
                card.add("Tipo", "Immagine {s}", .{EXT});
                const mp = @as(f64, @floatFromInt(img.width * img.height)) / 1e6;
                var mp_buf: [16]u8 = undefined;
                card.add("Risoluzione", "{d} × {d} px  ({s} MP)", .{ img.width, img.height, decimal(&mp_buf, mp) });
            }
        },
        .mesh => |m| {
            card.add("Tipo", "Modello 3D {s}", .{EXT});
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            card.add("Vertici", "{s}", .{grouped(&b1, m.num_vertices)});
            card.add("Facce", "{s}", .{grouped(&b2, m.num_faces)});
            const sx = m.bbox_max[0] - m.bbox_min[0];
            const sy = m.bbox_max[1] - m.bbox_min[1];
            const sz = m.bbox_max[2] - m.bbox_min[2];
            var x1: [16]u8 = undefined;
            var x2: [16]u8 = undefined;
            var x3: [16]u8 = undefined;
            card.add("Ingombro", "{s} × {s} × {s}", .{ decimal(&x1, sx), decimal(&x2, sy), decimal(&x3, sz) });
        },
        .csv => |c| {
            const archive = gui_state_mod.isArchiveListing(path);
            card.add("Tipo", "{s} {s}", .{ if (archive) "Archivio" else "Tabella", EXT });
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            if (archive) {
                card.add("Voci", "{s}", .{grouped(&b1, c.rows.len)});
            } else {
                card.add("Righe", "{s}", .{grouped(&b1, c.rows.len)});
                card.add("Colonne", "{s}", .{grouped(&b2, c.headers.len)});
            }
        },
        .workbook => |wb| {
            card.add("Tipo", "Foglio di calcolo {s}", .{EXT});
            const sh = wb.sheets[@min(wb.active, wb.sheets.len - 1)];
            card.add("Fogli", "{d}  (aperto: {s})", .{ wb.sheets.len, sh.name });
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            card.add("Righe", "{s}", .{grouped(&b1, sh.data.rows.len)});
            card.add("Colonne", "{s}", .{grouped(&b2, sh.data.headers.len)});
        },
        .markdown => |md| {
            if (isOffice(ext)) {
                card.add("Tipo", "Documento {s}", .{EXT});
            } else {
                card.add("Tipo", "Testo Markdown", .{});
                addLines(card, md.content);
            }
        },
        .text => |t| {
            if (isOffice(ext)) {
                card.add("Tipo", "Documento {s}", .{EXT});
            } else if (ext.len > 0) {
                card.add("Tipo", "Testo ({s})", .{EXT});
            } else {
                card.add("Tipo", "Testo", .{});
            }
            addLines(card, t);
        },
        .err => card.add("Tipo", "Non leggibile", .{}),
    }
    addFileRows(state, card, clean, in_archive, url);
}

/// Righe comuni: peso, data, cartella, posizione nella cartella.
fn addFileRows(state: *GuiAppState, card: *Card, clean: []const u8, in_archive: bool, url: bool) void {
    if (url) return;
    if (in_archive) {
        card.add("Archivio", "{s}", .{std.fs.path.basename(clean)});
    } else if (std.Io.Dir.cwd().statFile(state.io, clean, .{})) |st| {
        var b: [32]u8 = undefined;
        var g: [32]u8 = undefined;
        if (st.size >= 1000) {
            card.add("Dimensione", "{s}  ({s} byte)", .{ humanSize(&b, st.size), grouped(&g, st.size) });
        } else {
            card.add("Dimensione", "{d} byte", .{st.size});
        }
        const secs: i64 = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
        if (localTime(secs)) |tm| {
            card.add("Modificato", "{d:0>2}/{d:0>2}/{d}  {d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.mday)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)) });
        }
    } else |_| {}
    const dir = std.fs.path.dirname(clean) orelse ".";
    const home = homeDir();
    if (home.len > 1 and std.mem.startsWith(u8, dir, home) and (dir.len == home.len or dir[home.len] == '/')) {
        card.add("Cartella", "~{s}", .{dir[home.len..]});
    } else {
        card.add("Cartella", "{s}", .{dir});
    }
    if (state.current_file_index) |i| if (state.file_list.items.len > 1)
        card.add("Posizione", "{d} di {d} nella cartella", .{ i + 1, state.file_list.items.len });
}

fn homeDir() []const u8 {
    const v = std.c.getenv(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse return "";
    return std.mem.span(v);
}

fn addDuration(card: *Card, secs_f: f64) void {
    const s: u64 = @intFromFloat(@round(secs_f));
    if (s >= 3600) {
        card.add("Durata", "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, (s % 3600) / 60, s % 60 });
    } else {
        card.add("Durata", "{d}:{d:0>2}", .{ s / 60, s % 60 });
    }
}

fn addLines(card: *Card, text: []const u8) void {
    var n: usize = std.mem.count(u8, text, "\n");
    if (text.len > 0 and text[text.len - 1] != '\n') n += 1;
    var b: [32]u8 = undefined;
    card.add("Righe", "{s}", .{grouped(&b, n)});
}

fn isOffice(ext: []const u8) bool {
    inline for (.{ "docx", "doc", "odt", "pptx", "odp", "rtf", "epub" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// `N` o `page=N` (frammento del percorso dei PDF); 1 se assente o illeggibile.
fn parsePage(frag: []const u8) usize {
    const s = if (std.mem.startsWith(u8, frag, "page=")) frag["page=".len..] else frag;
    return std.fmt.parseInt(usize, s, 10) catch 1;
}

/// I primi campi di `struct tm`, uguali su glibc, macOS e MSVCRT; il resto
/// (tm_gmtoff, tm_zone…) cade nel margine.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    _rest: [64]u8 = undefined,
};
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
extern "c" fn _localtime64_s(out: *Tm, t: *const i64) c_int;

/// Ora locale di un istante Unix (secondi).
fn localTime(secs: i64) ?Tm {
    var tm: Tm = undefined;
    if (comptime builtin.os.tag == .windows) {
        if (_localtime64_s(&tm, &secs) != 0) return null;
    } else {
        if (localtime_r(&secs, &tm) == null) return null;
    }
    return tm;
}

const panel_bg = paint.Color.rgba(13, 15, 22, 0.97);
const title_fg = [3]u8{ 235, 238, 245 };
const label_fg = [3]u8{ 120, 160, 255 };
const value_fg = [3]u8{ 205, 210, 225 };
const hint_fg = [3]u8{ 110, 118, 135 };

/// Disegna la scheda al centro del frame `W`×`H`. Con `shared.mutex` acquisito.
pub fn draw(buf: []u8, W: u32, H: u32, raster: *glyph.Raster, card: *const Card) void {
    if (W < 200 or H < 120) return;
    const adv = raster.advance;
    if (adv <= 0) return;
    const line_h = raster.ascent - raster.descent + 4;
    const pad: i32 = 18;
    const wi: i32 = @intCast(W);
    const hi: i32 = @intCast(H);

    // Larghezza sul contenuto, entro i limiti delle colonne e della finestra.
    var cols: usize = std.unicode.utf8CountCodepoints(card.title.slice()) catch 0;
    for (card.rows[0..card.n]) |*r| {
        const v = std.unicode.utf8CountCodepoints(r.value.slice()) catch 0;
        cols = @max(cols, label_cols + @min(v, value_cols));
    }
    cols = @max(cols, 24);
    const max_cols: usize = @intCast(@max(@divTrunc(wi - 32 - 2 * pad, adv), 10));
    cols = @min(cols, @min(max_cols, label_cols + value_cols));
    const rows: i32 = @intCast(card.n + 3); // titolo, riga vuota, righe, suggerimento
    const pw: i32 = @as(i32, @intCast(cols)) * adv + 2 * pad;
    const ph = @min(hi - 32, rows * line_h + 2 * pad - 4);
    const px = @divTrunc(wi - pw, 2);
    const py = @divTrunc(hi - ph, 2);

    const u32px: [*]u32 = @ptrCast(@alignCast(buf.ptr));
    var canvas = paint.Canvas.initRgba8(u32px[0 .. @as(usize, W) * H], W, H);
    canvas.fillRoundedRect(@floatFromInt(px), @floatFromInt(py), @floatFromInt(pw), @floatFromInt(ph), 14.0, panel_bg);

    const x = px + pad;
    const inner_w = pw - 2 * pad;
    const y_end = py + ph - pad;
    var y = py + pad;
    var tb: [256]u8 = undefined;
    _ = yt_search.drawText(buf, W, H, raster, x, y + raster.ascent, ellipsize(&tb, card.title.slice(), cols), title_fg, inner_w);
    y += line_h + @divTrunc(line_h, 2);
    const vcols = cols -| label_cols;
    for (card.rows[0..card.n]) |*r| {
        if (y + line_h > y_end) break;
        _ = yt_search.drawText(buf, W, H, raster, x, y + raster.ascent, r.label, label_fg, (label_cols - 1) * adv);
        var vb: [256]u8 = undefined;
        _ = yt_search.drawText(buf, W, H, raster, x + label_cols * adv, y + raster.ascent, ellipsize(&vb, r.value.slice(), vcols), value_fg, inner_w - label_cols * adv);
        y += line_h;
    }
    if (y + line_h <= y_end + 4) {
        _ = yt_search.drawText(buf, W, H, raster, x, y + @divTrunc(line_h, 2) + raster.ascent, "i  Esc  chiudi", hint_fg, inner_w);
    }
}

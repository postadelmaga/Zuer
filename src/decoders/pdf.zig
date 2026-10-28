//! Plugin PDF: rasterizza la pagina richiesta con `pdftoppm` (poppler-utils).
//! Nessuna dipendenza a build-time: poppler è richiesto solo a runtime, con
//! errore chiaro se manca.
//!
//! Il costo dominante è il subprocess (~1,7 s per una pagina vettoriale A3
//! apribile a 200 DPI), e prima veniva pagato per intero a OGNI cambio pagina,
//! preceduto da un `pdfinfo` per il conteggio. Tre livelli lo tagliano:
//!   1. tier COARSE (`zuer_decode_coarse`): `-scale-to 1024`, ~6× più veloce e
//!      senza `pdfinfo`, mostrato come anteprima mentre il full arriva;
//!   2. conteggio pagine MEMOIZZATO per (realpath, mtime, size) — i cambi
//!      pagina non rilanciano `pdfinfo`, e alla prima apertura `pdftoppm` parte
//!      PRIMA (il conteggio serve solo alla navigazione);
//!   3. cache su disco delle pagine già renderizzate in `~/.cache/zuer/pdf`
//!      (chiave: file + dpi/scala + pagina) → riapertura senza subprocess.
//! I pixel, infine, si leggono direttamente nel buffer finale (header PPM in
//! una letturina a parte), senza la copia da ~34 MB che faceva il vecchio
//! `parsePpm` in place.

const std = @import("std");
const builtin = @import("builtin");
const decoder = @import("decoder");
const evict = @import("cache_evict.zig");
const ImageData = decoder.ImageData;
const Decoded = decoder.Decoded;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern fn rmdir(path: [*:0]const u8) c_int;
extern fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
extern fn unlink(filename: [*:0]const u8) c_int;

// I/O su file via libc (come le altre syscall del plugin): dentro un plugin
// dinamico l'`io` dell'host si blocca, quindi niente std.Io qui.
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_CREAT: c_int = 0o100;
const O_TRUNC: c_int = 0o1000;

// Iterazione directory via libc: serve per ripulire i file pagina residui
// prima di rmdir.
const DIR = opaque {};
const dirent = extern struct {
    d_ino: u64,
    d_off: u64,
    d_reclen: c_ushort,
    d_type: u8,
    d_name: [256]u8,
};
extern fn opendir(name: [*:0]const u8) ?*DIR;
extern fn readdir(dirp: *DIR) ?*dirent;
extern fn closedir(dirp: *DIR) c_int;

/// Lato coarse: `-scale-to N` rasterizza la pagina dentro un box N×N. 1024 è
/// abbastanza per un'anteprima a schermo (e sovrabbondante per una card
/// dell'explorer), ma costa una frazione del rendering a 200 DPI.
const coarse_scale = "1024";

/// Tetto sui pixel di UNA pagina (era implicito nel limite di `readFileLibc`):
/// un PDF ostile con un MediaBox assurdo non deve poter chiedere allocazioni
/// senza fondo, né via pdftoppm né via un file di cache manomesso.
const max_page_bytes: usize = 256 * 1024 * 1024;

pub fn decode(path: []const u8, io: std.Io, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    return decodeTier(path, io, filename, allocator, false);
}

/// Tier coarse: anteprima progressiva (e miniature dell'explorer). Rende la
/// pagina richiesta a bassa risoluzione e SENZA `pdfinfo`: `total_pages = 0`
/// (sconosciuto), perché il conteggio serve solo alla navigazione, che arriva
/// col tier full subito dopo.
pub fn decodeCoarse(path: []const u8, io: std.Io, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    return decodeTier(path, io, filename, allocator, true);
}

fn decodeTier(path: []const u8, io: std.Io, filename: []const u8, allocator: std.mem.Allocator, coarse: bool) Decoded {
    _ = io; // subprocess e letture file usano libc diretto (decoder.*), non l'io host
    // DPI alto anche nel terminale: con kitty l'immagine viaggia a piena
    // risoluzione e il terminale la scala, quindi più pixel = testo nitido
    // (a 70 DPI risultava sfocato su schermi grandi). La GUI, che consente lo
    // zoom, va ancora più su. Sovrascrivibile con ZUER_PDF_DPI.
    var dpi: []const u8 = "150";
    if (getenv("ZUER_GUI")) |val| {
        if (std.mem.eql(u8, std.mem.span(val), "1")) {
            dpi = "200";
        }
    }
    if (getenv("ZUER_PDF_DPI")) |val| {
        const s = std.mem.span(val);
        // Solo cifre, per non passare argomenti arbitrari a pdftoppm.
        if (s.len > 0 and s.len <= 4 and std.mem.indexOfNone(u8, s, "0123456789") == null) {
            dpi = s;
        }
    }

    var clean_path = path;
    var page_num: usize = 1;
    if (std.mem.indexOfScalar(u8, path, '#')) |hash_idx| {
        clean_path = path[0..hash_idx];
        const suffix = path[hash_idx + 1 ..];
        var page_str = suffix;
        if (std.mem.startsWith(u8, suffix, "page=")) {
            page_str = suffix["page=".len..];
        }
        page_num = std.fmt.parseInt(usize, page_str, 10) catch 1;
    }

    var clean_filename = filename;
    if (std.mem.indexOfScalar(u8, filename, '#')) |hash_idx| {
        clean_filename = filename[0..hash_idx];
    }

    return decodeInner(clean_path, clean_filename, dpi, page_num, coarse, allocator) catch |err| {
        const hint = switch (err) {
            error.CommandNotFound => "pdftoppm/pdfinfo non trovati: installa poppler-utils",
            else => @errorName(err),
        };
        const msg = std.fmt.allocPrint(allocator, "Errore rendering PDF: {s}", .{hint}) catch "Errore PDF";
        return .{ .err = msg };
    };
}

/// Canonicalizza `path` in un percorso ASSOLUTO con realpath(3) prima di
/// passarlo come argv a un tool esterno: un path relativo che inizia con `-`
/// (es. `zuer ./-r.pdf`) verrebbe altrimenti parsato come opzione da
/// pdfinfo/pdftoppm. Fallback: se realpath fallisce (file sparito nel
/// frattempo), usa il path originale ma prefissato con `./` quando è relativo
/// e inizia con `-`. Il chiamante libera con lo stesso allocator.
fn absPath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    var buf: [4096]u8 = undefined; // PATH_MAX
    if (realpath(pz.ptr, &buf)) |res|
        return gpa.dupe(u8, std.mem.span(res));
    if (std.mem.startsWith(u8, path, "-"))
        return std.fmt.allocPrint(gpa, "./{s}", .{path});
    return gpa.dupe(u8, path);
}

fn decodeInner(clean_path: []const u8, filename: []const u8, dpi: []const u8, page_num: usize, coarse: bool, allocator: std.mem.Allocator) !Decoded {
    // Path assoluto per i subprocess: mai passare il path utente as-given.
    const abs_path = try absPath(allocator, clean_path);
    defer allocator.free(abs_path);
    const stamp = fileStamp(abs_path);
    const fkey = fileKey(abs_path, stamp);

    var page: usize = if (page_num < 1) 1 else page_num;

    if (coarse) {
        // Il coarse non lancia mai `pdfinfo`, ma se il conteggio è GIÀ noto
        // (memo o cache su disco di un decode full precedente) clampa gratis:
        // evita di sprecare un pdftoppm su una pagina inesistente.
        if (pageCountLookup(fkey)) |known| {
            if (page > known) page = known;
        }
        const key = pageCacheKey(fkey, "-scale-to", coarse_scale, page);
        const p = try renderPage(allocator, abs_path, key, "-scale-to", coarse_scale, page);
        errdefer allocator.free(p.pixels);
        if (!p.from_cache) cacheWrite(allocator, key, p, 0);
        const name = try std.fmt.allocPrint(allocator, "{s} (pagina {d})", .{ filename, page });
        return .{
            .image = .{
                .width = p.width,
                .height = p.height,
                .pixels = p.pixels,
                .name = name,
                .total_pages = 0, // sconosciuto: il coarse non paga `pdfinfo`
            },
        };
    }

    // Conteggio pagine memoizzato per (realpath, mtime, size): dalla seconda
    // pagina in poi `pdfinfo` non viene più lanciato.
    var total_pages: usize = pageCountLookup(fkey) orelse 0;
    if (total_pages != 0 and page > total_pages) page = total_pages;

    // `pdftoppm` PRIMA di `pdfinfo`: il conteggio serve solo alla navigazione,
    // i pixel sono ciò che l'utente sta aspettando.
    var key = pageCacheKey(fkey, "-r", dpi, page);
    var rendered: ?Page = renderPage(allocator, abs_path, key, "-r", dpi, page) catch |err| blk: {
        // Senza conteggio non si distingue "pagina oltre la fine" (pdftoppm esce
        // 99 su un range invalido, o non scrive nulla) da un errore vero: solo in
        // quel caso si paga `pdfinfo`, si clampa e si riprova una volta sola.
        if (total_pages != 0) return err;
        if (err != error.PdfToPpmFailed and err != error.NoPagesRendered) return err;
        total_pages = fetchPageCount(allocator, abs_path, fkey) catch return err;
        if (page <= total_pages) return err; // la pagina esisteva: errore reale
        page = total_pages;
        break :blk null;
    };
    if (rendered == null) {
        key = pageCacheKey(fkey, "-r", dpi, page);
        rendered = try renderPage(allocator, abs_path, key, "-r", dpi, page);
    }
    const p = rendered.?;
    errdefer allocator.free(p.pixels);

    // La cache su disco porta con sé anche il conteggio: un hit evita del tutto
    // il subprocess `pdfinfo` alla riapertura del documento.
    if (total_pages == 0 and p.pages != 0) {
        total_pages = p.pages;
        pageCountStore(fkey, total_pages);
    }
    if (total_pages == 0) total_pages = fetchPageCount(allocator, abs_path, fkey) catch 1;
    if (total_pages < page) total_pages = page;
    if (!p.from_cache) cacheWrite(allocator, key, p, total_pages);

    // La label testuale resta per la UI; il conteggio pagine viaggia anche nel
    // campo strutturato `total_pages`, così l'host non deve parsare la stringa.
    const name = try std.fmt.allocPrint(allocator, "{s} (pagina {d} di {d})", .{ filename, page, total_pages });

    return .{ .image = .{
        .width = p.width,
        .height = p.height,
        .pixels = p.pixels,
        .name = name,
        .total_pages = std.math.cast(u32, total_pages) orelse std.math.maxInt(u32),
    } };
}

/// Numero di pagine da `pdfinfo`, memoizzato. Il primo che arriva paga il
/// subprocess; tutti i cambi pagina successivi leggono dalla memo.
fn fetchPageCount(gpa: std.mem.Allocator, abs_path: []const u8, fkey: u64) !usize {
    if (pageCountLookup(fkey)) |n| return n;

    var info = try decoder.runCapture(gpa, &.{ "pdfinfo", abs_path });
    defer info.deinit(gpa);
    if (info.exit_code != 0) return error.PdfInfoFailed;

    var total: usize = 1;
    var lines = std.mem.splitScalar(u8, info.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Pages:")) {
            const val = std.mem.trim(u8, line["Pages:".len..], " \t\r");
            total = std.fmt.parseInt(usize, val, 10) catch 1;
            break;
        }
    }
    if (total < 1) total = 1;
    pageCountStore(fkey, total);
    return total;
}

// ── Memo del conteggio pagine ───────────────────────────────────────────────
// Il plugin può essere chiamato da più thread insieme (decode iniziale,
// prefetch della pagina successiva, miniature dell'explorer): la tabella è
// piccolissima e protetta da un mutex, niente lock-free da giustificare.

const PageCountEntry = struct { key: u64, pages: u32 };

/// Spin-lock su atomica: la sezione critica è la scansione di 16 interi
/// (nanosecondi), e `std.Io.Mutex` vorrebbe l'`io` dell'host — che dentro un
/// plugin dinamico non si può usare (si blocca, vedi `decoder.runCapture`).
var pc_lock: std.atomic.Value(bool) = .init(false);
var pc_entries: [16]PageCountEntry = @splat(.{ .key = 0, .pages = 0 });
var pc_len: usize = 0;
var pc_next: usize = 0; // rimpiazzo circolare quando la tabella è piena

fn pcLock() void {
    while (pc_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn pcUnlock() void {
    pc_lock.store(false, .release);
}

fn pageCountLookup(key: u64) ?usize {
    pcLock();
    defer pcUnlock();
    for (pc_entries[0..pc_len]) |e| {
        if (e.key == key and e.pages != 0) return e.pages;
    }
    return null;
}

fn pageCountStore(key: u64, pages: usize) void {
    const p = std.math.cast(u32, pages) orelse return;
    if (p == 0) return;
    pcLock();
    defer pcUnlock();
    for (pc_entries[0..pc_len]) |*e| {
        if (e.key == key) {
            e.pages = p;
            return;
        }
    }
    if (pc_len < pc_entries.len) {
        pc_entries[pc_len] = .{ .key = key, .pages = p };
        pc_len += 1;
        return;
    }
    pc_entries[pc_next] = .{ .key = key, .pages = p };
    pc_next = (pc_next + 1) % pc_entries.len;
}

// ── Identità del file (per memo e cache su disco) ───────────────────────────

const Stamp = struct { size: u64 = 0, mtime_ns: i128 = 0 };

/// mtime + dimensione via statx: se il PDF viene riscritto sotto lo stesso
/// path, chiave diversa → memo e cache su disco si invalidano da sole.
fn fileStamp(abs_path: []const u8) Stamp {
    if (builtin.os.tag != .linux) return .{};
    const linux = std.os.linux;
    var buf: [4096]u8 = undefined;
    if (abs_path.len == 0 or abs_path.len >= buf.len) return .{};
    @memcpy(buf[0..abs_path.len], abs_path);
    buf[abs_path.len] = 0;
    var stx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, @ptrCast(&buf), 0, .{ .SIZE = true, .MTIME = true }, &stx);
    if (linux.errno(rc) != .SUCCESS) return .{};
    if (!stx.mask.SIZE or !stx.mask.MTIME) return .{};
    return .{
        .size = stx.size,
        .mtime_ns = @as(i128, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec,
    };
}

fn fileKey(abs_path: []const u8, stamp: Stamp) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    h.update(abs_path);
    h.update(std.mem.asBytes(&stamp.size));
    h.update(std.mem.asBytes(&stamp.mtime_ns));
    return h.final();
}

/// Chiave di una singola pagina renderizzata: file + variante di rendering
/// (`-r 200` e `-scale-to 1024` danno pixel diversi) + numero di pagina.
fn pageCacheKey(fkey: u64, flag: []const u8, value: []const u8, page: usize) u64 {
    var h = std.hash.Wyhash.init(fkey);
    h.update(flag);
    h.update(value);
    h.update(std.mem.asBytes(&page));
    return h.final();
}

// ── Rasterizzazione ─────────────────────────────────────────────────────────

const Page = struct {
    width: usize,
    height: usize,
    pixels: []u8,
    /// Conteggio pagine letto dalla cache su disco (0 = ignoto).
    pages: u32 = 0,
    /// true se i pixel vengono dalla cache: non vanno riscritti.
    from_cache: bool = false,
};

/// Rende `page` (o la ripesca dalla cache su disco). `flag`/`value` sono
/// SEMPRE letterali del plugin o il DPI già validato a monte: nessun argomento
/// arbitrario può raggiungere pdftoppm.
fn renderPage(gpa: std.mem.Allocator, abs_path: []const u8, key: u64, flag: []const u8, value: []const u8, page: usize) !Page {
    if (cacheRead(gpa, key)) |cached| return cached;

    // Rasterizzazione in un PPM temporaneo, dentro una directory privata creata
    // con mkdtemp: nome imprevedibile, niente symlink pre-creabili. (pdftoppm
    // non sa scrivere su stdout: il prefisso `-` genera un file chiamato
    // letteralmente `-.ppm`, verificato su poppler 26.08.)
    var dir_template: [32]u8 = undefined;
    const tmpl = try std.mem.printSentinel(&dir_template, "/tmp/zuer_pdf_XXXXXX", .{}, 0);
    if (mkdtemp(tmpl.ptr) == null) return error.TempDirFailed;
    defer cleanupTmpDir(tmpl.ptr);

    var prefix_buf: [48]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}/page", .{tmpl});

    var page_buf: [16]u8 = undefined;
    const page_str = try std.fmt.bufPrint(&page_buf, "{d}", .{page});

    var run_result = try decoder.runCapture(gpa, &.{ "pdftoppm", "-f", page_str, "-l", page_str, flag, value, abs_path, prefix });
    defer run_result.deinit(gpa);
    if (run_result.exit_code != 0) return error.PdfToPpmFailed;

    return readPageFile(prefix, page, gpa) orelse return error.NoPagesRendered;
}

/// pdftoppm zero-padda il numero di pagina in base al totale: si prova ogni
/// ampiezza fino a 6 cifre finché un file esiste ed è un PPM valido.
fn readPageFile(prefix: []const u8, page: usize, gpa: std.mem.Allocator) ?Page {
    var pad: usize = 1;
    while (pad <= 6) : (pad += 1) {
        var path_buf: [96]u8 = undefined;
        var digits_buf: [16]u8 = undefined;
        const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{page}) catch return null;
        if (digits.len > pad) continue;

        // Si lascia un byte per il terminatore NUL (le letture usano libc).
        var fbs: std.Io.Writer = .fixed(path_buf[0 .. path_buf.len - 1]);
        fbs.print("{s}-", .{prefix}) catch return null;
        fbs.splatByteAll('0', pad - digits.len) catch return null;
        fbs.print("{s}.ppm", .{digits}) catch return null;
        const len = fbs.buffered().len;
        path_buf[len] = 0;
        const candidate: [:0]const u8 = path_buf[0..len :0];

        if (readPpmFile(gpa, candidate)) |p| {
            _ = unlink(candidate.ptr);
            return p;
        }
    }
    return null;
}

/// Legge il PPM P6 prodotto da pdftoppm direttamente nel buffer finale: una
/// prima lettura corta per l'header, poi i pixel dentro l'allocazione esatta.
/// Rispetto al "leggi tutto il file e poi compatta in place" evita una copia e
/// una realloc da ~34 MB per pagina A3 a 200 DPI.
fn readPpmFile(gpa: std.mem.Allocator, path: [:0]const u8) ?Page {
    const fd = open(path.ptr, O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = close(fd);

    // "P6\n<w> <h>\n255\n": ampiamente sotto i 64 byte anche con commenti brevi.
    var hdr: [64]u8 = undefined;
    const got = read(fd, &hdr, hdr.len);
    if (got <= 0) return null;
    const n: usize = @intCast(got);
    const head = hdr[0..n];

    var pos: usize = 0;
    const magic = ppmToken(head, &pos) catch return null;
    if (!std.mem.eql(u8, magic, "P6")) return null;
    const width = std.fmt.parseInt(usize, ppmToken(head, &pos) catch return null, 10) catch return null;
    const height = std.fmt.parseInt(usize, ppmToken(head, &pos) catch return null, 10) catch return null;
    const maxval = std.fmt.parseInt(usize, ppmToken(head, &pos) catch return null, 10) catch return null;
    if (maxval != 255) return null;
    pos += 1; // un solo carattere di whitespace separa l'header dai dati binari
    if (pos > n) return null;

    // Un PDF ostile può dichiarare un MediaBox enorme: dimensioni fuori da
    // ogni ragionevolezza vengono rifiutate prima di allocare.
    if (width == 0 or height == 0 or width > 20000 or height > 20000) return null;
    const expected = width * height * 3;
    if (expected > max_page_bytes) return null;

    const pixels = gpa.alloc(u8, expected) catch return null;
    var filled = @min(expected, n - pos);
    @memcpy(pixels[0..filled], head[pos .. pos + filled]);
    while (filled < expected) {
        const r = read(fd, pixels.ptr + filled, expected - filled);
        if (r <= 0) {
            gpa.free(pixels);
            return null;
        }
        filled += @intCast(r);
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

/// Rimuove (best-effort) la directory temporanea: prima cancella gli eventuali
/// file `page-*` residui — pdftoppm può generarne più di uno e `rmdir` fallisce
/// in silenzio su una directory non vuota, lasciando orfani in /tmp — poi rmdir.
/// Ogni errore è ignorato: la pulizia non deve mai far fallire il decode.
fn cleanupTmpDir(tmpl: [*:0]const u8) void {
    if (opendir(tmpl)) |d| {
        while (readdir(d)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.d_name)), 0);
            if (!std.mem.startsWith(u8, name, "page")) continue;
            var buf: [320]u8 = undefined;
            const full = std.mem.printSentinel(&buf, "{s}/{s}", .{ std.mem.span(tmpl), name }, 0) catch continue;
            _ = unlink(full.ptr);
        }
        _ = closedir(d);
    }
    _ = rmdir(tmpl);
}

fn ppmToken(bytes: []const u8, pos: *usize) ![]const u8 {
    // Salta whitespace e commenti "#...\n"
    while (pos.* < bytes.len) {
        const c = bytes[pos.*];
        if (c == '#') {
            while (pos.* < bytes.len and bytes[pos.*] != '\n') pos.* += 1;
        } else if (std.ascii.isWhitespace(c)) {
            pos.* += 1;
        } else break;
    }
    const start = pos.*;
    while (pos.* < bytes.len and !std.ascii.isWhitespace(bytes[pos.*])) pos.* += 1;
    if (pos.* == start) return error.TruncatedPpm;
    return bytes[start..pos.*];
}

// ── Cache su disco delle pagine renderizzate ────────────────────────────────
//
// Formato "ZPG1": magic[4] | w u32 | h u32 | pages u32 | RGB (w*h*3 byte),
// little-endian. `pages` è il conteggio del documento (0 = ignoto): così un hit
// evita anche `pdfinfo`. Scrittura tmp+rename atomica e cap LRU sulla directory
// come texcache — una pagina A3 a 200 DPI pesa ~34 MB, senza eviction la cache
// crescerebbe all'infinito.

/// Solo Linux: `cache_evict` e i flag O_* POSIX usati qui non hanno senso
/// altrove. Sugli altri OS la cache è disattivata a comptime e il decode
/// procede come prima (il plugin è comunque installato solo su Linux).
const cache_enabled = builtin.os.tag == .linux;

const cache_magic = "ZPG1";
const cache_header_len = 16;

/// Cap LRU di `~/.cache/zuer/pdf`: oltre questa soglia l'eviction
/// (post-scrittura) cancella le pagine con mtime più vecchio.
const cache_cap_bytes: u64 = 256 * 1024 * 1024; // 256 MiB

var tmp_seq: std.atomic.Value(u64) = .init(0);
var tmp_sweep_done: std.atomic.Value(bool) = .init(false);

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

fn readAll(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = read(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn writeAll(fd: c_int, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = write(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// `$HOME/.cache/zuer/pdf`, creando la catena. null se niente HOME.
/// Il chiamante libera. (Stessa forma dell'helper di texcache.zig, che è
/// privato: qui serve una sottodirectory diversa.)
fn cacheDir(gpa: std.mem.Allocator) ?[]u8 {
    const home_c = getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    inline for (.{ "/.cache", "/.cache/zuer", "/.cache/zuer/pdf" }) |suffix| {
        const p = std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ home, suffix }, 0) catch return null;
        defer gpa.free(p);
        _ = mkdir(p.ptr, 0o755); // EEXIST ignorato
    }
    return std.fmt.allocPrint(gpa, "{s}/.cache/zuer/pdf", .{home}) catch null;
}

fn cacheRead(gpa: std.mem.Allocator, key: u64) ?Page {
    if (!cache_enabled) return null;
    const dir = cacheDir(gpa) orelse return null;
    defer gpa.free(dir);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.zpg", .{ dir, key }, 0) catch return null;
    defer gpa.free(path);

    const fd = open(path.ptr, O_RDONLY, 0);
    if (fd < 0) return null;
    defer _ = close(fd);

    var hdr: [cache_header_len]u8 = undefined;
    if (!readAll(fd, &hdr)) return null;
    if (!std.mem.eql(u8, hdr[0..4], cache_magic)) return null;
    const w = rd32(&hdr, 4);
    const h = rd32(&hdr, 8);
    const pages = rd32(&hdr, 12);
    if (w == 0 or h == 0 or w > 20000 or h > 20000) return null;
    const n = @as(usize, w) * h * 3;
    if (n > max_page_bytes) return null;
    const buf = gpa.alloc(u8, n) catch return null;
    if (!readAll(fd, buf)) {
        gpa.free(buf);
        return null;
    }
    // Cache-hit: "touch" dell'mtime così l'eviction LRU non cancella le entry usate.
    evict.touchFd(fd);
    return .{ .width = w, .height = h, .pixels = buf, .pages = pages, .from_cache = true };
}

/// Scrive la pagina renderizzata in cache (tmp + rename atomico). Best-effort:
/// ogni errore è silenzioso — la cache è un'ottimizzazione, non deve mai far
/// fallire il decode.
fn cacheWrite(gpa: std.mem.Allocator, key: u64, p: Page, total_pages: usize) void {
    if (!cache_enabled) return;
    if (p.pixels.len != p.width * p.height * 3) return;
    const dir = cacheDir(gpa) orelse return;
    defer gpa.free(dir);
    // Nome tmp univoco anche TRA processi (PID + seq): due istanze concorrenti
    // non devono interleave-arsi sullo stesso file temporaneo.
    const seq = tmp_seq.fetchAdd(1, .monotonic);
    const tmp = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.zpg.tmp{d}_{d}", .{ dir, key, std.os.linux.getpid(), seq }, 0) catch return;
    defer gpa.free(tmp);
    const path = std.fmt.allocPrintSentinel(gpa, "{s}/{x}.zpg", .{ dir, key }, 0) catch return;
    defer gpa.free(path);

    const fd = open(tmp.ptr, O_WRONLY | O_CREAT | O_TRUNC, 0o644);
    if (fd < 0) return;
    var ok = true;
    {
        var hdr: [cache_header_len]u8 = undefined;
        @memcpy(hdr[0..4], cache_magic);
        wr32(&hdr, 4, @intCast(p.width));
        wr32(&hdr, 8, @intCast(p.height));
        wr32(&hdr, 12, std.math.cast(u32, total_pages) orelse 0);
        ok = writeAll(fd, &hdr) and writeAll(fd, p.pixels);
    }
    _ = close(fd);
    if (!ok) return;
    if (rename(tmp.ptr, path.ptr) != 0) return;
    // Manutenzione post-scrittura: sweep una-tantum dei tmp orfani + cap LRU.
    evict.sweepTmpOnce(&tmp_sweep_done, dir);
    evict.evictLru(dir, cache_cap_bytes);
}

// ── ABI plugin ──────────────────────────────────────────────────────────────

fn decodeExport(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
    coarse: bool,
) decoder.DecodedC {
    const io = @as(*const std.Io, @ptrCast(@alignCast(io_ptr))).*;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const path_slice = path.toSlice();
    const filename = std.fs.path.basename(path_slice);
    // pdftoppm rilegge il PDF dal path: i byte già letti dall'host non servono.
    allocator.free(content.toSlice());
    const decoded = decodeTier(path_slice, io, filename, allocator, coarse);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    return decodeExport(path, content, io_ptr, allocator_ptr, false);
}

/// Tier coarse: anteprima a `-scale-to 1024`, senza `pdfinfo`. L'host la mostra
/// mentre il full (a DPI pieno) è ancora in coda, e l'explorer la usa per le
/// miniature.
export fn zuer_decode_coarse(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    return decodeExport(path, content, io_ptr, allocator_ptr, true);
}

pub const extensions = "pdf";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// pdftoppm rilegge il PDF dal path: l'host non deve leggere alcun byte.
export fn zuer_content_prefix() callconv(.c) usize {
    return 0;
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
export fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}

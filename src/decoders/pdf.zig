//! Plugin PDF: rasterizza le pagine con `pdftoppm` (poppler-utils) e le
//! impila verticalmente in un'unica immagine RGB. Nessuna dipendenza a
//! build-time: poppler è richiesto solo a runtime, con errore chiaro se manca.

const std = @import("std");
const decoder = @import("decoder");
const ImageData = decoder.ImageData;
const Decoded = decoder.Decoded;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern fn rmdir(path: [*:0]const u8) c_int;
extern fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

// Iterazione directory via libc (come le altre syscall del plugin): serve per
// ripulire i file pagina residui prima di rmdir.
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

const page_gap = 8;
const gap_color = [3]u8{ 0x30, 0x30, 0x38 };

pub fn decode(path: []const u8, io: std.Io, filename: []const u8, allocator: std.mem.Allocator) Decoded {
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

    return decodeInner(clean_path, clean_filename, dpi, page_num, allocator) catch |err| {
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
    const pz = try gpa.dupeZ(u8, path);
    defer gpa.free(pz);
    var buf: [4096]u8 = undefined; // PATH_MAX
    if (realpath(pz.ptr, &buf)) |res|
        return gpa.dupe(u8, std.mem.span(res));
    if (std.mem.startsWith(u8, path, "-"))
        return std.fmt.allocPrint(gpa, "./{s}", .{path});
    return gpa.dupe(u8, path);
}

fn decodeInner(clean_path: []const u8, filename: []const u8, dpi: []const u8, page_num: usize, allocator: std.mem.Allocator) !Decoded {
    // Path assoluto per i subprocess: mai passare il path utente as-given.
    const abs_path = try absPath(allocator, clean_path);
    defer allocator.free(abs_path);

    // 1. Numero di pagine dal sommario di pdfinfo
    var info = try decoder.runCapture(allocator, &.{ "pdfinfo", abs_path });
    defer info.deinit(allocator);
    if (info.exit_code != 0) return error.PdfInfoFailed;

    var total_pages: usize = 1;
    var lines = std.mem.splitScalar(u8, info.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Pages:")) {
            const val = std.mem.trim(u8, line["Pages:".len..], " \t\r");
            total_pages = std.fmt.parseInt(usize, val, 10) catch 1;
            break;
        }
    }

    var page = page_num;
    if (page < 1) page = 1;
    if (page > total_pages) page = total_pages;

    // 2. Rasterizzazione della singola pagina in PPM temporaneo, dentro una directory privata
    // creata con mkdtemp: nome imprevedibile, niente symlink pre-creabili.
    var dir_template: [32]u8 = undefined;
    const tmpl = try std.fmt.bufPrintZ(&dir_template, "/tmp/zuer_pdf_XXXXXX", .{});
    if (mkdtemp(tmpl.ptr) == null) return error.TempDirFailed;
    defer cleanupTmpDir(tmpl.ptr);

    var prefix_buf: [48]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}/page", .{tmpl});

    var page_buf: [16]u8 = undefined;
    const page_str = try std.fmt.bufPrint(&page_buf, "{d}", .{page});

    var run_result = try decoder.runCapture(allocator, &.{ "pdftoppm", "-f", page_str, "-l", page_str, "-r", dpi, abs_path, prefix });
    defer run_result.deinit(allocator);
    if (run_result.exit_code != 0) return error.PdfToPpmFailed;

    // 3. Lettura della pagina generata.
    const bytes = readPageFile(prefix, page, allocator) orelse return error.NoPagesRendered;
    defer allocator.free(bytes);
    const ppm = try parsePpm(bytes, allocator);
    errdefer allocator.free(ppm.pixels);

    // Passiamo al chiamante l'ownership diretta dei pixel parsati, evitando duplicazioni.
    const pixels = ppm.pixels;

    // La label testuale resta per la UI; il conteggio pagine viaggia anche nel
    // campo strutturato `total_pages`, così l'host non deve parsare la stringa.
    const name = try std.fmt.allocPrint(allocator, "{s} (pagina {d} di {d})", .{ filename, page, total_pages });

    return .{ .image = .{
        .width = ppm.width,
        .height = ppm.height,
        .pixels = pixels,
        .name = name,
        .total_pages = std.math.cast(u32, total_pages) orelse std.math.maxInt(u32),
    } };
}

fn readPageFile(prefix: []const u8, page: usize, allocator: std.mem.Allocator) ?[]u8 {
    var pad: usize = 1;
    while (pad <= 6) : (pad += 1) {
        var path_buf: [96]u8 = undefined;
        var digits_buf: [16]u8 = undefined;
        const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{page}) catch return null;
        if (digits.len > pad) continue;

        var fbs: std.Io.Writer = .fixed(&path_buf);
        fbs.print("{s}-", .{prefix}) catch return null;
        fbs.splatByteAll('0', pad - digits.len) catch return null;
        fbs.print("{s}.ppm", .{digits}) catch return null;
        const candidate = fbs.buffered();

        // Lettura via libc (non std.Io): dentro il plugin, sul thread worker,
        // l'io dell'host si blocca — come per std.process.run.
        if (decoder.readFileLibc(allocator, candidate, 256 * 1024 * 1024)) |bytes| {
            deleteFile(candidate);
            return bytes;
        } else |_| {}
    }
    return null;
}

extern fn unlink(filename: [*:0]const u8) c_int;

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
            const full = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ std.mem.span(tmpl), name }) catch continue;
            _ = unlink(full.ptr);
        }
        _ = closedir(d);
    }
    _ = rmdir(tmpl);
}

fn deleteFile(path: []const u8) void {
    var buf: [128]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = unlink(@ptrCast(&buf));
}

const Ppm = struct {
    width: usize,
    height: usize,
    pixels: []u8,
};

/// Parser minimale del formato PPM P6 (l'output di pdftoppm).
fn parsePpm(bytes: []const u8, allocator: std.mem.Allocator) !Ppm {
    var pos: usize = 0;
    const magic = try ppmToken(bytes, &pos);
    if (!std.mem.eql(u8, magic, "P6")) return error.NotP6;
    const width = try std.fmt.parseInt(usize, try ppmToken(bytes, &pos), 10);
    const height = try std.fmt.parseInt(usize, try ppmToken(bytes, &pos), 10);
    const maxval = try std.fmt.parseInt(usize, try ppmToken(bytes, &pos), 10);
    if (maxval != 255) return error.UnsupportedMaxval;
    // Un solo carattere di whitespace separa l'header dai dati binari
    pos += 1;

    // Un PDF ostile può dichiarare un MediaBox enorme: dimensioni fuori da
    // ogni ragionevolezza vengono rifiutate prima di allocare.
    if (width == 0 or height == 0 or width > 20000 or height > 20000) return error.InvalidPpmSize;
    const expected = width * height * 3;
    if (bytes.len < pos + expected) return error.TruncatedPpm;

    const pixels = try allocator.alloc(u8, expected);
    @memcpy(pixels, bytes[pos .. pos + expected]);
    return .{ .width = width, .height = height, .pixels = pixels };
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

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    const io = @as(*const std.Io, @ptrCast(@alignCast(io_ptr))).*;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const path_slice = path.toSlice();
    const filename = std.fs.path.basename(path_slice);
    // pdftoppm rilegge il PDF dal path: i byte già letti dall'host non servono.
    allocator.free(content.toSlice());
    const decoded = decode(path_slice, io, filename, allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

const extensions = "pdf";

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

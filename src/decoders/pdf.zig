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

const page_gap = 8;
const gap_color = [3]u8{ 0x30, 0x30, 0x38 };

pub fn decode(path: []const u8, io: std.Io, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    // In GUI si rasterizza ad alta risoluzione e più pagine; nel terminale
    // l'immagine viene comunque ridotta, quindi bastano meno pixel.
    var dpi: []const u8 = "70";
    var max_pages: usize = 4;
    if (getenv("ZUER_GUI")) |val| {
        if (std.mem.eql(u8, std.mem.span(val), "1")) {
            dpi = "120";
            max_pages = 12;
        }
    }

    return decodeInner(path, io, filename, dpi, max_pages, allocator) catch |err| {
        const hint = switch (err) {
            error.FileNotFound => "pdftoppm/pdfinfo non trovati: installa poppler-utils",
            else => @errorName(err),
        };
        const msg = std.fmt.allocPrint(allocator, "Errore rendering PDF: {s}", .{hint}) catch "Errore PDF";
        return .{ .err = msg };
    };
}

fn decodeInner(path: []const u8, io: std.Io, filename: []const u8, dpi: []const u8, max_pages: usize, allocator: std.mem.Allocator) !Decoded {
    // 1. Numero di pagine dal sommario di pdfinfo
    const info = try std.process.run(allocator, io, .{
        .argv = &.{ "pdfinfo", path },
    });
    defer allocator.free(info.stdout);
    defer allocator.free(info.stderr);
    switch (info.term) {
        .exited => |code| if (code != 0) return error.PdfInfoFailed,
        else => return error.PdfInfoFailed,
    }

    var total_pages: usize = 1;
    var lines = std.mem.splitScalar(u8, info.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Pages:")) {
            const val = std.mem.trim(u8, line["Pages:".len..], " \t\r");
            total_pages = std.fmt.parseInt(usize, val, 10) catch 1;
            break;
        }
    }
    const pages = @min(total_pages, max_pages);
    if (pages == 0) return error.EmptyPdf;

    // 2. Rasterizzazione in PPM temporanei, dentro una directory privata
    // creata con mkdtemp: nome imprevedibile, niente symlink pre-creabili.
    var dir_template: [32]u8 = undefined;
    const tmpl = try std.fmt.bufPrintZ(&dir_template, "/tmp/zuer_pdf_XXXXXX", .{});
    if (mkdtemp(tmpl.ptr) == null) return error.TempDirFailed;
    defer _ = rmdir(tmpl.ptr);

    var prefix_buf: [48]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "{s}/page", .{tmpl});

    var last_buf: [16]u8 = undefined;
    const last_str = try std.fmt.bufPrint(&last_buf, "{d}", .{pages});

    const run_result = try std.process.run(allocator, io, .{
        .argv = &.{ "pdftoppm", "-f", "1", "-l", last_str, "-r", dpi, path, prefix },
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |code| if (code != 0) return error.PdfToPpmFailed,
        else => return error.PdfToPpmFailed,
    }

    // 3. Lettura delle pagine generate. pdftoppm azzeropadda il numero di
    // pagina in modo dipendente dalla versione/documento: si provano le
    // larghezze di padding da 1 a 6 cifre.
    var ppm_pages = std.ArrayList(Ppm).empty;
    defer {
        for (ppm_pages.items) |p| allocator.free(p.pixels);
        ppm_pages.deinit(allocator);
    }

    var page: usize = 1;
    while (page <= pages) : (page += 1) {
        const bytes = readPageFile(prefix, page, io, allocator) orelse continue;
        defer allocator.free(bytes);
        const ppm = parsePpm(bytes, allocator) catch continue;
        ppm_pages.append(allocator, ppm) catch {
            allocator.free(ppm.pixels);
            break;
        };
    }
    if (ppm_pages.items.len == 0) return error.NoPagesRendered;

    // 4. Impila le pagine in un'unica immagine
    var width: usize = 0;
    var height: usize = 0;
    for (ppm_pages.items) |p| {
        width = @max(width, p.width);
        height += p.height;
    }
    height += page_gap * (ppm_pages.items.len - 1);

    const pixels = try allocator.alloc(u8, width * height * 3);
    errdefer allocator.free(pixels);
    // Sfondo = colore separatore, così i bordi di pagine più strette non restano neri
    var i: usize = 0;
    while (i < width * height) : (i += 1) {
        pixels[i * 3 ..][0..3].* = gap_color;
    }

    var y: usize = 0;
    for (ppm_pages.items) |p| {
        const x_off = (width - p.width) / 2;
        for (0..p.height) |row| {
            const dst = ((y + row) * width + x_off) * 3;
            const src = row * p.width * 3;
            @memcpy(pixels[dst .. dst + p.width * 3], p.pixels[src .. src + p.width * 3]);
        }
        y += p.height + page_gap;
    }

    var name: []const u8 = undefined;
    if (total_pages > pages) {
        name = try std.fmt.allocPrint(allocator, "{s} (prime {d} di {d} pagine)", .{ filename, pages, total_pages });
    } else {
        name = try allocator.dupe(u8, filename);
    }

    return .{ .image = .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .name = name,
    } };
}

fn readPageFile(prefix: []const u8, page: usize, io: std.Io, allocator: std.mem.Allocator) ?[]u8 {
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

        const limit = std.Io.Limit.limited(256 * 1024 * 1024);
        if (std.Io.Dir.cwd().readFileAlloc(io, candidate, allocator, limit)) |bytes| {
            deleteFile(candidate);
            return bytes;
        } else |_| {}
    }
    return null;
}

extern fn unlink(filename: [*:0]const u8) c_int;

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

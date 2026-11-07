const std = @import("std");
const builtin = @import("builtin");
const decoder = @import("decoder");
const exif = @import("exif.zig");
const ImageData = decoder.ImageData;
const Decoded = decoder.Decoded;

// stb_image (vendor/stb), compilato dentro il plugin: decodifica nativa di
// PNG/JPEG/GIF/BMP/TGA/PSD/HDR/PIC/PNM direttamente dai byte già letti, senza
// processi esterni.
extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_info_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int) c_int;
extern fn stbi_failure_reason() ?[*:0]const u8;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Canonicalizzazione per-OS: realpath(3) su POSIX, _fullpath (CRT) su Windows.
// Switch comptime come per `sub` in decoder.zig: solo il ramo selezionato viene
// analizzato, quindi l'extern dell'altro OS non arriva mai al link.
const canon = switch (builtin.os.tag) {
    .windows => struct {
        extern fn _fullpath(resolved: [*]u8, path: [*:0]const u8, max_len: usize) ?[*:0]u8;
        fn resolve(pz: [*:0]const u8, buf: []u8) ?[*:0]u8 {
            return _fullpath(buf.ptr, pz, buf.len);
        }
    },
    else => struct {
        extern fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
        fn resolve(pz: [*:0]const u8, buf: []u8) ?[*:0]u8 {
            return realpath(pz, buf.ptr);
        }
    },
};

/// Canonicalizza `path` in un percorso ASSOLUTO (realpath/_fullpath) prima di
/// passarlo come argv a un tool esterno: un path relativo che inizia con `-`
/// verrebbe parsato come opzione, e ImageMagick interpreta prefissi coder
/// (`msl:`, `caption:`, `pango:`…) DENTRO il filename — un path che inizia
/// con `/` li neutralizza. Fallback: se la canonicalizzazione fallisce (file
/// sparito nel frattempo), usa il path originale ma prefissato con `./` quando
/// è relativo e inizia con `-`. Il chiamante libera con lo stesso allocator.
fn absPath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    var buf: [4096]u8 = undefined; // PATH_MAX
    if (canon.resolve(pz.ptr, &buf)) |res|
        return gpa.dupe(u8, std.mem.span(res));
    if (std.mem.startsWith(u8, path, "-"))
        return std.fmt.allocPrint(gpa, "./{s}", .{path});
    return gpa.dupe(u8, path);
}

pub fn decode(path: []const u8, file_bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    var max_dim: usize = 160;
    if (getenv("ZUER_GUI")) |val| {
        if (std.mem.eql(u8, std.mem.span(val), "1")) {
            max_dim = 4096; // Risoluzione di alta qualità per la GUI
        }
    }
    return decodeWithMax(path, file_bytes, filename, allocator, max_dim);
}

/// Tetto del tier coarse (miniature explorer): i pixel restituiti restano
/// piccoli anche se stb decodifica comunque a piena risoluzione in C.
pub const coarse_max_dim: usize = 512;

pub fn decodeWithMax(path: []const u8, file_bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator, max_dim: usize) Decoded {
    // I subprocess (SVG/ImageMagick) usano decoder.runCapture (fork/exec diretti),
    // quindi qui non serve l'io dell'host.
    //
    // Ordine dei motori, IDENTICO su ogni piattaforma salvo il codec di sistema:
    //   1. SVG: rsvg-convert (non su Windows), poi nanosvg (in processo, ovunque);
    //   2. WebP: libwebp (in processo, ovunque; anche i WebP animati: 1° fotogramma);
    //   3. ICO: parser in Zig, voci PNG/BMP decodificate con stb;
    //   4. stb_image: PNG, JPEG (con orientamento EXIF), GIF, BMP, TGA, PSD, HDR, PIC, PNM;
    //   5. codec di sistema: ImageIO su macOS, WIC su Windows (TIFF, HEIC/AVIF…);
    //   6. ImageMagick, non su Windows (là `convert.exe` è lo strumento di sistema
    //      che converte i FILESYSTEM FAT in NTFS: mai lanciarlo).
    // L'alpha si compone sempre su bianco, come i viewer di documenti.
    var last_err: anyerror = error.UnsupportedImageFormat;

    if (hasSvgExtension(filename)) {
        if (comptime !is_windows) {
            if (decodeWithRsvg(path, filename, max_dim, allocator)) |img| {
                return .{ .image = img };
            } else |_| {}
        }
        if (decodeSvgNano(file_bytes, filename, max_dim, allocator)) |img| {
            return .{ .image = img };
        } else |e| last_err = e;
    } else if (isWebp(file_bytes)) {
        if (decodeWebp(file_bytes, filename, max_dim, allocator)) |img| {
            return .{ .image = img };
        } else |e| last_err = e;
    } else if (isIco(file_bytes)) {
        if (decodeIco(file_bytes, filename, max_dim, allocator)) |img| {
            return .{ .image = img };
        } else |e| last_err = e;
    } else if (decodeNative(file_bytes, filename, max_dim, allocator)) |img| {
        return .{ .image = img };
    } else |e| {
        last_err = e;
    }
    if (last_err == error.ImageTooLarge or last_err == error.OutOfMemory) return errResult(allocator, last_err, null);

    if (decodeSystem(file_bytes, filename, max_dim, allocator)) |img| {
        return .{ .image = img };
    } else |e| {
        if (e == error.ImageTooLarge or e == error.OutOfMemory) return errResult(allocator, e, null);
    }

    if (comptime is_windows) {
        // AVIF/HEIC in WIC esistono solo con le estensioni del Microsoft Store:
        // il messaggio dice quale manca invece di "formato non riconosciuto".
        if (isoBrand(file_bytes)) |brand| {
            const ext = if (brand == .avif) "AV1 Video Extension" else "HEIF Image Extensions + HEVC Video Extensions";
            const msg = std.fmt.allocPrint(allocator, "Errore caricamento immagine: {s} richiede il codec di Windows «{s}» (Microsoft Store)", .{ if (brand == .avif) "AVIF" else "HEIC/HEIF", ext }) catch "";
            return .{ .err = msg };
        }
        return errResult(allocator, last_err, null);
    }
    // Formati vettoriali o non coperti: fallback a ImageMagick.
    if (decodeWithImageMagick(path, filename, max_dim, allocator)) |img| {
        return .{ .image = img };
    } else |im_err| {
        return errResult(allocator, last_err, im_err);
    }
}

const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag == .macos;

/// Tetto sui pixel di una singola immagine SORGENTE (verificato prima di
/// decodificare): ~150 megapixel = 600 MB di RGBA. Oltre, un errore chiaro invece
/// di un'allocazione che può esaurire la memoria della macchina.
pub const max_source_pixels: usize = 150_000_000;

fn errResult(allocator: std.mem.Allocator, err: anyerror, im_err: ?anyerror) Decoded {
    const reason: []const u8 = switch (err) {
        error.UnsupportedImageFormat => if (stbi_failure_reason()) |r| std.mem.span(r) else "formato non riconosciuto",
        error.ImageTooLarge => "immagine troppo grande (oltre 150 megapixel)",
        error.OutOfMemory => "memoria esaurita",
        else => @errorName(err),
    };
    const msg = if (im_err) |e|
        std.fmt.allocPrint(allocator, "Errore caricamento immagine: {s} (fallback ImageMagick: {s})", .{ reason, @errorName(e) }) catch ""
    else
        std.fmt.allocPrint(allocator, "Errore caricamento immagine: {s}", .{reason}) catch "";
    return .{ .err = msg };
}

fn hasSvgExtension(filename: []const u8) bool {
    inline for (.{ ".svg", ".svgz" }) |ext| {
        if (filename.len >= ext.len) {
            const tail = filename[filename.len - ext.len ..];
            var eq = true;
            for (tail, ext) |a, b| {
                if (std.ascii.toLower(a) != b) eq = false;
            }
            if (eq) return true;
        }
    }
    return false;
}

/// Rasterizza l'SVG con librsvg in un PNG in memoria (adattato al box
/// max_dim×max_dim), poi lo decodifica con stb come qualsiasi altro PNG.
fn decodeWithRsvg(path: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    const svg_dim = svgDim(max_dim);
    var dim_buf: [16]u8 = undefined;
    const dim_str = try std.fmt.bufPrint(&dim_buf, "{d}", .{svg_dim});

    // Path assoluto: mai passare il path utente as-given a un subprocess.
    const abs_path = try absPath(allocator, path);
    defer allocator.free(abs_path);

    // Sfondo esplicito: stb scarta l'alpha e il trasparente diverrebbe nero.
    // Bianco, come i viewer di documenti: gli SVG sono quasi sempre disegnati
    // per sfondi chiari (tratti scuri) e su nero sparirebbero.
    var result = try decoder.runCapture(allocator, &.{ "rsvg-convert", "--width", dim_str, "--height", dim_str, "--keep-aspect-ratio", "--format", "png", "--background-color", "#ffffff", abs_path });
    defer result.deinit(allocator);

    if (result.exit_code != 0 or result.stdout.len == 0) return error.RsvgFailed;

    return decodeNative(result.stdout, filename, svg_dim, allocator);
}

/// La rasterizzazione costa ~col quadrato del lato: a 4096 un SVG complesso può
/// prendere decine di secondi (35 s misurati con rsvg), mentre a 2048 è ~4× più
/// veloce con qualità indistinguibile a schermo. Lato SVG cappato a 2048 (i
/// raster restano al max_dim pieno). Override: ZUER_SVG_MAX.
fn svgDim(max_dim: usize) usize {
    var svg_dim: usize = @min(max_dim, 2048);
    if (getenv("ZUER_SVG_MAX")) |v| {
        if (std.fmt.parseInt(usize, std.mem.span(v), 10)) |m| {
            if (m > 0) svg_dim = m;
        } else |_| {}
    }
    return svg_dim;
}

// ── Codec in C compilati nel plugin (src/c/image_codecs.c, src/c/wic_decode.c) ──
extern fn zuer_img_free(p: ?*anyopaque) void;
extern fn zuer_webp_rgba(data: [*]const u8, len: usize, max_pixels: c_int, out: *?[*]u8, w: *c_int, h: *c_int) c_int;
extern fn zuer_svg_rgba(data: [*:0]u8, max_dim: c_int, out: *?[*]u8, w: *c_int, h: *c_int) c_int;
const wic = if (is_windows) struct {
    extern fn zuer_wic_rgba(data: [*]const u8, len: usize, max_pixels: c_int, out: *?[*]u8, w: *c_int, h: *c_int) c_int;
} else struct {};
const imageio = if (is_macos) @import("image_imageio.zig") else struct {};

/// Pixel RGBA da un codec C (malloc): composti su bianco e ridimensionati.
fn finishC(rc: c_int, px: ?[*]u8, w: c_int, h: c_int, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    switch (rc) {
        0 => {},
        -2 => return error.OutOfMemory,
        -3 => return error.ImageTooLarge,
        else => return error.UnsupportedImageFormat,
    }
    const p = px orelse return error.UnsupportedImageFormat;
    defer zuer_img_free(p);
    if (w <= 0 or h <= 0) return error.InvalidImageSize;
    return resizeToFit(p, 4, @intCast(w), @intCast(h), 1, filename, max_dim, allocator);
}

fn decodeWebp(file_bytes: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    var px: ?[*]u8 = null;
    var w: c_int = 0;
    var h: c_int = 0;
    const rc = zuer_webp_rgba(file_bytes.ptr, file_bytes.len, @intCast(max_source_pixels), &px, &w, &h);
    return finishC(rc, px, w, h, filename, max_dim, allocator);
}

/// nanosvg: il parser lavora sul posto, quindi su una copia terminata da NUL.
/// `.svgz` (gzip) viene prima decompresso con la flate della std.
fn decodeSvgNano(file_bytes: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    const max_svg_bytes = 64 * 1024 * 1024;
    var text: []u8 = undefined;
    if (file_bytes.len >= 2 and file_bytes[0] == 0x1f and file_bytes[1] == 0x8b) {
        var in: std.Io.Reader = .fixed(file_bytes);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var dec: std.compress.flate.Decompress = .init(&in, .gzip, &window);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        _ = dec.reader.streamRemaining(&out.writer) catch return error.UnsupportedImageFormat;
        if (out.written().len > max_svg_bytes) return error.ImageTooLarge;
        text = try allocator.alloc(u8, out.written().len + 1);
        @memcpy(text[0 .. text.len - 1], out.written());
    } else {
        if (file_bytes.len > max_svg_bytes) return error.ImageTooLarge;
        text = try allocator.alloc(u8, file_bytes.len + 1);
        @memcpy(text[0 .. text.len - 1], file_bytes);
    }
    defer allocator.free(text);
    text[text.len - 1] = 0;
    const dim = svgDim(max_dim);
    var px: ?[*]u8 = null;
    var w: c_int = 0;
    var h: c_int = 0;
    const rc = zuer_svg_rgba(text[0 .. text.len - 1 :0].ptr, @intCast(dim), &px, &w, &h);
    return finishC(rc, px, w, h, filename, dim, allocator);
}

/// Codec di sistema: ImageIO (macOS) o WIC (Windows). Altrove non c'è.
fn decodeSystem(file_bytes: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    if (comptime is_windows) {
        var px: ?[*]u8 = null;
        var w: c_int = 0;
        var h: c_int = 0;
        const rc = wic.zuer_wic_rgba(file_bytes.ptr, file_bytes.len, @intCast(max_source_pixels), &px, &w, &h);
        return finishC(rc, px, w, h, filename, max_dim, allocator);
    } else if (comptime is_macos) {
        const r = try imageio.decode(allocator, file_bytes, max_source_pixels);
        defer allocator.free(r.rgba);
        return resizeToFit(r.rgba.ptr, 4, r.width, r.height, 1, filename, max_dim, allocator);
    } else return error.UnsupportedImageFormat;
}

fn decodeNative(file_bytes: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    if (file_bytes.len == 0 or file_bytes.len > std.math.maxInt(c_int)) return error.UnsupportedImageFormat;

    // Dimensioni dall'header PRIMA di decodificare: il tetto vale anche per stb.
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    if (stbi_info_from_memory(file_bytes.ptr, @intCast(file_bytes.len), &w, &h, &channels) == 0)
        return error.UnsupportedImageFormat;
    if (w <= 0 or h <= 0) return error.InvalidImageSize;
    if (@as(usize, @intCast(w)) * @as(usize, @intCast(h)) > max_source_pixels) return error.ImageTooLarge;

    const data = stbi_load_from_memory(file_bytes.ptr, @intCast(file_bytes.len), &w, &h, &channels, 4) orelse
        return error.UnsupportedImageFormat;
    defer stbi_image_free(data);

    if (w <= 0 or h <= 0) return error.InvalidImageSize;
    return resizeToFit(data, 4, @intCast(w), @intCast(h), exif.orientation(file_bytes), filename, max_dim, allocator);
}

/// Contenitore ISO-BMFF d'immagine (`....ftyp<brand>`): AVIF o HEIF.
fn isoBrand(b: []const u8) ?enum { avif, heif } {
    if (b.len < 12 or !std.mem.eql(u8, b[4..8], "ftyp")) return null;
    const brand = b[8..12];
    if (std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis")) return .avif;
    inline for (.{ "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1" }) |h| {
        if (std.mem.eql(u8, brand, h)) return .heif;
    }
    return null;
}

fn isWebp(b: []const u8) bool {
    return b.len >= 12 and std.mem.eql(u8, b[0..4], "RIFF") and std.mem.eql(u8, b[8..12], "WEBP");
}

// ── ICO ─────────────────────────────────────────────────────────────────────
// Un contenitore di più immagini: si sceglie la più grande (a parità, quella con
// più bit per pixel). Una voce è un PNG intero oppure un DIB "nudo" (header
// BITMAPINFOHEADER con altezza raddoppiata, pixel XOR, poi la maschera AND a 1 bit).

fn isIco(b: []const u8) bool {
    return b.len >= 6 and b[0] == 0 and b[1] == 0 and b[2] == 1 and b[3] == 0 and
        std.mem.readInt(u16, b[4..6], .little) > 0;
}

fn decodeIco(bytes: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    const count = std.mem.readInt(u16, bytes[4..6], .little);
    var best: ?struct { off: usize, size: usize, area: usize, bpp: u16 } = null;
    for (0..count) |i| {
        const e = 6 + i * 16;
        if (e + 16 > bytes.len) break;
        const ew: usize = if (bytes[e] == 0) 256 else bytes[e];
        const eh: usize = if (bytes[e + 1] == 0) 256 else bytes[e + 1];
        const bpp = std.mem.readInt(u16, bytes[e + 6 ..][0..2], .little);
        const size = std.mem.readInt(u32, bytes[e + 8 ..][0..4], .little);
        const off = std.mem.readInt(u32, bytes[e + 12 ..][0..4], .little);
        if (size == 0 or off >= bytes.len or size > bytes.len - off) continue;
        const area = ew * eh;
        if (best == null or area > best.?.area or (area == best.?.area and bpp > best.?.bpp))
            best = .{ .off = off, .size = size, .area = area, .bpp = bpp };
    }
    const b = best orelse return error.UnsupportedImageFormat;
    const entry = bytes[b.off..][0..b.size];
    if (entry.len >= 8 and std.mem.eql(u8, entry[0..8], "\x89PNG\r\n\x1a\n"))
        return decodeNative(entry, filename, max_dim, allocator);
    return decodeIcoDib(entry, filename, max_dim, allocator);
}

/// DIB di un'icona → file BMP ricostruito (header di 14 byte, altezza dimezzata)
/// decodificato da stb; poi la maschera AND rende trasparenti i pixel che la
/// richiedono (le icone a 32 bit hanno già l'alpha e la maschera si ignora).
fn decodeIcoDib(dib: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    if (dib.len < 40) return error.UnsupportedImageFormat;
    const hdr_size = std.mem.readInt(u32, dib[0..4], .little);
    if (hdr_size < 40 or hdr_size > dib.len) return error.UnsupportedImageFormat;
    const w = std.mem.readInt(i32, dib[4..8], .little);
    const h2 = std.mem.readInt(i32, dib[8..12], .little);
    const bpp = std.mem.readInt(u16, dib[14..16], .little);
    const clr_used = std.mem.readInt(u32, dib[32..36], .little);
    if (w <= 0 or w > 4096 or h2 <= 0 or h2 > 8192 or @rem(h2, 2) != 0) return error.UnsupportedImageFormat;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(@divExact(h2, 2));
    const colors: usize = if (bpp <= 8) (if (clr_used != 0) clr_used else @as(usize, 1) << @intCast(bpp)) else clr_used;
    const pix_off = 14 + hdr_size + colors * 4;
    const xor_row = ((uw * bpp + 31) / 32) * 4;
    const and_row = ((uw + 31) / 32) * 4;

    const bmp = try allocator.alloc(u8, 14 + dib.len);
    defer allocator.free(bmp);
    @memcpy(bmp[0..2], "BM");
    std.mem.writeInt(u32, bmp[2..6], @intCast(bmp.len), .little);
    std.mem.writeInt(u32, bmp[6..10], 0, .little);
    std.mem.writeInt(u32, bmp[10..14], @intCast(pix_off), .little);
    @memcpy(bmp[14..], dib);
    std.mem.writeInt(i32, bmp[14 + 8 ..][0..4], @intCast(uh), .little);

    var ow: c_int = 0;
    var oh: c_int = 0;
    var ch: c_int = 0;
    const data = stbi_load_from_memory(bmp.ptr, @intCast(bmp.len), &ow, &oh, &ch, 4) orelse
        return error.UnsupportedImageFormat;
    defer stbi_image_free(data);
    if (ow != w or oh != @as(c_int, @intCast(uh))) return error.UnsupportedImageFormat;

    // Maschera AND (righe dal basso verso l'alto): 1 = trasparente.
    const mask_off = pix_off - 14 + xor_row * uh;
    if (bpp < 32 and mask_off + and_row * uh <= dib.len) {
        for (0..uh) |y| {
            const row = dib[mask_off + (uh - 1 - y) * and_row ..][0..and_row];
            for (0..uw) |x| {
                if ((row[x / 8] >> @intCast(7 - x % 8)) & 1 != 0) data[(y * uw + x) * 4 + 3] = 0;
            }
        }
    }
    return resizeToFit(data, 4, uw, uh, 1, filename, max_dim, allocator);
}

/// Ridimensiona i pixel (`ch` = 3 RGB o 4 RGBA) per stare entro max_dim×max_dim
/// (media per area, solo riduzione), componendo l'alpha su bianco e applicando
/// l'orientamento EXIF `orient` (1 = nessuno), in un buffer RGB di proprietà
/// dell'allocator del chiamante. Tutto in un passaggio: nessuna copia intermedia
/// a piena risoluzione.
fn resizeToFit(src: [*]const u8, ch: usize, src_w: usize, src_h: usize, orient: u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    const fw: f32 = @floatFromInt(src_w);
    const fh: f32 = @floatFromInt(src_h);
    const fmax: f32 = @floatFromInt(max_dim);
    const scale = @min(1.0, @min(fmax / fw, fmax / fh));

    // Dimensioni ridotte nello spazio della SORGENTE; l'orientamento le scambia dopo.
    const dst_w = @max(1, @as(usize, @intFromFloat(@round(fw * scale))));
    const dst_h = @max(1, @as(usize, @intFromFloat(@round(fh * scale))));
    const swap = orient >= 5 and orient <= 8;
    const out_w = if (swap) dst_h else dst_w;
    const out_h = if (swap) dst_w else dst_h;

    const name = try allocator.dupe(u8, filename);
    errdefer allocator.free(name);
    const pixels = try allocator.alloc(u8, dst_w * dst_h * 3);
    errdefer allocator.free(pixels);

    for (0..out_h) |oy| {
        for (0..out_w) |ox| {
            const sp = exif.srcCoord(orient, dst_w, dst_h, ox, oy);
            const dx = sp[0];
            const dy = sp[1];
            const y0 = dy * src_h / dst_h;
            const y1 = @max(y0 + 1, (dy + 1) * src_h / dst_h);
            const x0 = dx * src_w / dst_w;
            const x1 = @max(x0 + 1, (dx + 1) * src_w / dst_w);

            var sum = [3]u64{ 0, 0, 0 };
            for (y0..y1) |sy| {
                for (x0..x1) |sx| {
                    const s = (sy * src_w + sx) * ch;
                    if (ch == 4) {
                        // Composizione su bianco: c·a + 255·(255−a), in unità 1/255.
                        const a: u64 = src[s + 3];
                        inline for (0..3) |c| sum[c] += (@as(u64, src[s + c]) * a + 255 * (255 - a) + 127) / 255;
                    } else {
                        inline for (0..3) |c| sum[c] += src[s + c];
                    }
                }
            }
            const count: u64 = @intCast((y1 - y0) * (x1 - x0));
            const d = (oy * out_w + ox) * 3;
            inline for (0..3) |c| pixels[d + c] = @intCast(sum[c] / count);
        }
    }

    return .{
        .width = out_w,
        .height = out_h,
        .pixels = pixels,
        .name = name,
    };
}

fn decodeWithImageMagick(path: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    // Path assoluto (neutralizza i prefissi coder di ImageMagick) + selettore
    // `[0]` esplicito: ImageMagick interpreta un suffisso `[N]` anche su path
    // assoluti, quindi lo fissiamo noi al primo frame. La semantica non cambia:
    // il codice sotto usava già solo il primo frame (primi due token di
    // identify, primi expected_bytes di convert) — con `[0]` identify non
    // concatena più le misure dei frame successivi e convert decodifica meno.
    const abs_path = try absPath(allocator, path);
    defer allocator.free(abs_path);
    const first_frame = try std.fmt.allocPrint(allocator, "{s}[0]", .{abs_path});
    defer allocator.free(first_frame);

    // 1. identify to get original size
    var size_result = try decoder.runCapture(allocator, &.{ "identify", "-format", "%w %h", first_frame });
    defer size_result.deinit(allocator);
    if (size_result.exit_code != 0) return error.IdentifyProcessFailed;

    var size_tokens = std.mem.tokenizeAny(u8, size_result.stdout, " \n\r\t");
    const w_str = size_tokens.next() orelse return error.InvalidImageMetadata;
    const h_str = size_tokens.next() orelse return error.InvalidImageMetadata;

    const orig_w = try std.fmt.parseInt(usize, w_str, 10);
    const orig_h = try std.fmt.parseInt(usize, h_str, 10);

    // Compute resized dimensions to fit within max_dim x max_dim
    const fmax: f32 = @floatFromInt(max_dim);
    const scale_w = fmax / @as(f32, @floatFromInt(orig_w));
    const scale_h = fmax / @as(f32, @floatFromInt(orig_h));
    const scale = @min(1.0, @min(scale_w, scale_h));

    const width = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(orig_w)) * scale)));
    const height = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(orig_h)) * scale)));

    if (width == 0 or height == 0) return error.EmptyResizedImage;

    // 2. convert path -resize <width>x<height> rgb:-
    var resize_buf: [32]u8 = undefined;
    const resize_str = try std.fmt.bufPrint(&resize_buf, "{d}x{d}", .{ width, height });

    // `rgb:-` scarta l'alpha: senza flatten esplicito il trasparente diventa
    // nero. Stesso sfondo bianco del percorso rsvg.
    var convert_result = try decoder.runCapture(allocator, &.{ "convert", first_frame, "-background", "white", "-alpha", "remove", "-depth", "8", "-resize", resize_str, "rgb:-" });
    defer convert_result.deinit(allocator);
    if (convert_result.exit_code != 0) return error.ConvertProcessFailed;

    const expected_bytes = width * height * 3;
    if (convert_result.stdout.len < expected_bytes) return error.IncompleteImagePixels;

    const name = try allocator.dupe(u8, filename);
    errdefer allocator.free(name);

    // Copia esatta dei pixel utili: liberare una slice diversa dall'allocazione
    // originale corromperebbe l'allocator.
    const pixels = try allocator.dupe(u8, convert_result.stdout[0..expected_bytes]);

    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .name = name,
    };
}

fn decodeExport(path: decoder.SliceC, content: decoder.SliceC, allocator_ptr: *const anyopaque, coarse: bool) decoder.DecodedC {
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const path_slice = path.toSlice();
    const content_slice = content.toSlice();
    const filename = std.fs.path.basename(path_slice);
    const decoded = if (coarse)
        decodeWithMax(path_slice, content_slice, filename, allocator, coarse_max_dim)
    else
        decode(path_slice, content_slice, filename, allocator);
    // decode() non conserva i byte del file (stb copia i pixel nel buffer
    // ridimensionato, ImageMagick rilegge dal path): vanno liberati qui o
    // trapelano a ogni immagine.
    allocator.free(content_slice);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr; // i subprocess usano fork/exec diretti, non l'io dell'host
    return decodeExport(path, content, allocator_ptr, false);
}

/// Tier coarse: stessa pipeline ma pixel entro `coarse_max_dim` — per le
/// miniature (explorer) che a piena risoluzione peserebbero ~64 MB l'una.
fn zuer_decode_coarse(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    return decodeExport(path, content, allocator_ptr, true);
}

// In processo su ogni piattaforma: stb_image (PNG/JPEG/GIF/BMP/TGA/PSD/HDR/PIC/PNM),
// libwebp (WebP), nanosvg (SVG/SVGZ), il parser ICO. TIFF e AVIF passano dal codec
// di sistema (ImageIO su macOS, WIC su Windows) o da ImageMagick su Linux.
pub const extensions = "png,jpg,jpeg,gif,bmp,tga,psd,hdr,pic,pnm,pbm,pgm,ppm,svg,svgz,webp,tif,tiff,ico,avif,heic,heif";

fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}

// Gli export dell'ABI plugin esistono solo dove i decoder SONO plugin (vedi
// decoder.plugin_abi): su Android sono linkati dentro l'unica libreria dell'APK e i loro
// nomi colliderebbero.
comptime {
    if (decoder.plugin_abi) {
        @export(&zuer_decode, .{ .name = "zuer_decode", .linkage = .strong });
        @export(&zuer_decode_coarse, .{ .name = "zuer_decode_coarse", .linkage = .strong });
        @export(&zuer_extensions, .{ .name = "zuer_extensions", .linkage = .strong });
        @export(&zuer_abi_version, .{ .name = "zuer_abi_version", .linkage = .strong });
    }
}

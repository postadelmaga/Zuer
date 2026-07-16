const std = @import("std");
const decoder = @import("decoder");
const ImageData = decoder.ImageData;
const Decoded = decoder.Decoded;

// stb_image (vendor/stb), compilato dentro il plugin: decodifica nativa di
// PNG/JPEG/GIF/BMP direttamente dai byte già letti, senza processi esterni.
extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_failure_reason() ?[*:0]const u8;

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// Canonicalizzazione per-OS: realpath(3) su POSIX, _fullpath (CRT) su Windows.
// Switch comptime come per `sub` in decoder.zig: solo il ramo selezionato viene
// analizzato, quindi l'extern dell'altro OS non arriva mai al link.
const canon = switch (@import("builtin").os.tag) {
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
    const pz = try gpa.dupeZ(u8, path);
    defer gpa.free(pz);
    var buf: [4096]u8 = undefined; // PATH_MAX
    if (canon.resolve(pz.ptr, &buf)) |res|
        return gpa.dupe(u8, std.mem.span(res));
    if (std.mem.startsWith(u8, path, "-"))
        return std.fmt.allocPrint(gpa, "./{s}", .{path});
    return gpa.dupe(u8, path);
}

pub fn decode(path: []const u8, file_bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    // I subprocess (SVG/ImageMagick) usano decoder.runCapture (fork/exec diretti),
    // quindi qui non serve l'io dell'host.
    var max_dim: usize = 160;
    if (getenv("ZUER_GUI")) |val| {
        if (std.mem.eql(u8, std.mem.span(val), "1")) {
            max_dim = 4096; // Risoluzione di alta qualità per la GUI
        }
    }

    // SVG: prima librsvg (rendering di qualità, gestisce anche .svgz),
    // poi il fallback ImageMagick come per gli altri formati non-stb.
    if (hasSvgExtension(filename)) {
        if (decodeWithRsvg(path, filename, max_dim, allocator)) |img| {
            return .{ .image = img };
        } else |_| {}
    }

    if (decodeNative(file_bytes, filename, max_dim, allocator)) |img| {
        return .{ .image = img };
    } else |native_err| {
        const native_reason: []const u8 = switch (native_err) {
            error.UnsupportedImageFormat => if (stbi_failure_reason()) |r| std.mem.span(r) else "formato non riconosciuto",
            else => @errorName(native_err),
        };

        // Formati vettoriali non coperti da stb_image (es. SVG): fallback a ImageMagick.
        if (decodeWithImageMagick(path, filename, max_dim, allocator)) |img| {
            return .{ .image = img };
        } else |im_err| {
            const msg = std.fmt.allocPrint(
                allocator,
                "Errore caricamento immagine: {s} (fallback ImageMagick: {s})",
                .{ native_reason, @errorName(im_err) },
            ) catch "Errore immagine";
            return .{ .err = msg };
        }
    }
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
    // La rasterizzazione rsvg costa ~col quadrato del lato: a 4096 un SVG complesso
    // può prendere decine di secondi (35 s misurati), mentre a 2048 è ~4× più veloce
    // con qualità indistinguibile a schermo. Cappiamo quindi il lato SVG a 2048
    // (i raster restano al max_dim pieno). Override: ZUER_SVG_MAX.
    var svg_dim: usize = @min(max_dim, 2048);
    if (getenv("ZUER_SVG_MAX")) |v| {
        if (std.fmt.parseInt(usize, std.mem.span(v), 10)) |m| {
            if (m > 0) svg_dim = m;
        } else |_| {}
    }
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

fn decodeNative(file_bytes: []const u8, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    if (file_bytes.len == 0 or file_bytes.len > std.math.maxInt(c_int)) return error.UnsupportedImageFormat;

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const data = stbi_load_from_memory(file_bytes.ptr, @intCast(file_bytes.len), &w, &h, &channels, 3) orelse
        return error.UnsupportedImageFormat;
    defer stbi_image_free(data);

    if (w <= 0 or h <= 0) return error.InvalidImageSize;
    return resizeToFit(data, @intCast(w), @intCast(h), filename, max_dim, allocator);
}

/// Ridimensiona i pixel RGB per stare entro max_dim×max_dim (media per area,
/// solo riduzione) copiandoli in un buffer di proprietà dell'allocator del chiamante.
fn resizeToFit(src: [*]const u8, src_w: usize, src_h: usize, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    const fw: f32 = @floatFromInt(src_w);
    const fh: f32 = @floatFromInt(src_h);
    const fmax: f32 = @floatFromInt(max_dim);
    const scale = @min(1.0, @min(fmax / fw, fmax / fh));

    const dst_w = @max(1, @as(usize, @intFromFloat(@round(fw * scale))));
    const dst_h = @max(1, @as(usize, @intFromFloat(@round(fh * scale))));

    const name = try allocator.dupe(u8, filename);
    errdefer allocator.free(name);
    const pixels = try allocator.alloc(u8, dst_w * dst_h * 3);
    errdefer allocator.free(pixels);

    if (dst_w == src_w and dst_h == src_h) {
        @memcpy(pixels, src[0 .. src_w * src_h * 3]);
    } else {
        for (0..dst_h) |dy| {
            const y0 = dy * src_h / dst_h;
            const y1 = @max(y0 + 1, (dy + 1) * src_h / dst_h);
            for (0..dst_w) |dx| {
                const x0 = dx * src_w / dst_w;
                const x1 = @max(x0 + 1, (dx + 1) * src_w / dst_w);

                var sum = [3]u64{ 0, 0, 0 };
                for (y0..y1) |sy| {
                    for (x0..x1) |sx| {
                        const s = (sy * src_w + sx) * 3;
                        sum[0] += src[s];
                        sum[1] += src[s + 1];
                        sum[2] += src[s + 2];
                    }
                }
                const count: u64 = @intCast((y1 - y0) * (x1 - x0));
                const d = (dy * dst_w + dx) * 3;
                pixels[d] = @intCast(sum[0] / count);
                pixels[d + 1] = @intCast(sum[1] / count);
                pixels[d + 2] = @intCast(sum[2] / count);
            }
        }
    }

    return .{
        .width = dst_w,
        .height = dst_h,
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

fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr; // i subprocess usano fork/exec diretti, non l'io dell'host
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const path_slice = path.toSlice();
    const content_slice = content.toSlice();
    const filename = std.fs.path.basename(path_slice);
    const decoded = decode(path_slice, content_slice, filename, allocator);
    // decode() non conserva i byte del file (stb copia i pixel nel buffer
    // ridimensionato, ImageMagick rilegge dal path): vanno liberati qui o
    // trapelano a ogni immagine.
    allocator.free(content_slice);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

// stb_image copre nativamente PNG/JPEG/GIF/BMP/TGA/PSD/HDR/PIC/PNM; i formati
// vettoriali o non coperti (SVG, WebP, TIFF, ICO, AVIF) passano dal fallback
// ImageMagick già presente in decode().
const extensions = "png,jpg,jpeg,gif,bmp,tga,psd,hdr,pic,pnm,pbm,pgm,ppm,svg,svgz,webp,tif,tiff,ico,avif";

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
        @export(&zuer_extensions, .{ .name = "zuer_extensions", .linkage = .strong });
        @export(&zuer_abi_version, .{ .name = "zuer_abi_version", .linkage = .strong });
    }
}

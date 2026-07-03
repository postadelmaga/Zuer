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

pub fn decode(path: []const u8, io: std.Io, file_bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator) Decoded {
    var max_dim: usize = 160;
    if (getenv("ZUER_GUI")) |val| {
        if (std.mem.eql(u8, std.mem.span(val), "1")) {
            max_dim = 4096; // Risoluzione di alta qualità per la GUI
        }
    }

    if (decodeNative(file_bytes, filename, max_dim, allocator)) |img| {
        return .{ .image = img };
    } else |native_err| {
        const native_reason: []const u8 = switch (native_err) {
            error.UnsupportedImageFormat => if (stbi_failure_reason()) |r| std.mem.span(r) else "formato non riconosciuto",
            else => @errorName(native_err),
        };

        // Formati vettoriali non coperti da stb_image (es. SVG): fallback a ImageMagick.
        if (decodeWithImageMagick(path, io, filename, max_dim, allocator)) |img| {
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

fn decodeWithImageMagick(path: []const u8, io: std.Io, filename: []const u8, max_dim: usize, allocator: std.mem.Allocator) !ImageData {
    // 1. identify to get original size
    const size_result = try std.process.run(allocator, io, .{
        .argv = &.{ "identify", "-format", "%w %h", path },
    });
    defer allocator.free(size_result.stdout);
    defer allocator.free(size_result.stderr);

    switch (size_result.term) {
        .exited => |code| {
            if (code != 0) return error.IdentifyProcessFailed;
        },
        else => return error.IdentifyProcessFailed,
    }

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

    const convert_result = try std.process.run(allocator, io, .{
        .argv = &.{ "convert", path, "-depth", "8", "-resize", resize_str, "rgb:-" },
    });
    errdefer allocator.free(convert_result.stdout);
    defer allocator.free(convert_result.stderr);

    switch (convert_result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(convert_result.stdout);
                return error.ConvertProcessFailed;
            }
        },
        else => {
            allocator.free(convert_result.stdout);
            return error.ConvertProcessFailed;
        },
    }

    const expected_bytes = width * height * 3;
    if (convert_result.stdout.len < expected_bytes) {
        allocator.free(convert_result.stdout);
        return error.IncompleteImagePixels;
    }

    const name = try allocator.dupe(u8, filename);
    errdefer allocator.free(name);

    // Vale quanto in text_render: mai liberare una slice diversa
    // dall'allocazione originale.
    const pixels = if (convert_result.stdout.len == expected_bytes)
        convert_result.stdout
    else blk: {
        const exact = try allocator.dupe(u8, convert_result.stdout[0..expected_bytes]);
        allocator.free(convert_result.stdout);
        break :blk exact;
    };

    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .name = name,
    };
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
    const content_slice = content.toSlice();
    const filename = std.fs.path.basename(path_slice);
    const decoded = decode(path_slice, io, content_slice, filename, allocator);
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

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

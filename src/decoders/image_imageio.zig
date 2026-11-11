//! Codec immagine di sistema su macOS (ImageIO): il ripiego per i formati che
//! stb_image, libwebp e nanosvg non coprono (TIFF, HEIC, AVIF, JPEG 2000, ICNS…),
//! lo stesso ruolo di ImageMagick su Linux e di WIC su Windows. Solo API C:
//! ImageIO, CoreGraphics e CoreFoundation si aprono a runtime alla prima immagine
//! (come in pdf_coregraphics.zig), quindi nessun link e nessun SDK in cross-build.
//!
//! Si chiede a ImageIO una miniatura del lato richiesto con la trasformazione EXIF
//! applicata (`CGImageSourceCreateThumbnailAtIndex`): le foto HEIC/RAW escono dritte e
//! un RAW da 50 MP si decodifica già ridotto. Se la miniatura fallisce si ripiega
//! sull'immagine intera.
//!
//! I pixel escono già composti su bianco (la bitmap è riempita di bianco prima di
//! disegnarci l'immagine): RGBA con alpha 255, allocati con `gpa`.

const std = @import("std");

pub const Raster = struct { width: usize, height: usize, rgba: []u8 };

const CFTypeRef = ?*anyopaque;
const CGFloat = f64;
const CGRect = extern struct { x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat };
const kCGImageAlphaPremultipliedLast: u32 = 1;

/// Simboli indispensabili: se ne manca uno ImageIO è inutilizzabile.
const Core = struct {
    CFDataCreate: *const fn (CFTypeRef, [*]const u8, isize) callconv(.c) CFTypeRef,
    CFRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGImageSourceCreateWithData: *const fn (CFTypeRef, CFTypeRef) callconv(.c) CFTypeRef,
    CGImageSourceGetCount: *const fn (CFTypeRef) callconv(.c) usize,
    CGImageSourceCreateImageAtIndex: *const fn (CFTypeRef, usize, CFTypeRef) callconv(.c) CFTypeRef,
    CGImageGetWidth: *const fn (CFTypeRef) callconv(.c) usize,
    CGImageGetHeight: *const fn (CFTypeRef) callconv(.c) usize,
    CGImageRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGColorSpaceCreateDeviceRGB: *const fn () callconv(.c) CFTypeRef,
    CGColorSpaceRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGBitmapContextCreate: *const fn (?*anyopaque, usize, usize, usize, usize, CFTypeRef, u32) callconv(.c) CFTypeRef,
    CGContextRelease: *const fn (CFTypeRef) callconv(.c) void,
    CGContextSetRGBFillColor: *const fn (CFTypeRef, CGFloat, CGFloat, CGFloat, CGFloat) callconv(.c) void,
    CGContextFillRect: *const fn (CFTypeRef, CGRect) callconv(.c) void,
    CGContextDrawImage: *const fn (CFTypeRef, CGRect, CFTypeRef) callconv(.c) void,
};

/// Miniatura con orientamento: facoltativa (Darling non ha
/// `CGImageSourceCreateThumbnailAtIndex`), senza si decodifica l'immagine intera.
const Thumb = struct {
    CGImageSourceCreateThumbnailAtIndex: *const fn (CFTypeRef, usize, CFTypeRef) callconv(.c) CFTypeRef,
    CFDictionaryCreate: *const fn (CFTypeRef, [*]const CFTypeRef, [*]const CFTypeRef, isize, *const anyopaque, *const anyopaque) callconv(.c) CFTypeRef,
    CFNumberCreate: *const fn (CFTypeRef, isize, *const anyopaque) callconv(.c) CFTypeRef,
    // Costanti (simboli di DATI: `lookup` dà il loro indirizzo).
    kCFTypeDictionaryKeyCallBacks: *const anyopaque,
    kCFTypeDictionaryValueCallBacks: *const anyopaque,
    kCFBooleanTrue: *const CFTypeRef,
    kCGImageSourceCreateThumbnailFromImageAlways: *const CFTypeRef,
    kCGImageSourceCreateThumbnailWithTransform: *const CFTypeRef,
    kCGImageSourceThumbnailMaxPixelSize: *const CFTypeRef,
};

const Api = struct { core: Core, thumb: ?Thumb };

const kCFNumberSInt64Type: isize = 4;

const libs = [_][]const u8{
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/ImageIO.framework/ImageIO",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
};

var api_lock: std.atomic.Value(bool) = .init(false);
var api: ?Api = null;
var api_failed = false;

fn getApi() !*const Api {
    while (api_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer api_lock.store(false, .release);
    if (api) |*a| return a;
    if (api_failed) return error.ImageIoUnavailable;
    api_failed = true;
    var handles: [libs.len]std.DynLib = undefined;
    for (libs, 0..) |p, i| handles[i] = std.DynLib.open(p) catch return error.ImageIoUnavailable;
    api = .{
        .core = lookupAll(Core, &handles) orelse return error.ImageIoUnavailable,
        .thumb = lookupAll(Thumb, &handles),
    };
    api_failed = false;
    return &api.?;
}

/// Tutti i simboli di `S` (null se ne manca anche uno solo).
fn lookupAll(comptime S: type, handles: *[libs.len]std.DynLib) ?S {
    var out: S = undefined;
    inline for (@typeInfo(S).@"struct".field_names, @typeInfo(S).@"struct".field_types) |name, T| {
        const lib = if (comptime std.mem.startsWith(u8, name, "CF") or std.mem.startsWith(u8, name, "kCF"))
            &handles[0]
        else if (comptime std.mem.startsWith(u8, name, "CGImageSource") or std.mem.startsWith(u8, name, "kCGImageSource"))
            &handles[1]
        else
            &handles[2];
        @field(out, name) = lib.lookup(T, name) orelse return null;
    }
    return out;
}

/// Miniatura ImageIO di lato massimo `max_dim`, orientamento EXIF applicato.
fn thumbnail(c: *const Core, a: *const Thumb, src: CFTypeRef, max_dim: usize) CFTypeRef {
    const side: i64 = @intCast(@max(max_dim, 1));
    const num = a.CFNumberCreate(null, kCFNumberSInt64Type, &side) orelse return null;
    defer c.CFRelease(num);
    const yes = a.kCFBooleanTrue.*;
    const keys = [_]CFTypeRef{ a.kCGImageSourceCreateThumbnailFromImageAlways.*, a.kCGImageSourceCreateThumbnailWithTransform.*, a.kCGImageSourceThumbnailMaxPixelSize.* };
    const vals = [_]CFTypeRef{ yes, yes, num };
    const opts = a.CFDictionaryCreate(null, &keys, &vals, keys.len, a.kCFTypeDictionaryKeyCallBacks, a.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer c.CFRelease(opts);
    return a.CGImageSourceCreateThumbnailAtIndex(src, 0, opts);
}

/// Primo fotogramma di `bytes`, lato massimo `max_dim` (orientamento applicato).
/// `max_pixels` è verificato PRIMA di allocare.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, max_dim: usize, max_pixels: usize) !Raster {
    const api_ = try getApi();
    const a = &api_.core;
    const data = a.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.OutOfMemory;
    defer a.CFRelease(data);
    const src = a.CGImageSourceCreateWithData(data, null) orelse return error.UnsupportedImageFormat;
    defer a.CFRelease(src);
    if (a.CGImageSourceGetCount(src) == 0) return error.UnsupportedImageFormat;
    const thumb = if (api_.thumb) |*t| thumbnail(a, t, src, max_dim) else null;
    const img = thumb orelse
        a.CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.UnsupportedImageFormat;
    defer a.CGImageRelease(img);
    const w = a.CGImageGetWidth(img);
    const h = a.CGImageGetHeight(img);
    if (w == 0 or h == 0) return error.InvalidImageSize;
    if (w * h > max_pixels) return error.ImageTooLarge;

    const rgba = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(rgba);
    const cs = a.CGColorSpaceCreateDeviceRGB() orelse return error.ImageIoFailed;
    defer a.CGColorSpaceRelease(cs);
    const ctx = a.CGBitmapContextCreate(rgba.ptr, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast) orelse
        return error.ImageIoFailed;
    defer a.CGContextRelease(ctx);
    const rect: CGRect = .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    a.CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    a.CGContextFillRect(ctx, rect);
    a.CGContextDrawImage(ctx, rect, img);
    return .{ .width = w, .height = h, .rgba = rgba };
}
